#!/bin/bash
set -uo pipefail

# Release preflight (M20 §4B; M23 §4B.3). Run by build-upload-asc.sh before it archives;
# also runnable on its own to see where a release stands.
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
# It reports every failure, not just the first, then refuses. To go past ONE named check:
#
#   RELEASE_PREFLIGHT_ALLOW=copies,keychain ./scripts/build-upload-asc.sh
#
# Only `copies`, `keychain` and `build-number` can be named. The clean tree and the Sentry
# token cannot: for an upload, the post-archive HEAD/clean guard and the dSYM step decide
# anyway, and no name reaches them. The old all-or-nothing RELEASE_PREFLIGHT_OVERRIDE is
# refused — 1.11.0 and 1.12.0 both shipped under it because of one untracked lock file.
#
# What "clean" means (scripts/lib/release_policy.sh `tree_is_dirty`): every line of
# `git status --porcelain --untracked-files=all` except untracked entries under .claude/.
# `GATE_PROJECT_DIR` points the checks at another tree (its tests use fixtures).

MODE="${1:-upload}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${GATE_PROJECT_DIR:-$(cd "$SCRIPTS/.." && pwd)}"
# shellcheck source=lib/release_policy.sh
source "$SCRIPTS/lib/release_policy.sh"
# Outside /tmp, which macOS empties; the daily cleanup job keeps it (its `.no-sweep`).
ASC_VENV_DEFAULT="$HOME/Library/Caches/Soundpost-build/asc-venv"
if [ -z "${ASC_PYTHON:-}" ]; then
  ASC_PYTHON="$ASC_VENV_DEFAULT/bin/python3"
  [ -x "$ASC_PYTHON" ] || [ ! -x /tmp/asc-venv/bin/python3 ] || ASC_PYTHON=/tmp/asc-venv/bin/python3
fi
PBXPROJ="$PROJECT_DIR/Soundpost.xcodeproj/project.pbxproj"

case "$MODE" in
  upload|archive) ;;
  *) echo "ERROR: unknown mode '$MODE' (upload or archive)" >&2; exit 2 ;;
esac
if legacy_override_refused; then exit 1; fi
allow_validate || exit 1

failures=()
allowed=()
fail() { failures+=("$1"); printf '  ✘ %s\n' "$1"; }
pass() { printf '  ✔ %s\n' "$1"; }
# A check that RELEASE_PREFLIGHT_ALLOW may name: reported either way, counted only if not allowed.
fail_or_allow() {
  if allow_has "$1"; then
    allowed+=("$1: ${2%%$'\n'*}")
    printf '  ! %s (allowed: RELEASE_PREFLIGHT_ALLOW=%s)\n' "$2" "$1"
  else
    fail "$2"
  fi
}

project_setting() {
  grep -E "^[[:space:]]*$1 = " "$PBXPROJ" | sed -E 's/.*= "?([^";]*)"?;.*/\1/' | sort -u
}

echo "==> Release preflight ($MODE)"

VERSION="$(project_setting MARKETING_VERSION 2>/dev/null)"
BUILD="$(project_setting CURRENT_PROJECT_VERSION 2>/dev/null)"
if [ "$(printf '%s\n' "$VERSION" | grep -c .)" -ne 1 ] || [ "$(printf '%s\n' "$BUILD" | grep -c .)" -ne 1 ]; then
  fail "the project does not hold one MARKETING_VERSION and one CURRENT_PROJECT_VERSION (got '$VERSION' / '$BUILD')"
else
  pass "project is $VERSION ($BUILD)"
fi

# ── iCloud conflict copies, in what ships ────────────────────────────────────
# The project's source roots (from the project file), the .xcodeproj, metadata/, scripts/,
# backend/ — each required to exist — and the screenshot folder if there is one. Not the
# whole checkout: other sessions' files under .claude/ never build, and a scan of them
# blocked 1.12.0 (M23 §4B.3).
SHOT_DIR="$(python3 -c "import sys; sys.path.insert(0, '$SCRIPTS'); import asc_policy; print(asc_policy.screenshot_dir())" 2>/dev/null || true)"
copies="$(copy_scan "$PROJECT_DIR" "$SHOT_DIR")"
case $? in
  0) pass "no iCloud conflict copies" ;;
  1) fail_or_allow copies "iCloud conflict copies would compile into the build or reach the store:
$(printf '%s\n' "$copies" | sed 's/^/        /')" ;;
  *) fail "the copy scan could not run: $copies" ;;
esac

# ── Signing: is the keychain usable right now? ────────────────────────────────
console_locked="$(ioreg -n Root -d1 -a 2>/dev/null | grep -A1 IOConsoleLocked | grep -c '<true/>' || true)"
[ "$console_locked" = "1" ] && echo "  · the console is locked (screen lock); signing may still work — the probe decides"
keychain="$HOME/Library/Keychains/login.keychain-db"
keychain_info="$(security show-keychain-info "$keychain" 2>&1)"
if printf '%s' "$keychain_info" | grep -q 'User interaction is not allowed'; then
  fail_or_allow keychain "the login keychain is locked (unlock the Mac, then re-run)"
else
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Distribution/{print $2; exit}')"
  [ -z "$identity" ] && identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/{print $2; exit}')"
  if [ -z "$identity" ]; then
    fail_or_allow keychain "no Apple Distribution or Apple Development identity in the keychain search list"
  else
    probe_dir="$(mktemp -d)"
    cp /bin/echo "$probe_dir/sigtest"
    if codesign -f -s "$identity" "$probe_dir/sigtest" >"$probe_dir/log" 2>&1; then
      pass "codesign works (one-second probe)"
    else
      fail_or_allow keychain "codesign probe failed: $(tail -1 "$probe_dir/log") — the keychain will not sign; unlock the Mac"
    fi
    rm -rf "$probe_dir"
  fi
fi

if [ "$MODE" = "upload" ]; then
  # ── Clean tree ──────────────────────────────────────────────────────────────
  # Fail closed: `tree_is_dirty` treats a git that cannot answer as dirty.
  if dirty="$(tree_is_dirty "$PROJECT_DIR")"; then
    fail "the working tree is not clean — the binary would not be any commit:
$(printf '%s\n' "$dirty" | head -20 | sed 's/^/        /')"
  elif ! head_sha="$(git -C "$PROJECT_DIR" rev-parse --verify --short HEAD 2>/dev/null)" || [ -z "$head_sha" ]; then
    fail "git cannot resolve HEAD — the binary would not be any commit"
  else
    pass "working tree clean at $head_sha (untracked files under .claude/ do not count)"
  fi

  # ── Build number ────────────────────────────────────────────────────────────
  if [ ! -x "$ASC_PYTHON" ]; then
    fail_or_allow build-number "no ASC venv at $ASC_PYTHON — rebuild it:
        python3 -m venv \"$ASC_VENV_DEFAULT\" && \"$ASC_VENV_DEFAULT/bin/python3\" -m pip install \"pyjwt[crypto]\" requests && touch \"$ASC_VENV_DEFAULT/.no-sweep\""
  elif out="$("$ASC_PYTHON" "$SCRIPTS/asc.py" check-build-number "$BUILD" 2>&1)"; then
    pass "$out"
  else
    fail_or_allow build-number "$out"
  fi

  # ── Sentry: this build's crashes must symbolicate ───────────────────────────
  problem="$(sentry_token_problem)"
  if [ -n "$problem" ]; then
    fail "$problem"
  else
    pass "Sentry token present (${#SENTRY_AUTH_TOKEN} chars)"
  fi
fi

if [ "${#allowed[@]}" -gt 0 ]; then
  echo "!!! RELEASE_PREFLIGHT_ALLOW — going past ${#allowed[@]} named check(s):"
  for f in "${allowed[@]}"; do printf '!!!   - %s\n' "$f"; done
fi
if [ "${#failures[@]}" -eq 0 ]; then
  echo "==> Preflight passed."
  exit 0
fi

echo
echo "ERROR: refusing to $MODE — ${#failures[@]} preflight check(s) failed (listed above)."
echo "       Only copies, keychain and build-number can be named in RELEASE_PREFLIGHT_ALLOW."
exit 1
