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

MODE="${1:-upload}"
PROJECT_DIR="/Users/jason/Documents/Soundpost"
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

# Upload this build's dSYMs to Sentry so its Release crashes symbolicate (M12 §S1).
# Non-fatal: a no-op-with-warning when SENTRY_AUTH_TOKEN / sentry-cli is absent, so
# the archive→upload pipeline never breaks just because Sentry creds aren't present.
echo ""
echo "=== Step 1.5/2: dSYM upload to Sentry ==="
"$PROJECT_DIR/scripts/upload-dsyms.sh" "$ARCHIVE_PATH" || \
  echo "WARN: dSYM upload step returned non-zero; continuing with export."

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
else
  echo "Done — local .ipa at: $EXPORT_PATH"
fi
