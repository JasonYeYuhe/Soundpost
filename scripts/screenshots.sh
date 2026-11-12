#!/bin/bash
# Re-runnable App Store screenshot capture (M19 §4A).
#
# WHY THIS EXISTS. The store's five screenshots were captured by hand on 2026-06-10
# and were not touched through 1.3.0, 1.4.0, 1.5.0, 1.6.0, 1.6.1, 1.6.2, 1.7.0 or
# 1.8.0. Nothing failed — there was simply no step that could fail. They show an app
# from before sound labels existed, which is the feature the last three releases were
# about. A hand-made screenshot goes stale by construction; a script goes stale only
# if nobody runs it, and running it is one line in a release checklist.
#
# WHAT IT PRODUCES. What `scripts/asc_policy.py` says the store gets — one constant read
# by this script and by `asc.py screenshots` alike (M23 §4B.7): the display type and its
# pixel size (APP_IPHONE_67, 1320x2868 since M23; the 6.5-inch set from 2026-09-16 is
# stale), the screens in store order, and the folder. A wrong size is a rejected
# submission, not a cosmetic problem, so every shot is measured against that constant.
#
# WHERE. `~/Library/Caches/Soundpost-build/screenshots-69/<locale>/` — outside iCloud, and
# never `build/screenshots/`, which holds the set the store shows today: this script
# empties a locale folder before capturing into it, and deletions in build/ are Jason's.
#
# THE DEVICE. The shared 6.9-inch `iPhone 17 Pro Max` from the global simulator table, by
# UDID — exactly one available device of that name on the iOS 27.0 runtime — under
# `/tmp/lock-iphone-17-pro-max`. Never created here (it used to create `Soundpost-Shots`, an
# iPhone 11 Pro Max): booting a never-booted device costs gigabytes. Shut down at exit only
# if this run booted it. Status bar: 9:41, full battery and bars, cleared at exit (M23 §4G).
#
# WHEN. After 09:30 local time: the demo library's samples sit at fixed daytime times
# (`DemoData.seed`), and before 09:30 this morning's would move to "a minute ago".
#
# WHAT IT DOES NOT DO. Upload: `asc.py screenshots` sends exactly the captured names.
#
# Usage:
#   scripts/screenshots.sh              # all locales, all screens
#   scripts/screenshots.sh ja           # one locale
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOTS_DEVICE="iPhone 17 Pro Max"
SHOTS_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
LOCK_DIR="/tmp/lock-iphone-17-pro-max"
BUNDLE_ID="com.soundpost.Soundpost"
# The build log, outside iCloud and outside build/ (whose files are Jason's).
BUILD_LOG="$HOME/Library/Caches/Soundpost-build/shots-build.log"
red()  { printf '\033[31m%s\033[0m\n' "$1" >&2; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# One constant, in asc_policy (M23 §4B.4, §4B.7). Read, never repeated here.
policy() { python3 -c "import sys; sys.path.insert(0, '$PROJECT_DIR/scripts'); import asc_policy as p; print($1)"; }
OUT="$(policy 'p.screenshot_dir()')"
DISPLAY_TYPE="$(policy 'p.SCREENSHOT_DISPLAY_TYPE')"
WANT_DIMS="$(policy '" ".join(str(n) for n in p.SCREENSHOT_SIZE) + " "')"
read -r -a SCREENS <<< "$(policy '" ".join(p.SCREENSHOT_SCREENS)')"
[ -n "$OUT" ] && [ -n "$DISPLAY_TYPE" ] && [ "${#SCREENS[@]}" -gt 0 ] || { red "could not read the screenshot policy"; exit 1; }
case "$OUT" in "$HOME/Documents"/*|"$PROJECT_DIR"/*) red "refusing to write screenshots into iCloud ($OUT)"; exit 1 ;; esac
mkdir -p "$OUT" && touch "$OUT/.no-sweep"

# **The screens (asc_policy.SCREENSHOT_SCREENS) leave out `settings`, and the reason is worth keeping.** That screen is the best
# argument for the on-device listening the description now leads with — the Listening
# footer explains it in the app's own words. It also ends with "Capsules live only on
# this device, so deleting the app erases them", which is what `CloudSyncMonitor`
# reports when there is no iCloud account. True of a screenshot simulator; false of
# the app the listing describes, which promises sync. Two contradicting claims on one
# store page.
#
# Forcing that footer to say something else was the tempting fix and the forbidden
# one: §4A rule 3 is that a screenshot may only show states the app actually produces,
# never one assembled for the photograph. Signing the capture simulator into iCloud
# would fix it honestly, and needs a password no script should hold. Until then the
# privacy story is carried by the description, in words, where it is not contingent on
# an account.

# Not `("${@:-en-US ja zh-Hans}")`, which expands to ONE element holding all three
# names. The script then made a single directory literally called "en-US ja zh-Hans",
# captured five screenshots into it, and reported success — and the output count below
# agreed with it, because that count derives its expectation from the same array.
# A tally cannot catch a mistake it shares.
if [ $# -gt 0 ]; then LOCALES=("$@"); else LOCALES=(en-US ja zh-Hans); fi
for locale in "${LOCALES[@]}"; do
  case "$locale" in
    en-US|ja|zh-Hans) ;;
    *) red "unknown locale '$locale' — the app ships en-US, ja and zh-Hans"; exit 1 ;;
  esac
done

if [ "$(date +%H%M)" -lt 0930 ]; then
  red "it is before 09:30: the demo library's morning samples would not be at their fixed times yet"
  exit 1
fi

# Exactly one match, by exact name AND runtime, or nothing (the global simulator rules).
UDID="$(xcrun simctl list devices available --json | python3 -c "
import json, sys
found = [x['udid'] for x in json.load(sys.stdin)['devices'].get('$SHOTS_RUNTIME', []) if x['name'] == '$SHOTS_DEVICE']
print(found[0] if len(found) == 1 else '')")"
[ -n "$UDID" ] || { red "need exactly one available '$SHOTS_DEVICE' on $SHOTS_RUNTIME; found none, or several"; exit 1; }

mkdir "$LOCK_DIR" 2>/dev/null || { red "$LOCK_DIR is taken: another run is using $SHOTS_DEVICE"; exit 1; }
was_booted=0
build_locked=0
cleanup() {
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  [ "$was_booted" = 1 ] || xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  [ "$build_locked" = 0 ] || build_lock_release "$DD.lock"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
if pgrep -f "xcodebuild.*$UDID" >/dev/null; then red "an xcodebuild run is using $SHOTS_DEVICE"; exit 1; fi

if xcrun simctl list devices --json | python3 -c "
import json, sys
sys.exit(0 if any(x['udid'] == '$UDID' and x['state'] == 'Booted'
                  for rs in json.load(sys.stdin)['devices'].values() for x in rs) else 1)"; then
  was_booted=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || { red "$SHOTS_DEVICE did not boot"; exit 1; }
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4

# **Derived data OUTSIDE the repo.** This project lives in an iCloud-synced folder,
# and iCloud writes extended attributes onto everything under it. Building into
# `build/shots-dd` therefore fails at the very last step with "resource fork, Finder
# information, or similar detritus not allowed" — a code-signing error whose message
# says nothing about iCloud, arriving after a full compile.
DD="${TMPDIR:-/tmp}soundpost-screenshots-dd"
# Swift packages (~1.9 GB of Sentry) come from the shared checkout in
# ~/Library/Caches/Soundpost-build, not from a copy inside $DD: scripts/lib/build_cache.sh.
# shellcheck source=lib/build_cache.sh
source "$PROJECT_DIR/scripts/lib/build_cache.sh"
# One run at a time in $DD: it is per $TMPDIR, not per checkout, so two checkouts would
# otherwise share its build.db, and one's wipe-and-retry would delete the other's root. Held
# until exit, since the app is installed from $DD.
build_lock_take "$DD.lock" "screenshots.sh in $PROJECT_DIR" || exit 1
build_locked=1
local_build_args "$PROJECT_DIR" -derivedDataPath "$DD" || exit 1

# macOS periodically empties $TMPDIR, and it does not do so atomically — it can leave
# a half-deleted `SourcePackages/artifacts` tree behind. The next build then fails with
# "There is no Info.plist found at .../Sentry.xcframework/Info.plist", which names a
# dependency and says nothing about the cache, and reads like a broken checkout. Hit
# twice in one afternoon. So: one wipe-and-retry, and only then believe the failure.
# (With the shared package checkout the packages are no longer in $DD; the retry still
# covers a half-purged Build tree, and it resolves into $DD in case the shared checkout is
# the damaged one.)
build_once() {
  xcodebuild build -project "$PROJECT_DIR/Soundpost.xcodeproj" -scheme Soundpost \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DD" ${LOCAL_BUILD_ARGS[@]+"${LOCAL_BUILD_ARGS[@]}"} \
    > "$BUILD_LOG" 2>&1
}

printf '  building…\n'
if ! build_once; then
  printf '  build failed; wiping derived data and retrying once…\n'
  rm -rf "$DD"
  local_build_retry_args "$PROJECT_DIR"
  build_once || { red "build failed twice — see $BUILD_LOG"; exit 1; }
fi
APP="$DD/Build/Products/Debug-iphonesimulator/Soundpost.app"
[ -d "$APP" ] || { red "no app bundle at $APP"; exit 1; }

xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

for locale in "${LOCALES[@]}"; do
  # `ja`, not `ja-JP`: the app's catalogue keys are the two-letter codes, and a
  # region-qualified language that the bundle does not carry falls back to English
  # silently — a whole locale's screenshots in the wrong language, with nothing
  # reporting it. Verified per shot below instead of trusted.
  lang="${locale%%-*}"
  # Emptied first, so nothing from an earlier run is mistaken for this one's — 1.9.0's
  # capture shot still showed a Pro upsell after Pro was hidden. (`asc.py screenshots`
  # now also refuses any name it does not expect, M23 §4B.4.) $OUT is never in build/.
  rm -rf "${OUT:?}/$locale"
  mkdir -p "$OUT/$locale"
  for screen in "${SCREENS[@]}"; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" \
      -seedSampleData -screenshotScreen "$screen" \
      -AppleLanguages "($lang)" -AppleLocale "$locale" >/dev/null
    file="$OUT/$locale/$(printf '%02d' $(( $(echo "${SCREENS[@]}" | tr ' ' '\n' | grep -n "^$screen$" | cut -d: -f1) )))-$screen.png"

    # **Poll until the app has drawn, rather than sleeping and hoping.**
    #
    # The first version slept four seconds and shot. The first two launches after an
    # install are slower than that — the demo library is seeded on the first one — so
    # it produced two perfectly-sized, completely black PNGs and reported success,
    # because the only check was `sips -g pixelWidth`. A blank frame satisfies a
    # dimension check exactly as well as a rendered gallery does.
    #
    # So the loop shoots, measures the image, and keeps going until there is something
    # in it. Sheets animate in and the gallery lays out; a screenshot taken
    # mid-transition is the kind of thing nobody notices until it is on the store page,
    # and one extra settled second after content appears costs nothing.
    drawn=0
    for attempt in $(seq 1 20); do
      sleep 1
      xcrun simctl io "$UDID" screenshot "$file" >/dev/null 2>&1 || continue
      if python3 "$PROJECT_DIR/scripts/screenshot_check.py" "$file" 2>/dev/null; then
        sleep 1
        xcrun simctl io "$UDID" screenshot "$file" >/dev/null 2>&1
        drawn=1
        break
      fi
    done
    if [ "$drawn" -ne 1 ]; then
      red "$locale/$screen never drew anything — 20s of blank frames"
      python3 "$PROJECT_DIR/scripts/screenshot_check.py" "$file" || true
      exit 1
    fi

    dims="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s", $2 " "}')"
    if [ "$dims" != "$WANT_DIMS" ]; then
      red "$file is ${dims}— App Store Connect wants ${WANT_DIMS}for $DISPLAY_TYPE (scripts/asc_policy.py)"
      exit 1
    fi
  done
  ok "$locale — ${#SCREENS[@]} screens"
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
# Count what landed. Every failure this script has had so far — the blank frames, the
# collapsed locale array — reported success, because nothing counted the output
# against what was asked for.
#
# Only the locales asked for. Counting all of $OUT made a correct single-locale run
# (`screenshots.sh ja`) fail every time on the other locales' files — and a red that is
# always red is one people learn to ignore.
want=$(( ${#LOCALES[@]} * ${#SCREENS[@]} ))
got=0
for locale in "${LOCALES[@]}"; do
  got=$(( got + $(find "$OUT/$locale" -name '*.png' | wc -l | tr -d ' ') ))
done
if [ "$got" -ne "$want" ]; then
  red "$got screenshots, expected $want (${#LOCALES[@]} locales x ${#SCREENS[@]} screens)"
  exit 1
fi
others=$(find "$OUT" -mindepth 1 -maxdepth 1 -type d | while read -r d; do
  keep=0; for locale in "${LOCALES[@]}"; do [ "$(basename "$d")" = "$locale" ] && keep=1; done
  [ "$keep" = 0 ] && basename "$d"
done | tr '\n' ' ')
if [ -n "$others" ]; then
  printf '  note: %s in %s were not captured by this run, and `asc.py screenshots` uploads them too.\n' "$others" "$OUT"
fi
ok "$got screenshots in $OUT — upload them with \`asc.py screenshots\`."
