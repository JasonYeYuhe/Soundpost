#!/bin/bash
set -euo pipefail

# Archive -> export/upload Soundpost to App Store Connect using the ASC API key
# (.p8) + automatic signing. No keychain, no altool, no app-specific password.
# Adapted from RoastMate/FlowPilot. Soundpost uses a hand-authored .xcodeproj
# (file-system-synchronized groups), so there is NO xcodegen step.
#
# Usage:
#   ./scripts/build-upload-asc.sh            # archive + UPLOAD to App Store Connect, tag, push the tag
#   ./scripts/build-upload-asc.sh archive    # archive + local .ipa export only (no upload, no tag)
#
# ASC API creds come from env (exported in ~/.zshrc) with sensible defaults:
#   ASC_API_KEY_ID, ASC_API_ISSUER, ASC_API_KEY_PATH
#
# WHERE THE ARCHIVE GOES (M23 §4B.2). Xcode's Archives, outside ~/Documents:
#   ~/Library/Developer/Xcode/Archives/<YYYY-MM-DD>/Soundpost <version> (<build>).xcarchive
# 1.12.0's app bundle vanished from the iCloud-synced build/ two hours after its upload.
# Nothing here deletes or overwrites an archive: an archive of this version and build that
# records a SUCCESSFUL upload refuses the run (raise the build number); one that does not
# (a failed attempt) is left alone and this run writes `… - attempt <n>.xcarchive`.
# ARCHIVES_ROOT moves the folder (a dry run passes its own scratch one); ARCHIVE_PATH names
# the archive outright and must not exist. The export (.ipa / upload staging) goes to
# ~/Library/Caches/Soundpost-build/export/<version>-<build>/, which is replaceable.
#
# THE CHECKS. scripts/release-preflight.sh before archiving (clean tree, no iCloud copies,
# a keychain that can sign, a new build number, a Sentry token). In upload mode this script
# also proves the Sentry token works before the archive starts, refuses an upload if HEAD
# moved or the tree changed while the archive ran, and requires the dSYMs to reach Sentry
# (`upload-dsyms.sh --required`). RELEASE_PREFLIGHT_ALLOW=<check>[,<check>] goes past a
# named preflight check (copies, keychain, build-number) and nothing else; the retired
# RELEASE_PREFLIGHT_OVERRIDE is refused. Decisions live in scripts/lib/release_policy.sh.

MODE="${1:-upload}"
# Derived, not hard-coded: a worktree or a clone ran the archive from the main
# checkout's sources while reporting its own (M20 §4B).
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/release_policy.sh
source "$PROJECT_DIR/scripts/lib/release_policy.sh"
SCHEME="${SCHEME:-Soundpost}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"

case "$MODE" in
  upload|archive) ;;
  *) echo "ERROR: unknown mode '$MODE' (upload or archive)"; exit 2 ;;
esac
if legacy_override_refused; then exit 1; fi
allow_validate || exit 1

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

# An upload's dSYMs must reach Sentry, so the token is proven BEFORE the twenty-minute
# archive, not discovered missing after it (M23 §4B.3, §4B.6). `upload-dsyms.sh` without
# --required still warns and skips, which is right for a dry archive and wrong here.
if [ "$MODE" = "upload" ]; then
  problem="$(sentry_token_problem)"
  if [ -n "$problem" ]; then
    echo "ERROR: refusing to upload — $problem."
    echo "       This build's crashes would not symbolicate. No setting skips this."
    exit 1
  fi
  set +e
  code="$(sentry_probe)"
  verdict=$?
  set -e
  case "$verdict" in
    0) echo "==> Sentry token accepted (chunk-upload options: HTTP $code)" ;;
    1) echo "ERROR: refusing to upload — Sentry rejected the token (HTTP $code: token rejected)."
       echo "       Make a new one; check its shape first (\${#SENTRY_AUTH_TOKEN}, no '<…>')."
       exit 1 ;;
    *) echo "WARN: the Sentry probe answered HTTP $code — not a rejection, so the archive goes"
       echo "      ahead; the dSYM upload after it is still required." ;;
  esac
fi

project_setting() {
  grep -E "^[[:space:]]*$1 = " "$PROJECT_DIR/Soundpost.xcodeproj/project.pbxproj" \
    | sed -E 's/.*= "?([^";]*)"?;.*/\1/' | sort -u
}
VERSION="$(project_setting MARKETING_VERSION)"
BUILD="$(project_setting CURRENT_PROJECT_VERSION)"
if [ "$(printf '%s\n' "$VERSION" | grep -c .)" -ne 1 ] || [ "$(printf '%s\n' "$BUILD" | grep -c .)" -ne 1 ]; then
  echo "ERROR: the project does not hold one MARKETING_VERSION and one CURRENT_PROJECT_VERSION ('$VERSION' / '$BUILD')."
  exit 1
fi
# The commit this build is made from, fixed now: the archive takes twenty minutes, and
# another session sharing this checkout can commit in that time.
BUILT_SHA="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"

# Paths, computed only now that VERSION and BUILD are known.
ARCHIVES_ROOT="${ARCHIVES_ROOT:-$HOME/Library/Developer/Xcode/Archives}"
if [ -n "${ARCHIVE_PATH:-}" ]; then
  if [ -e "$ARCHIVE_PATH" ]; then
    echo "ERROR: $ARCHIVE_PATH already exists, and nothing here overwrites an archive."
    echo "       Name another path, or leave ARCHIVE_PATH unset to get the next free name."
    exit 1
  fi
elif ! ARCHIVE_PATH="$(archive_plan "$ARCHIVES_ROOT" "$VERSION" "$BUILD" "$(date +%Y-%m-%d)")"; then
  exit 1
fi
EXPORT_PATH="${EXPORT_PATH:-$HOME/Library/Caches/Soundpost-build/export/$VERSION-$BUILD}"

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

# The export folder is staging and may be replaced; the archive is never touched.
rm -rf "${EXPORT_PATH:?}"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

echo "=== Step 1/2: Archiving $SCHEME $VERSION ($BUILD) ($DESTINATION) ==="
echo "    -> $ARCHIVE_PATH"
xcodebuild archive \
  -project "$PROJECT_DIR/Soundpost.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE_PATH" \
  "${AUTH[@]}"
[ -d "$ARCHIVE_PATH" ] || { echo "ERROR: archive failed"; exit 1; }
echo "Archive OK -> $ARCHIVE_PATH"

# What the archive contains (M22 §4B.6): every target's executable, one version across
# the app and its extensions, a WidgetKit extension that links nothing it should not,
# the app's own dSYM. Fatal in both modes; no setting skips it.
"$PROJECT_DIR/scripts/verify-archive.sh" "$ARCHIVE_PATH" || {
  echo "ERROR: refusing to continue — the archive is not what this project builds (see above)."
  exit 1
}

# Still the commit the preflight saw, and still clean? If the checkout changed while the
# archive ran, the binary may match neither commit — stop before it reaches App Store
# Connect rather than tag the wrong one afterwards. Same dirty rule as the preflight
# (untracked files under .claude/ do not count); no setting skips it.
if [ "$MODE" = "upload" ]; then
  now_sha="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
  dirty=""
  if [ -z "$BUILT_SHA" ] || [ "$now_sha" != "$BUILT_SHA" ] || dirty="$(tree_is_dirty "$PROJECT_DIR")"; then
    echo "ERROR: refusing to upload — the checkout changed while the archive ran"
    echo "       (started at ${BUILT_SHA:-unknown}, now ${now_sha:-unknown}, or the tree is dirty)."
    [ -n "$dirty" ] && printf '%s\n' "$dirty" | head -20 | sed 's/^/         /'
    echo "       Re-run from a quiet checkout. The archive is kept at $ARCHIVE_PATH."
    exit 1
  fi
fi

# Upload this build's dSYMs to Sentry so its Release crashes symbolicate (M12 §S1).
# Required for an upload (M20 §4B, M23 §4B.3): 1.6.1 and 1.6.2 reached users with no
# dSYMs in Sentry because a failure here was a warning. A local archive only warns.
echo ""
echo "=== Step 1.5/2: dSYM upload to Sentry ==="
if [ "$MODE" = "upload" ]; then
  if ! ls -d "$ARCHIVE_PATH"/dSYMs/*.dSYM >/dev/null 2>&1; then
    echo "ERROR: refusing to upload — the archive holds no dSYMs, so this build's crashes would not symbolicate."
    exit 1
  fi
  if ! "$PROJECT_DIR/scripts/upload-dsyms.sh" --required "$ARCHIVE_PATH"; then
    echo "ERROR: refusing to upload — the dSYM upload to Sentry failed, so this build's crashes would not symbolicate."
    echo "       The archive is kept at $ARCHIVE_PATH; retry with: scripts/upload-dsyms.sh --required \"$ARCHIVE_PATH\""
    exit 1
  fi
elif [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  # A dry archive with no Sentry token uploads nothing (M22 S3): it is a signing and
  # contents check, not a release, and its dSYMs belong to no build anyone will run.
  echo "SKIP: archive mode with no SENTRY_AUTH_TOKEN — no dSYMs are sent."
elif ! "$PROJECT_DIR/scripts/upload-dsyms.sh" "$ARCHIVE_PATH"; then
  echo "WARN: the dSYM upload to Sentry failed; continuing with the local export."
fi

echo ""
echo "=== Step 2/2: exportArchive ($MODE) via ASC API key ==="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_PATH" \
  "${AUTH[@]}"

echo ""
if should_push_tag "$MODE"; then
  echo "Done — uploaded to App Store Connect. Check TestFlight processing in ASC."
  echo "The archive stays at $ARCHIVE_PATH"
  # The upload has happened; nothing below may turn that into a reported failure.
  TAG="v${VERSION}-b${BUILD}"
  tagged=""
  if [ -z "$BUILT_SHA" ]; then
    echo "WARN: no commit was recorded for this build, so it is not tagged."
  elif git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "WARN: tag $TAG already exists; left as it is (push it yourself if it is not on origin)."
  elif git -C "$PROJECT_DIR" tag -a "$TAG" "$BUILT_SHA" \
         -m "Soundpost $VERSION ($BUILD), uploaded to App Store Connect"; then
    echo "Tagged ${BUILT_SHA:0:7} as $TAG."
    tagged=1
  else
    echo "WARN: could not create tag $TAG on ${BUILT_SHA:0:7}; create it by hand."
  fi
  if [ -n "$tagged" ]; then
    if git -C "$PROJECT_DIR" push origin "$TAG"; then
      echo "Pushed $TAG to origin."
    else
      echo "WARN: could not push $TAG. Push it by hand: git push origin $TAG"
    fi
  fi
else
  echo "Done — local .ipa at: $EXPORT_PATH"
  echo "The archive stays at $ARCHIVE_PATH"
fi
exit 0
