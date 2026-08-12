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
# ASC API creds come from env with sensible defaults baked in below:
#   ASC_API_KEY_ID, ASC_API_ISSUER, ASC_API_KEY_PATH
# Because those defaults exist, this script runs fine in a shell that never sourced
# ~/.zshrc — which is why a missing SENTRY_AUTH_TOKEN used to go unnoticed. Export
# the SENTRY_* vars from ~/.zshenv (read by every zsh, not just interactive ones).

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

# --- dSYM upload preflight -------------------------------------------------
# The ASC_API_* vars above have hardcoded fallbacks, so a release run from a shell
# that never sourced the user's profile still archives, signs and uploads perfectly —
# while the Sentry step silently no-ops for want of a token. That asymmetry is how
# 1.6.0 build 12 reached App Store Connect with no symbols on Sentry. Check the
# preconditions BEFORE the ~10-minute archive, not after.
DSYM_STATUS_FILE="$(mktemp -t soundpost-dsym-status)"
export DSYM_STATUS_FILE
printf 'not-run\n' > "$DSYM_STATUS_FILE"
trap 'rm -f "$DSYM_STATUS_FILE"' EXIT

DSYM_PREFLIGHT="ok"
if ! command -v sentry-cli >/dev/null 2>&1; then
  DSYM_PREFLIGHT="sentry-cli is not installed (brew install getsentry/tools/sentry-cli)"
elif [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  DSYM_PREFLIGHT="SENTRY_AUTH_TOKEN is not set in this shell"
fi

if [ "$DSYM_PREFLIGHT" != "ok" ]; then
  echo ""
  echo "########################################################################"
  echo "# PREFLIGHT WARNING: dSYMs will NOT reach Sentry this run."
  echo "#   $DSYM_PREFLIGHT"
  echo "#"
  echo "# Release crashes for this build will show raw addresses, not symbols."
  echo "# ~/.zshrc is read by INTERACTIVE zsh only — a run from an agent, cron,"
  echo "# 'zsh -c' or CI never sees it. Put the SENTRY_* exports in ~/.zshenv."
  echo "#"
  echo "# Ctrl-C now to fix it, or let the build run and backfill afterwards with:"
  echo "#   ./scripts/upload-dsyms.sh build/${SCHEME}.xcarchive"
  echo "########################################################################"
  echo ""
fi
# ---------------------------------------------------------------------------

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

# --- Release summary: did symbols actually ship? ----------------------------
# Printed last, on purpose. exportArchive's output is thousands of lines long and
# buries a WARN from step 1.5 completely; this is the line that has to be true.
DSYM_STATUS="$(cat "$DSYM_STATUS_FILE" 2>/dev/null || echo unknown)"
echo ""
case "$DSYM_STATUS" in
  uploaded)
    echo "======================================================================"
    echo " dSYM upload to Sentry: OK — symbols are on"
    echo " ${SENTRY_ORG:-jason-yeyuhe}/${SENTRY_PROJECT:-soundpost}."
    echo " Release crashes for this build will symbolicate."
    echo "======================================================================"
    ;;
  *)
    echo "######################################################################"
    case "$DSYM_STATUS" in
      skipped-no-token) REASON="SENTRY_AUTH_TOKEN was not set in this shell" ;;
      skipped-no-cli)   REASON="sentry-cli is not installed" ;;
      failed)           REASON="the upload ran but FAILED" ;;
      not-run)          REASON="the upload step never ran" ;;
      *)                REASON="status unknown ('$DSYM_STATUS')" ;;
    esac
    echo "# dSYM upload to Sentry: DID NOT HAPPEN — $REASON."
    echo "#"
    echo "# THIS BUILD'S RELEASE CRASHES WILL NOT SYMBOLICATE."
    if [ "$MODE" = "upload" ]; then
      echo "# The App Store Connect upload above still succeeded; only symbols are"
      echo "# missing. Fix the cause, then backfill this exact archive with:"
    else
      echo "# The archive/export above still succeeded; only symbols are missing."
      echo "# Fix the cause, then backfill this exact archive with:"
    fi
    echo "#"
    echo "#   ./scripts/upload-dsyms.sh $ARCHIVE_PATH"
    echo "#"
    echo "# (The archive is overwritten by the next run — backfill before then.)"
    echo "######################################################################"
    exit 3
    ;;
esac
