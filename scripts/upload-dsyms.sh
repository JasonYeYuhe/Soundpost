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
#
# NOTE on where the token lives: ~/.zshrc is read by INTERACTIVE zsh only. A release
# driven from any non-interactive shell (an agent, cron, `zsh -c`, CI) does not see it,
# and because build-upload-asc.sh carries hardcoded ASC_API_* fallbacks the rest of the
# release still succeeds — which is exactly how 1.6.0 build 12 shipped unsymbolicated.
# Put the SENTRY_* exports in ~/.zshenv so every shell gets them.
#
# Outcome reporting: when DSYM_STATUS_FILE is set in the environment, this script
# writes one word to that path describing what actually happened —
#   uploaded | skipped-no-cli | skipped-no-token | nothing-found | failed
# so a caller (build-upload-asc.sh) can surface it at the end of a release run.
# Unset ⇒ nothing is written and behaviour is exactly as before.

SENTRY_ORG="${SENTRY_ORG:-jason-yeyuhe}"
SENTRY_PROJECT="${SENTRY_PROJECT:-soundpost}"

report() {
  if [ -n "${DSYM_STATUS_FILE:-}" ]; then
    printf '%s\n' "$1" > "$DSYM_STATUS_FILE" 2>/dev/null || true
  fi
  return 0
}

# Default to the worst case: if this script dies unexpectedly (set -e, a signal),
# the caller must not read a stale "uploaded" and believe symbols shipped.
report failed

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "WARN: sentry-cli not installed (brew install getsentry/tools/sentry-cli) — skipping dSYM upload."
  report skipped-no-cli
  exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "WARN: SENTRY_AUTH_TOKEN not set — skipping dSYM upload."
  echo "      Export it in ~/.zshenv (alongside ASC_API_* ) to symbolicate Release crashes."
  report skipped-no-token
  exit 0
fi

upload() {
  local src="$1"
  echo "=== sentry-cli debug-files upload ($src) → $SENTRY_ORG/$SENTRY_PROJECT ==="
  # --include-sources is intentionally OMITTED: never upload source to Sentry.
  sentry-cli debug-files upload \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$src"
}

MODE="${1:-}"

if [ "$MODE" = "--backfill" ]; then
  PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  # Soundpost archives are written to the repo's build/ by build-upload-asc.sh
  # (overwritten each build), so scan there as well as the Xcode Organizer.
  SEARCH_DIRS=("$HOME/Library/Developer/Xcode/Archives" "$PROJECT_DIR/build")
  echo "Backfilling Soundpost*.xcarchive dSYMs from: ${SEARCH_DIRS[*]}"
  found=0
  failures=0
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' archive; do
      found=1
      if ! upload "$archive"; then
        failures=$((failures + 1))
        echo "ERROR: dSYM upload failed for: $archive" >&2
      fi
    done < <(find "$dir" -type d -name "Soundpost*.xcarchive" -print0 2>/dev/null)
  done
  if [ "$found" -eq 0 ]; then
    echo "No Soundpost*.xcarchive found — nothing to backfill."
    report nothing-found
    exit 0
  fi
  if [ "$failures" -gt 0 ]; then
    report failed
    echo "ERROR: $failures archive(s) failed to upload." >&2
    exit 1
  fi
  report uploaded
  exit 0
fi

if [ -z "$MODE" ]; then
  echo "ERROR: pass a path (a .xcarchive, dSYM dir, .dSYM, or .zip) or --backfill." >&2
  report failed
  exit 1
fi

if ! upload "$MODE"; then
  report failed
  echo "ERROR: dSYM upload failed for: $MODE" >&2
  exit 1
fi
report uploaded
