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
