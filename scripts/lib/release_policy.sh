#!/bin/bash
# Sourced, never run: the release path's decisions, where tests can reach them (M23 §4B.0).
# Bash 3.2 (macOS /bin/bash). `scripts/test_gates.py` drives each function directly
# (`bash -c 'source …; fn …'`) and asserts its messages, so a fixture fails against old
# behaviour for the reason under test — never because an ASC key or a keychain is missing.
#
# Callers: scripts/release-preflight.sh and scripts/build-upload-asc.sh.
#
#   default_archive_path ROOT VERSION BUILD DATE
#       ROOT/DATE/Soundpost VERSION (BUILD).xcarchive — Xcode's Organizer layout, outside
#       ~/Documents. 1.12.0's app bundle vanished from the iCloud-synced build/ (M23 §3.8).
#   archive_plan ROOT VERSION BUILD DATE
#       Prints the path to archive into, or refuses (status 1) when an archive of this
#       version and build already records a SUCCESSFUL upload. Never refuses for a mere
#       existing path: a failed attempt gets the next free name, and nothing is overwritten.
#   archive_records_upload ARCHIVE
#       Status 0 when the archive's Info.plist records `destination = upload` with
#       `uploadEvent.state = success`.
#   allow_validate / allow_has CHECK
#       RELEASE_PREFLIGHT_ALLOW=<check>[,<check>] — only copies, keychain, build-number.
#   legacy_override_refused
#       Status 0 (and a message) when the retired RELEASE_PREFLIGHT_OVERRIDE is set.
#   tree_is_dirty DIR
#       Status 0 when the checkout is dirty (or git cannot say), printing the lines that
#       make it so; status 1 when clean. Untracked entries under .claude/ do not count.
#   copy_scan DIR [SCREENSHOT_DIR]
#       iCloud conflict copies in what ships. 0 none, 1 found (printed), 2 cannot scan.
#   should_push_tag MODE
#   sentry_token_problem
#       Prints why SENTRY_AUTH_TOKEN cannot upload dSYMs, or nothing.
#   sentry_probe_verdict HTTP_CODE / sentry_probe
#       401 is fatal (status 1); 403 and network errors warn (status 2); 2xx passes.

RELEASE_ALLOW_NAMES="copies keychain build-number"

default_archive_path() {
  printf '%s/%s/Soundpost %s (%s).xcarchive\n' "$1" "$4" "$2" "$3"
}

archive_records_upload() {
  [ -f "$1/Info.plist" ] || return 1
  python3 - "$1/Info.plist" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        info = plistlib.load(f)
except Exception:
    sys.exit(1)          # unreadable: a half-written attempt, not an uploaded build
for d in info.get("Distributions") or []:
    if d.get("destination") == "upload" and (d.get("uploadEvent") or {}).get("state") == "success":
        sys.exit(0)
sys.exit(1)
PY
}

# Every existing archive of VERSION (BUILD) under ROOT's dated folders, one per line.
_archives_of() {
  local root="$1" version="$2" build="$3" a
  [ -d "$root" ] || return 0
  for a in "$root"/*/"Soundpost $version ($build)"*.xcarchive; do
    [ -e "$a" ] && printf '%s\n' "$a"
  done
  return 0
}

archive_plan() {
  local root="$1" version="$2" build="$3" date="$4"
  local existing a n name taken
  if [ -z "$root" ] || [ -z "$version" ] || [ -z "$build" ] || [ -z "$date" ]; then
    echo "archive_plan: needs ROOT VERSION BUILD DATE" >&2
    return 1
  fi
  existing="$(_archives_of "$root" "$version" "$build")"
  if [ -n "$existing" ]; then
    while IFS= read -r a; do
      if archive_records_upload "$a"; then
        echo "REFUSED: $version ($build) was already uploaded to App Store Connect —" >&2
        echo "         $a records a successful upload." >&2
        echo "         Raise CURRENT_PROJECT_VERSION; never archive over an uploaded build." >&2
        return 1
      fi
    done <<EOF
$existing
EOF
  fi
  name="Soundpost $version ($build).xcarchive"
  if [ -z "$existing" ] && [ ! -e "$root/$date/$name" ]; then
    default_archive_path "$root" "$version" "$build" "$date"
    return 0
  fi
  n=2
  while :; do
    name="Soundpost $version ($build) - attempt $n.xcarchive"
    taken=""
    for a in "$root"/*/"$name"; do [ -e "$a" ] && taken=1; done
    [ -z "$taken" ] && break
    n=$((n + 1))
  done
  echo "  · earlier attempts of $version ($build) are left as they are:" >&2
  printf '%s\n' "$existing" | sed 's/^/      /' >&2
  printf '%s/%s/%s\n' "$root" "$date" "$name"
}

legacy_override_refused() {
  [ -n "${RELEASE_PREFLIGHT_OVERRIDE:-}" ] || return 1
  echo "ERROR: RELEASE_PREFLIGHT_OVERRIDE is retired (M23 §4B.3): it skipped every check at once," >&2
  echo "       and also the HEAD guard and the dSYM step after the archive." >&2
  echo "       Name the one check you mean to go past instead:" >&2
  echo "         RELEASE_PREFLIGHT_ALLOW=<check>[,<check>]   (checks: ${RELEASE_ALLOW_NAMES// /, })" >&2
  echo "       Nothing allows a dirty tree, a moved HEAD or an upload without dSYMs in Sentry." >&2
  return 0
}

allow_validate() {
  local raw="${RELEASE_PREFLIGHT_ALLOW:-}" name ok known bad=""
  [ -n "$raw" ] || return 0
  for name in $(printf '%s' "$raw" | tr ',' ' '); do
    ok=""
    for known in $RELEASE_ALLOW_NAMES; do [ "$name" = "$known" ] && ok=1; done
    if [ -z "$ok" ]; then
      bad=1
      case "$name" in
        dirty)  echo "ERROR: RELEASE_PREFLIGHT_ALLOW=dirty is not a check you can go past: an upload's HEAD/clean guard decides after the archive anyway." >&2 ;;
        sentry) echo "ERROR: RELEASE_PREFLIGHT_ALLOW=sentry is not a check you can go past: an upload requires its dSYMs in Sentry." >&2 ;;
        *)      echo "ERROR: RELEASE_PREFLIGHT_ALLOW names an unknown check '$name' (known: ${RELEASE_ALLOW_NAMES// /, })." >&2 ;;
      esac
    fi
  done
  [ -z "$bad" ]
}

allow_has() {
  local name
  for name in $(printf '%s' "${RELEASE_PREFLIGHT_ALLOW:-}" | tr ',' ' '); do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

tree_is_dirty() {
  local dir="$1" out
  if ! out="$(git -C "$dir" status --porcelain --untracked-files=all 2>&1)"; then
    echo "git status failed in $dir — cannot tell whether the tree is clean: $out"
    return 0
  fi
  # Untracked (`??`) entries under .claude/ are other sessions' locks and worktrees, never
  # built. A pathspec exclude would also hide TRACKED changes there, so filter lines instead.
  # Porcelain quotes a path with spaces: `?? ".claude/x 2.lock"`.
  out="$(printf '%s\n' "$out" | grep -Ev '^\?\? "?\.claude/' | grep -v '^$' || true)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

copy_scan() {
  local dir="$1" shots="${2:-}" lib roots root missing="" paths=() found
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if ! roots="$(python3 "$lib/project_model.py" --project "$dir" roots --kinds app,appex,test,other 2>&1)"; then
    echo "the project reader failed, so the copy scan cannot know what ships: $roots"
    return 2
  fi
  if [ -z "$roots" ]; then
    echo "the project reader named no source roots, so the copy scan would see nothing"
    return 2
  fi
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ -d "$dir/$root" ]; then paths+=("$dir/$root"); else missing="$missing $root"; fi
  done <<EOF
$roots
EOF
  for root in metadata scripts backend; do
    if [ -d "$dir/$root" ]; then paths+=("$dir/$root"); else missing="$missing $root/"; fi
  done
  for root in "$dir"/*.xcodeproj; do
    [ -d "$root" ] && paths+=("$root")
  done
  if [ -n "$missing" ]; then
    echo "required scan root(s) missing:$missing — a scan of nothing is not a clean scan"
    return 2
  fi
  [ -n "$shots" ] && [ -d "$shots" ] && paths+=("$shots")
  # Any copy number, not only " 2": with `Foo 2.swift` present, the next is `Foo 3.swift`.
  # A sibling `Soundpost 2.xcodeproj` is caught too (one level, top of the tree).
  found="$( { find -E "${paths[@]}" -name .claude -prune -o -regex '.* [0-9]+(\.[^/]*)?' -print 2>/dev/null
              find -E "$dir" -mindepth 1 -maxdepth 1 -regex '.* [0-9]+\.xcodeproj' -print 2>/dev/null; } | sort -u)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 1
  fi
  return 0
}

should_push_tag() {
  [ "$1" = "upload" ]
}

sentry_token_problem() {
  if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "sentry-cli is not installed (brew install getsentry/tools/sentry-cli)"
  elif [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "SENTRY_AUTH_TOKEN is not set — agent shells do not read ~/.zshrc: eval \"\$(grep -E '^export SENTRY_' ~/.zshrc)\""
  elif [ "${SENTRY_AUTH_TOKEN#<}" != "$SENTRY_AUTH_TOKEN" ]; then
    echo "SENTRY_AUTH_TOKEN starts with '<' — it was pasted with its angle brackets"
  fi
}

sentry_probe_verdict() {
  case "$1" in
    2[0-9][0-9]) return 0 ;;
    401)         return 1 ;;
    *)           return 2 ;;
  esac
}

# The organization's chunk-upload options: the first thing `sentry-cli debug-files upload`
# asks for, so a token that cannot read them cannot upload. Prints the HTTP code ("000"
# for a network error) and returns the verdict.
sentry_probe() {
  local org="${SENTRY_ORG:-jason-yeyuhe}" url="${SENTRY_URL:-https://sentry.io}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
           -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN:-}" \
           "${url%/}/api/0/organizations/$org/chunk-upload/" 2>/dev/null)" || true
  [ -n "$code" ] || code="000"
  printf '%s\n' "$code"
  sentry_probe_verdict "$code"
}
