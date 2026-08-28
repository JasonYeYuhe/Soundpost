#!/bin/bash
set -euo pipefail

# Upload debug symbols (dSYMs) to Sentry so Release crashes symbolicate
# (M12 §S1 / §4H-vi). Without this, production crash reports are raw addresses.
#
# Keyed off SENTRY_AUTH_TOKEN in the environment — exactly like the ASC API creds
# live in ~/.zshrc. If the token is absent this is a NON-FATAL no-op (so the build
# pipeline still runs for a developer without Sentry creds); it only warns.
#
# Usage:
#   ./scripts/upload-dsyms.sh <path>        # a .xcarchive, a dir of dSYMs, a .dSYM, or a .zip
#   ./scripts/upload-dsyms.sh --backfill    # every Soundpost archive in ~/Library/Developer/Xcode/Archives
#
# Org/project come from env with defaults (override if the slugs differ):
#   SENTRY_ORG     (default: jason-yeyuhe — the student-plan org, see ~/Documents/credits.md)
#   SENTRY_PROJECT (default: soundpost)
#   SENTRY_AUTH_TOKEN (REQUIRED to actually upload; absent ⇒ warn + skip)

SENTRY_ORG="${SENTRY_ORG:-jason-yeyuhe}"
SENTRY_PROJECT="${SENTRY_PROJECT:-soundpost}"

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "WARN: sentry-cli not installed (brew install getsentry/tools/sentry-cli) — skipping dSYM upload."
  exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "WARN: SENTRY_AUTH_TOKEN not set — skipping dSYM upload."
  echo "      Export it in ~/.zshrc (alongside ASC_API_* ) to symbolicate Release crashes."
  exit 0
fi

upload() {
  local src="$1"
  echo "=== sentry-cli debug-files upload ($src) → $SENTRY_ORG/$SENTRY_PROJECT ==="
  # --include-sources is intentionally OMITTED: never upload source to Sentry.
  #
  # The `|| return 1` is the point. Without it a failed upload — an expired token
  # returns `Invalid token (http status: 401)` and a non-zero exit — was swallowed,
  # this script still exited 0, and the caller printed nothing. Measured 2026-08-28
  # on the 1.7.0 build 16 upload: the token in ~/.zshrc had expired, the dSYMs never
  # reached Sentry, and the run reported success. That is the same shape as
  # 1.6.0 build 12 shipping unsymbolicated, which is the incident this script exists
  # to prevent — reported as fine, twice.
  sentry-cli debug-files upload \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$src" || return 1
}

MODE="${1:-}"

if [ "$MODE" = "--backfill" ]; then
  PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  # Soundpost archives are written to the repo's build/ by build-upload-asc.sh
  # (overwritten each build), so scan there as well as the Xcode Organizer.
  SEARCH_DIRS=("$HOME/Library/Developer/Xcode/Archives" "$PROJECT_DIR/build")
  echo "Backfilling Soundpost*.xcarchive dSYMs from: ${SEARCH_DIRS[*]}"
  found=0
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' archive; do
      found=1
      upload "$archive"
    done < <(find "$dir" -type d -name "Soundpost*.xcarchive" -print0 2>/dev/null)
  done
  [ "$found" -eq 1 ] || echo "No Soundpost*.xcarchive found — nothing to backfill."
  exit 0
fi

if [ -z "$MODE" ]; then
  echo "ERROR: pass a path (a .xcarchive, dSYM dir, .dSYM, or .zip) or --backfill." >&2
  exit 1
fi

upload "$MODE"
