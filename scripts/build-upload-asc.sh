#!/bin/bash
set -euo pipefail

# Archive -> export/upload Soundpost to App Store Connect using the ASC API key
# (.p8) + automatic signing. No keychain, no altool, no app-specific password.
# Adapted from RoastMate/FlowPilot. Soundpost uses a hand-authored .xcodeproj
# (file-system-synchronized groups), so there is NO xcodegen step.
#
# Usage:
#   ./scripts/build-upload-asc.sh            # archive + UPLOAD to App Store Connect
#   ./scripts/build-upload-asc.sh archive    # archive + local .ipa export only (no upload)
#
# ASC API creds come from env (exported in ~/.zshrc) with sensible defaults:
#   ASC_API_KEY_ID, ASC_API_ISSUER, ASC_API_KEY_PATH
#
# Before archiving it runs scripts/release-preflight.sh (clean tree, no iCloud
# `X 2.swift` copies, a keychain that can sign, a new build number, a Sentry token).
# An upload also needs its dSYMs in Sentry, and is tagged `v<version>-b<build>` once
# App Store Connect has it. One override for all of it: RELEASE_PREFLIGHT_OVERRIDE=yes.

MODE="${1:-upload}"
# Derived, not hard-coded: a worktree or a clone ran the archive from the main
# checkout's sources while reporting its own (M20 §4B).
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Soundpost}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
ARCHIVE_PATH="$PROJECT_DIR/build/${SCHEME}.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/Export-${SCHEME}"

API_KEY_ID="${ASC_API_KEY_ID:-DMMFP6XTXX}"
API_ISSUER="${ASC_API_ISSUER:-c5671c11-49ec-47d9-bd38-5e3c1a249416}"
API_KEY_PATH="${ASC_API_KEY_PATH:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_${API_KEY_ID}.p8}"

if [ ! -f "$API_KEY_PATH" ]; then
  echo "ERROR: ASC API key not found at: $API_KEY_PATH"
  echo "       Set ASC_API_KEY_PATH or place AuthKey_${API_KEY_ID}.p8 there."
  exit 1
fi

# CloudKit schema gate (M15 §11B-i). An uploaded build talks to the CloudKit
# **Production** environment, and a record type that exists only in Development is
# not there — the client cannot create it, nothing throws, and the feature simply
# stops syncing while the UI keeps promising it works.
#
# This is here because remembering did not work: M9 performed the promotion by hand
# and wrote it down, M15 added an entity and nobody carried the step forward, and the
# plan's own note ("adding an entity is additive") was about SwiftData's *local*
# migration. A checklist is not a gate. This is.
#
# Set CK_SKIP_SCHEMA_CHECK=yes to upload anyway — deliberately awkward, and it prints
# what you are choosing to ship without.
if [ "$MODE" = "upload" ] && [ "${CK_SKIP_SCHEMA_CHECK:-}" != "yes" ]; then
  echo "==> CloudKit schema check (Production must know every record type this build ships)"
  if ! "$PROJECT_DIR/scripts/cloudkit-schema.sh" status; then
    echo
    echo "ERROR: refusing to upload — the CloudKit Production schema is behind this build."
    echo "       A shipped build talks to Production. A record type missing there does not"
    echo "       error; it silently does not sync, which is how an in-app promise becomes"
    echo "       false. See docs/M15-DEVPLAN.md §11B-i for the two steps."
    echo "       To upload regardless: CK_SKIP_SCHEMA_CHECK=yes $0 $MODE"
    exit 1
  fi
fi

"$PROJECT_DIR/scripts/release-preflight.sh" "$MODE" || exit 1

project_setting() {
  grep -E "^[[:space:]]*$1 = " "$PROJECT_DIR/Soundpost.xcodeproj/project.pbxproj" \
    | sed -E 's/.*= ([^;]*);.*/\1/' | sort -u
}
VERSION="$(project_setting MARKETING_VERSION)"
BUILD="$(project_setting CURRENT_PROJECT_VERSION)"
# The commit this build is made from, fixed now: the archive takes twenty minutes, and
# another session sharing this checkout can commit in that time.
BUILT_SHA="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"

if [ "$MODE" = "upload" ]; then
  EXPORT_PLIST="$PROJECT_DIR/ExportOptions-upload.plist"
else
  EXPORT_PLIST="$PROJECT_DIR/ExportOptions.plist"
fi

# Passed to BOTH archive and export so automatic signing can talk to ASC and
# create/refresh the distribution cert + provisioning profile as needed.
AUTH=(
  -authenticationKeyPath "$API_KEY_PATH"
  -authenticationKeyID "$API_KEY_ID"
  -authenticationKeyIssuerID "$API_ISSUER"
  -allowProvisioningUpdates
)

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

echo "=== Step 1/2: Archiving $SCHEME ($DESTINATION) ==="
xcodebuild archive \
  -project "$PROJECT_DIR/Soundpost.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE_PATH" \
  "${AUTH[@]}"
[ -d "$ARCHIVE_PATH" ] || { echo "ERROR: archive failed"; exit 1; }
echo "Archive OK -> $ARCHIVE_PATH"

# Still the commit the preflight saw, and still clean? If the checkout changed while the
# archive ran, the binary may match neither commit — stop before it reaches App Store
# Connect rather than tag the wrong one afterwards.
if [ "$MODE" = "upload" ] && [ "${RELEASE_PREFLIGHT_OVERRIDE:-}" != "yes" ]; then
  now_sha="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
  if [ -z "$BUILT_SHA" ] || [ "$now_sha" != "$BUILT_SHA" ] \
     || [ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
    echo "ERROR: refusing to upload — the checkout changed while the archive ran"
    echo "       (started at ${BUILT_SHA:-unknown}, now ${now_sha:-unknown}, or the tree is dirty)."
    echo "       Re-run from a quiet checkout, or: RELEASE_PREFLIGHT_OVERRIDE=yes $0 $MODE"
    exit 1
  fi
fi

# Upload this build's dSYMs to Sentry so its Release crashes symbolicate (M12 §S1).
# Fatal for an upload (M20 §4B): 1.6.1 and 1.6.2 reached users with no dSYMs in
# Sentry because a failure here was a warning. A local archive only warns.
echo ""
echo "=== Step 1.5/2: dSYM upload to Sentry ==="
dsym_problem=""
if ! ls -d "$ARCHIVE_PATH"/dSYMs/*.dSYM >/dev/null 2>&1; then
  dsym_problem="the archive holds no dSYMs"
elif ! "$PROJECT_DIR/scripts/upload-dsyms.sh" "$ARCHIVE_PATH"; then
  dsym_problem="the dSYM upload to Sentry failed"
fi
if [ -n "$dsym_problem" ]; then
  if [ "$MODE" = "upload" ] && [ "${RELEASE_PREFLIGHT_OVERRIDE:-}" != "yes" ]; then
    echo "ERROR: refusing to upload — $dsym_problem, so this build's crashes would not symbolicate."
    echo "       To upload regardless: RELEASE_PREFLIGHT_OVERRIDE=yes $0 $MODE"
    exit 1
  fi
  echo "WARN: $dsym_problem; continuing with export."
fi

echo ""
echo "=== Step 2/2: exportArchive ($MODE) via ASC API key ==="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_PATH" \
  "${AUTH[@]}"

echo ""
if [ "$MODE" = "upload" ]; then
  echo "Done — uploaded to App Store Connect. Check TestFlight processing in ASC."
  # The upload has happened; nothing below may turn that into a reported failure.
  TAG="v${VERSION}-b${BUILD}"
  if [ -z "$BUILT_SHA" ]; then
    echo "WARN: no commit was recorded for this build, so it is not tagged."
  elif git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "WARN: tag $TAG already exists; left as it is."
  elif git -C "$PROJECT_DIR" tag -a "$TAG" "$BUILT_SHA" \
         -m "Soundpost $VERSION ($BUILD), uploaded to App Store Connect"; then
    echo "Tagged ${BUILT_SHA:0:7} as $TAG. Push it: git push origin $TAG"
    if [ "${RELEASE_PREFLIGHT_OVERRIDE:-}" = "yes" ]; then
      echo "WARN: the preflight was overridden — $TAG names the commit at the start, which"
      echo "      may not be exactly what was built."
    fi
  else
    echo "WARN: could not create tag $TAG on ${BUILT_SHA:0:7}; create it by hand."
  fi
else
  echo "Done — local .ipa at: $EXPORT_PATH"
fi
