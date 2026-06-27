#!/bin/bash
set -euo pipefail

# Fail if an xcodebuild log contains compiler warnings in OUR sources (M12 §S1).
# Third-party SPM dependency warnings (Sentry) are excluded — they live under
# DerivedData SourcePackages/checkouts and are not ours to fix. The standing bar
# is a warning-free *project* build.
#
# Usage: ./scripts/check-warnings.sh <xcodebuild.log>

LOG="${1:?usage: check-warnings.sh <xcodebuild.log>}"

matches="$(grep -E "warning:" "$LOG" 2>/dev/null \
  | grep -E "/(Soundpost|SoundpostTests)/" \
  | grep -v "SourcePackages" \
  | grep -v "/DerivedData/" || true)"

if [ -n "$matches" ]; then
  echo "✗ Build produced warnings in project sources:" >&2
  echo "$matches" >&2
  exit 1
fi
echo "✓ No warnings in project sources."
