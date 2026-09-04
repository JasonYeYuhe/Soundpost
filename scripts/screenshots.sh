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
# WHAT IT PRODUCES. `APP_IPHONE_65`, 1242x2688, five screens, three locales — read
# from App Store Connect on 2026-09-05 rather than assumed, because a wrong size is a
# rejected submission and not a cosmetic problem:
#
#     en-US / ja / zh-Hans : 1 set each, APP_IPHONE_65, 5 images, 1242 x 2688
#
# iPhone 11 Pro Max is the device type that renders exactly that. Verified, not
# assumed: a booted one screenshots at 1242x2688 on iOS 26.5.
#
# WHAT IT DOES NOT DO. Upload. `asc.py` has no screenshot command and adding one is
# an open decision (§8). The files land in `build/screenshots/<locale>/` for a human
# to drag into App Store Connect, or for a future `asc.py screenshots` to read.
#
# Usage:
#   scripts/screenshots.sh              # all locales, all screens
#   scripts/screenshots.sh ja           # one locale
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_NAME="Soundpost-Shots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"
BUNDLE_ID="com.soundpost.Soundpost"
OUT="$PROJECT_DIR/build/screenshots"
SCREENS=(gallery detail search capture settings)
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

red()  { printf '\033[31m%s\033[0m\n' "$1" >&2; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# The newest available iOS runtime, rather than a pinned one that ages out.
RUNTIME="$(xcrun simctl list runtimes --json \
  | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]]; print(sorted(rs, key=lambda r: r["version"])[-1]["identifier"])')"

UDID="$(xcrun simctl list devices --json \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for rs in d.values() for x in rs if x['name']=='$DEVICE_NAME'), ''))")"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
  printf '  created %s (%s)\n' "$DEVICE_NAME" "$UDID"
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# **Derived data OUTSIDE the repo.** This project lives in an iCloud-synced folder,
# and iCloud writes extended attributes onto everything under it. Building into
# `build/shots-dd` therefore fails at the very last step with "resource fork, Finder
# information, or similar detritus not allowed" — a code-signing error whose message
# says nothing about iCloud, arriving after a full compile.
DD="${TMPDIR:-/tmp}soundpost-screenshots-dd"

printf '  building…\n'
xcodebuild build -project "$PROJECT_DIR/Soundpost.xcodeproj" -scheme Soundpost \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DD" > "$PROJECT_DIR/build/shots-build.log" 2>&1 \
  || { red "build failed — see build/shots-build.log"; exit 1; }
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
    if [ "$dims" != "1242 2688 " ]; then
      red "$file is ${dims}— App Store Connect wants 1242 2688 for APP_IPHONE_65"
      exit 1
    fi
  done
  ok "$locale — ${#SCREENS[@]} screens"
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
# Count what landed. Every failure this script has had so far — the blank frames, the
# collapsed locale array — reported success, because nothing counted the output
# against what was asked for.
want=$(( ${#LOCALES[@]} * ${#SCREENS[@]} ))
got=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
if [ "$got" -ne "$want" ]; then
  red "$got screenshots, expected $want (${#LOCALES[@]} locales x ${#SCREENS[@]} screens)"
  exit 1
fi
ok "$got screenshots in $OUT — upload them in App Store Connect (§8)."
