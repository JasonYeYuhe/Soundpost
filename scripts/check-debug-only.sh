#!/bin/bash
# Nothing DEBUG-only may reach a shipping binary.
#
# WHY THIS EXISTS. The app has grown several launch arguments that do things a user
# must never be able to trigger: `-seedSampleData` swaps in a fabricated library,
# `-screenshotScreen` stages a screen, and `-verifyProductionSync` WRITES A ROW TO THE
# USER'S LIVE CLOUDKIT DATABASE. Every one of them is wrapped in `#if DEBUG`, and that
# is a claim about the preprocessor made by reading the preprocessor. This asks the
# compiler instead: build Release and look for the strings in the binary.
#
# It is the same shape as every other gate here — the claim was true when it was
# written, and the question is whether anything notices on the day it stops being.
#
# WHAT IT ACTUALLY DETECTS, measured rather than assumed. A debug type that is
# compiled into Release but that nothing reachable calls is **dead-stripped**, and its
# name and its string literals go with it — so this gate cannot see it, and there is
# nothing there to see. What it does catch is the case that matters: a launch argument
# a shipping build actually READS. Verified by making `ProductionSyncCheck.requestedPhase`
# reachable from `usesProductionContainer` in Release — `verifyProductionSync` then
# appears in the binary and this gate goes red, while the type name and the marker
# value stay absent because they are still unreachable.
#
# So the load-bearing entries below are the launch-argument strings. The type names and
# the marker value are belt and braces: they cost nothing and they would catch a build
# that somehow kept the type alive.
#
# Usage: scripts/check-debug-only.sh            # builds Release itself
#        scripts/check-debug-only.sh <app-path> # checks a binary you already have
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Each entry is a string that must NOT appear in a Release binary. Names of the
# DEBUG-only types, the launch arguments that reach them, and the marker values they
# would write — the last of those because a renamed type with a live marker string
# would still be a live marker.
FORBIDDEN=(
  ProductionSyncCheck
  verifyProductionSync
  m19.production-sync-check
  seedSampleData
  screenshotScreen
  demo-screenshots
  CloudKitSchemaSeed
  initializeCloudKitSchema
  runAudioSelfTest
  runVideoSelfTest
)

if [ $# -ge 1 ]; then
  APP="$1"
else
  # Derived data OUTSIDE the repo: this project lives in an iCloud-synced folder and
  # iCloud writes xattrs that make codesign fail with a message about resource forks.
  DD="${TMPDIR:-/tmp}soundpost-debugonly-dd"
  printf '  building Release…\n'
  xcodebuild build -project "$PROJECT_DIR/Soundpost.xcodeproj" -scheme Soundpost \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DD" > "$PROJECT_DIR/build/release-check.log" 2>&1 \
    || { printf '\033[31m✗ Release build failed — see build/release-check.log\033[0m\n' >&2; exit 1; }
  APP="$DD/Build/Products/Release-iphonesimulator/Soundpost.app"
fi

BIN="$APP/$(basename "$APP" .app)"
[ -f "$BIN" ] || { printf '\033[31m✗ no binary at %s\033[0m\n' "$BIN" >&2; exit 1; }

# Read once. NOT `strings "$BIN" | grep -q …`: under `set -o pipefail`, `grep -q`
# exits the moment it matches, `strings` takes SIGPIPE, and the pipeline reports
# failure for a successful match — so the premise check below would fail on a binary
# that is fine, and every absence check would "pass" for the same wrong reason. This
# is the third place in this repo where `pipefail` has turned a working pipeline into
# a lying one (see cloudkit-schema.sh's `diff | sed`).
SYMBOLS="$(strings "$BIN")"

# The premise, asserted before the absences: this really is the app's binary. Without
# it, a path typo would produce a clean run over a file with no strings in it at all —
# every assertion below passing for the one reason that makes them meaningless.
if ! grep -q "Soundpost heard" <<<"$SYMBOLS"; then
  printf '\033[31m✗ %s does not look like the Soundpost binary (no shipped copy in it)\033[0m\n' "$BIN" >&2
  exit 1
fi

failed=0
for token in "${FORBIDDEN[@]}"; do
  if grep -q -- "$token" <<<"$SYMBOLS"; then
    printf '\033[31m✗ %s is in the Release binary\033[0m\n' "$token" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  printf '\033[31mA DEBUG-only entry point reached a shipping build. One of them writes to\n' >&2
  printf 'the user'"'"'s live CloudKit database.\033[0m\n' >&2
  exit 1
fi

printf '\033[32m✓ Debug-only gate passed — %d entry points, none in the Release binary.\033[0m\n' "${#FORBIDDEN[@]}"
