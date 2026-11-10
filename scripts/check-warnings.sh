#!/bin/bash
set -euo pipefail

# Fail if an xcodebuild log contains compiler warnings in OUR sources (M12 §S1).
# Third-party SPM dependency warnings (Sentry) are excluded — they live under
# DerivedData SourcePackages/checkouts and are not ours to fix. The standing bar
# is a warning-free *project* build.
#
# Usage: ./scripts/check-warnings.sh <xcodebuild.log>

LOG="${1:?usage: check-warnings.sh <xcodebuild.log>}"

# **Ours** is everything under this checkout (M22 §4B.3), named by path rather than by
# folder: the filter used to be `/(Soundpost|SoundpostTests)/`, which caught a warning
# in a new target's folder only because the checkout itself happens to be called
# `Soundpost` — in a clone under any other name, a widget's warnings went unseen. A
# warning the build system raises for a whole target names no file, only
# `(in target 'X' from project 'Soundpost')`; that is ours too.
# `GATE_PROJECT_DIR` points it at another checkout (its own tests use fixtures).
PROJECT_DIR="${GATE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_NAME="$(basename "$(ls -d "$PROJECT_DIR"/*.xcodeproj | head -1)" .xcodeproj)"

# Every read below discards errors, so a mistyped path or a build that died before its
# log was written used to read as a clean build: "No warnings", exit 0.
if [ ! -s "$LOG" ]; then
  echo "✗ No build log at $LOG (missing or empty) — nothing was checked." >&2
  exit 2
fi

matches="$(grep -E "warning:" "$LOG" 2>/dev/null \
  | grep -F "$PROJECT_DIR/" \
  | grep -v "SourcePackages" \
  | grep -v "/DerivedData/" || true)"
target_matches="$(grep -E "warning:" "$LOG" 2>/dev/null \
  | grep -F "from project '$PROJECT_NAME')" || true)"
if [ -n "$target_matches" ]; then
  matches="${matches:+$matches
}$target_matches"
fi

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
macro_matches="$(awk -v root="$PROJECT_DIR/" '
  /^macro expansion .*warning:/ { pending = $0; next }
  pending != "" && /note: expanded code originates here/ {
    if (index($0, root) > 0 && $0 !~ /SourcePackages/ && $0 !~ /\/DerivedData\//)
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
