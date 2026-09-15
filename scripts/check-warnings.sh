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

# A warning raised inside a macro expansion (`#require`, `#expect`, `#Predicate`) does
# not carry a source path at all. The compiler prints it as
#
#   macro expansion #require:1:54: warning: '#require(_:_:)' is redundant …
#   `- /…/SoundpostTests/SoundprintTests.swift:1432:78: note: expanded code originates here
#
# so the filter above — which needs the path on the warning line — never saw one.
# That is how a warning Xcode 27 raises in two tests read as "No warnings". Pair each
# such warning with the "originates here" note that follows it and judge the note's
# path by the same rules.
macro_matches="$(awk '
  /^macro expansion .*warning:/ { pending = $0; next }
  pending != "" && /note: expanded code originates here/ {
    if ($0 ~ /\/(Soundpost|SoundpostTests)\// && $0 !~ /SourcePackages/ && $0 !~ /\/DerivedData\//)
      print pending " <- " $0
    pending = ""
  }
' "$LOG" 2>/dev/null | sort -u || true)"
if [ -n "$macro_matches" ]; then
  matches="${matches:+$matches
}$macro_matches"
fi

if [ -n "$matches" ]; then
  echo "✗ Build produced warnings in project sources:" >&2
  echo "$matches" >&2
  exit 1
fi
echo "✓ No warnings in project sources."
