#!/bin/bash
set -uo pipefail

# Release preflight (M20 §4B). Run by build-upload-asc.sh before it archives; also
# runnable on its own to see where a release stands.
#
#   ./scripts/release-preflight.sh           # upload: every check
#   ./scripts/release-preflight.sh archive   # local archive only: iCloud copies + signing
#
# Every check here stands for a release that already went wrong, or nearly did:
#   - a dirty tree       → the binary is not any commit; nothing can reproduce it
#   - `X 2.swift` files  → iCloud conflict copies compile into the build, because the
#                          project uses file-system-synchronized groups
#   - a locked keychain  → codesign dies 20 minutes into an archive with
#                          errSecInternalComponent (Stride 1.2.1, 2026-09-08)
#   - a reused build no. → App Store Connect refuses it only after the upload
#   - no Sentry token    → 1.6.0, 1.6.1 and 1.6.2 shipped with no dSYMs in Sentry
#
# It reports every failure, not just the first, then refuses. One override, loud on
# purpose, modelled on CK_SKIP_SCHEMA_CHECK:
#
#   RELEASE_PREFLIGHT_OVERRIDE=yes ./scripts/build-upload-asc.sh
#
# The same override also lets build-upload-asc.sh continue past a failed dSYM upload.

MODE="${1:-upload}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASC_PYTHON="${ASC_PYTHON:-/tmp/asc-venv/bin/python3}"
PBXPROJ="$PROJECT_DIR/Soundpost.xcodeproj/project.pbxproj"

failures=()
fail() { failures+=("$1"); printf '  ✘ %s\n' "$1"; }
pass() { printf '  ✔ %s\n' "$1"; }

project_setting() {
  grep -E "^[[:space:]]*$1 = " "$PBXPROJ" | sed -E 's/.*= ([^;]*);.*/\1/' | sort -u
}

echo "==> Release preflight ($MODE)"

VERSION="$(project_setting MARKETING_VERSION)"
BUILD="$(project_setting CURRENT_PROJECT_VERSION)"
if [ "$(printf '%s\n' "$VERSION" | grep -c .)" -ne 1 ] || [ "$(printf '%s\n' "$BUILD" | grep -c .)" -ne 1 ]; then
  fail "the project does not hold one MARKETING_VERSION and one CURRENT_PROJECT_VERSION (got '$VERSION' / '$BUILD')"
else
  pass "project is $VERSION ($BUILD)"
fi

# ── iCloud conflict copies ────────────────────────────────────────────────────
# Any copy number, not only " 2": with `Foo 2.swift` already present, the next copy
# is `Foo 3.swift`.
copies="$(find -E "$PROJECT_DIR" \( -path "$PROJECT_DIR/.git" -o -path "$PROJECT_DIR/build" \) -prune \
          -o -regex '.* [0-9]+(\.[^/]*)?' -print 2>/dev/null)"
if [ -n "$copies" ]; then
  fail "iCloud conflict copies would compile into the build:"
  printf '%s\n' "$copies" | sed 's/^/        /'
else
  pass "no iCloud conflict copies"
fi

# ── Signing: is the keychain usable right now? ────────────────────────────────
console_locked="$(ioreg -n Root -d1 -a 2>/dev/null | grep -A1 IOConsoleLocked | grep -c '<true/>' || true)"
[ "$console_locked" = "1" ] && echo "  · the console is locked (screen lock); signing may still work — the probe decides"
keychain="$HOME/Library/Keychains/login.keychain-db"
keychain_info="$(security show-keychain-info "$keychain" 2>&1)"
if printf '%s' "$keychain_info" | grep -q 'User interaction is not allowed'; then
  fail "the login keychain is locked (unlock the Mac, then re-run)"
else
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Distribution/{print $2; exit}')"
  [ -z "$identity" ] && identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/{print $2; exit}')"
  if [ -z "$identity" ]; then
    fail "no Apple Distribution or Apple Development identity in the keychain search list"
  else
    probe_dir="$(mktemp -d)"
    cp /bin/echo "$probe_dir/sigtest"
    if codesign -f -s "$identity" "$probe_dir/sigtest" >"$probe_dir/log" 2>&1; then
      pass "codesign works (one-second probe)"
    else
      fail "codesign probe failed: $(tail -1 "$probe_dir/log") — the keychain will not sign; unlock the Mac"
    fi
    rm -rf "$probe_dir"
  fi
fi

if [ "$MODE" = "upload" ]; then
  # ── Clean tree ──────────────────────────────────────────────────────────────
  # Fail closed: a git that cannot answer prints nothing, which must not read as clean.
  if ! dirty="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)"; then
    fail "git status failed — cannot tell whether the tree is clean"
  elif [ -n "$dirty" ]; then
    fail "the working tree is not clean — the binary would not be any commit:"
    printf '%s\n' "$dirty" | head -20 | sed 's/^/        /'
  elif ! head_sha="$(git -C "$PROJECT_DIR" rev-parse --verify --short HEAD 2>/dev/null)" || [ -z "$head_sha" ]; then
    fail "git cannot resolve HEAD — the binary would not be any commit"
  else
    pass "working tree clean at $head_sha"
  fi

  # ── Build number ────────────────────────────────────────────────────────────
  if [ ! -x "$ASC_PYTHON" ]; then
    fail "no ASC venv at $ASC_PYTHON (macOS empties /tmp) — rebuild:
        python3 -m venv /tmp/asc-venv && /tmp/asc-venv/bin/python3 -m pip install \"pyjwt[crypto]\" requests"
  elif out="$("$ASC_PYTHON" "$PROJECT_DIR/scripts/asc.py" check-build-number "$BUILD" 2>&1)"; then
    pass "$out"
  else
    fail "$out"
  fi

  # ── Sentry: this build's crashes must symbolicate ───────────────────────────
  if ! command -v sentry-cli >/dev/null 2>&1; then
    fail "sentry-cli is not installed (brew install getsentry/tools/sentry-cli)"
  elif [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    fail "SENTRY_AUTH_TOKEN is not set — agent shells do not read ~/.zshrc:
        eval \"\$(grep -E '^export SENTRY_' ~/.zshrc)\""
  elif [ "${SENTRY_AUTH_TOKEN#<}" != "$SENTRY_AUTH_TOKEN" ]; then
    fail "SENTRY_AUTH_TOKEN starts with '<' — it was pasted with its angle brackets"
  else
    pass "Sentry token present (${#SENTRY_AUTH_TOKEN} chars)"
  fi
fi

if [ "${#failures[@]}" -eq 0 ]; then
  echo "==> Preflight passed."
  exit 0
fi

echo
if [ "${RELEASE_PREFLIGHT_OVERRIDE:-}" = "yes" ]; then
  echo "!!! RELEASE_PREFLIGHT_OVERRIDE=yes — continuing WITHOUT ${#failures[@]} check(s):"
  for f in "${failures[@]}"; do printf '!!!   - %s\n' "${f%%$'\n'*}"; done
  exit 0
fi
echo "ERROR: refusing to $MODE — ${#failures[@]} preflight check(s) failed (listed above)."
echo "       To go ahead regardless: RELEASE_PREFLIGHT_OVERRIDE=yes $0 $MODE"
exit 1
