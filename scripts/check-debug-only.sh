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
  # macOS periodically empties $TMPDIR, and it does not do so atomically — it can leave
  # a half-deleted `SourcePackages/artifacts` tree behind. The next build then fails with
  # "There is no Info.plist found at .../Sentry.xcframework/Info.plist", which names a
  # dependency and says nothing about the cache, and reads like a broken checkout. Hit
  # twice in one afternoon. So: one wipe-and-retry, and only then believe the failure.
  # `build/` is gitignored, so on a fresh checkout — which is every CI run — it does not
  # exist, the redirect below fails before xcodebuild starts, and the retry fails the same
  # way. That read as "Release build failed twice" and kept CI red from the commit that
  # added this gate (0232dcc) until 18ef18e, through the 1.9.0 submissions.
  mkdir -p "$PROJECT_DIR/build"
  # On CI there is no signing identity; sign ad-hoc exactly as the test step does.
  SIGNING=()
  if [ -n "${CI:-}" ]; then
    SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM="")
  fi
  # Locally, Swift packages (~1.9 GB of Sentry) come from the shared checkout in
  # ~/Library/Caches/Soundpost-build rather than a copy inside $DD, so a $TMPDIR purge
  # (above) no longer takes them. On CI this adds nothing. See scripts/lib/build_cache.sh.
  # shellcheck source=lib/build_cache.sh
  source "$PROJECT_DIR/scripts/lib/build_cache.sh"
  # One build at a time in $DD: it is per $TMPDIR, not per checkout, so two checkouts would
  # otherwise share its build.db, and one's wipe-and-retry would delete the other's root.
  if [ -z "${CI:-}" ]; then
    build_lock_take "$DD.lock" "check-debug-only.sh in $PROJECT_DIR" || exit 1
    trap 'build_lock_release "$DD.lock"' EXIT
  fi
  local_build_args "$PROJECT_DIR" -derivedDataPath "$DD" || exit 1
  build_once() {
    xcodebuild build -project "$PROJECT_DIR/Soundpost.xcodeproj" -scheme Soundpost \
      -configuration Release -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DD" ${SIGNING[@]+"${SIGNING[@]}"} \
      ${LOCAL_BUILD_ARGS[@]+"${LOCAL_BUILD_ARGS[@]}"} > "$PROJECT_DIR/build/release-check.log" 2>&1
  }
  printf '  building Release…\n'
  if ! build_once; then
    printf '  build failed; wiping derived data and retrying once…\n'
    rm -rf "$DD"
    local_build_retry_args "$PROJECT_DIR"
    build_once || {
      # The log is a file, and on CI nobody can open it: print its end, or a failure
      # there says nothing about why (2026-11-08: red twice on a docs-only commit).
      printf '  last lines of build/release-check.log:\n' >&2
      { grep -E "error:|fatal|failed" "$PROJECT_DIR/build/release-check.log" | tail -n 15
        tail -n 25 "$PROJECT_DIR/build/release-check.log"; } 2>/dev/null | sed 's/^/    /' >&2 || true
      printf '\033[31m✗ Release build failed twice — see build/release-check.log\033[0m\n' >&2
      exit 1
    }
  fi
  APP="$DD/Build/Products/Release-iphonesimulator/Soundpost.app"
fi

# Every binary that ships, named by the project rather than assumed (M22 §4B.4). Until M22
# this read `Soundpost.app/Soundpost` only, so a widget extension's binary — a second
# executable inside the same `.app` — would never have been looked at. Counting Mach-O
# files would not do either: the `.app` already holds two (the app and Sentry), so a count
# passes with the extension missing. So each app and extension target names the exact
# executable it must produce, and each must be there.
#
# `GATE_PROJECT_DIR` points the project reader at another project (the gate's own tests
# use fixtures); it defaults to this checkout.
MODEL_PROJECT="${GATE_PROJECT_DIR:-$PROJECT_DIR}"
EXECUTABLES="$(python3 "$PROJECT_DIR/scripts/lib/project_model.py" --project "$MODEL_PROJECT" executables)" \
  || { printf '\033[31m✗ could not read the project'"'"'s targets\033[0m\n' >&2; exit 1; }

# The premise for each binary, asserted before the absences: this really is that target's
# binary. Without it a path typo — or an empty file — produces a clean run over a binary
# with no strings in it at all, every assertion below passing for the one reason that makes
# them meaningless. A target with no anchor here fails: whoever adds a target chooses what
# proves its binary is the real one.
anchor_for() {
  case "$1" in
    Soundpost) printf '%s' "Soundpost heard" ;;
    SoundpostWidgetExtension) printf '%s' "com.soundpost.Soundpost.widget.newCapsule" ;;
    *) return 1 ;;
  esac
}

failed=0
checked=0
while IFS=$'\t' read -r target rel; do
  [ -n "$target" ] || continue
  BIN="$APP/$rel"
  [ -f "$BIN" ] || { printf '\033[31m✗ %s: no binary at %s\033[0m\n' "$target" "$BIN" >&2; exit 1; }
  ANCHOR="$(anchor_for "$target")" || {
    printf '\033[31m✗ %s: no premise anchor in check-debug-only.sh for this target\033[0m\n' "$target" >&2
    exit 1
  }

  # Read once. NOT `strings "$BIN" | grep -q …`: under `set -o pipefail`, `grep -q`
  # exits the moment it matches, `strings` takes SIGPIPE, and the pipeline reports
  # failure for a successful match — so the premise check below would fail on a binary
  # that is fine, and every absence check would "pass" for the same wrong reason. This
  # is the third place in this repo where `pipefail` has turned a working pipeline into
  # a lying one (see cloudkit-schema.sh's `diff | sed`).
  SYMBOLS="$(strings "$BIN")"
  if ! grep -q -- "$ANCHOR" <<<"$SYMBOLS"; then
    printf '\033[31m✗ %s does not look like the %s binary (no "%s" in it)\033[0m\n' "$BIN" "$target" "$ANCHOR" >&2
    exit 1
  fi

  for token in "${FORBIDDEN[@]}"; do
    if grep -q -- "$token" <<<"$SYMBOLS"; then
      printf '\033[31m✗ %s is in the Release binary of %s\033[0m\n' "$token" "$target" >&2
      failed=1
    fi
  done
  checked=$((checked + 1))
done <<<"$EXECUTABLES"

if [ "$checked" -eq 0 ]; then
  printf '\033[31m✗ the project names no shipping binary to check\033[0m\n' >&2
  exit 1
fi

if [ "$failed" -ne 0 ]; then
  printf '\033[31mA DEBUG-only entry point reached a shipping build. One of them writes to\n' >&2
  printf 'the user'"'"'s live CloudKit database.\033[0m\n' >&2
  exit 1
fi

printf '\033[32m✓ Debug-only gate passed — %d entry points, none in %d Release binar%s.\033[0m\n' \
  "${#FORBIDDEN[@]}" "$checked" "$([ "$checked" -eq 1 ] && echo y || echo ies)"
