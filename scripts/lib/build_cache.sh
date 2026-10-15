#!/bin/bash
# Sourced, never run: the Swift package checkout that local xcodebuild runs in scripts/ share.
# Adapted from Stride's scripts/ci/build_cache.sh (Stride 63e5689). Bash 3.2 (macOS /bin/bash).
#
# WHY THIS EXISTS. About 1.9 GB of every ~2.2 GB Soundpost derived-data root is SourcePackages,
# nearly all of it sentry-cocoa's five xcframeworks (the app links one of them). screenshots.sh
# and check-debug-only.sh each unpacked all five again into their own root under $TMPDIR, and
# macOS purges $TMPDIR, so most runs started cold (measured 2026-10-14, trash-inflow P7a).
#
#   local_build_args <project dir> [the caller's xcodebuild args...]
#     Sets the array LOCAL_BUILD_ARGS, for the caller to splice into its xcodebuild line as
#     ${LOCAL_BUILD_ARGS[@]+"${LOCAL_BUILD_ARGS[@]}"} (a bare "${LOCAL_BUILD_ARGS[@]}" of an
#     empty array is an unbound-variable error under bash 3.2's set -u):
#       COMPILER_INDEX_STORE_ENABLE=NO   nothing ever opens these roots in Xcode
#       -clonedSourcePackagesDirPath <dir> -disableAutomaticPackageResolution
#     after making sure <dir> holds a finished resolve for <project dir>, and sets
#     LOCAL_SPM_DIR to <dir> (empty when the package flags are left out). With CI set,
#     LOCAL_BUILD_ARGS is empty, so ci.yml's builds run exactly as before. The package flags
#     alone are left out (xcodebuild resolves into the derived data, as before) when:
#       - SOUNDPOST_SPM_DIR=off;
#       - the caller's args already name -clonedSourcePackagesDirPath;
#       - $TMPDIR is not the user's default (below);
#       - the project has no Package.resolved;
#       - the resolve fails (printed as a warning, with its log): no network, or a
#         Package.resolved that no longer satisfies the project's package requirements.
#     A -derivedDataPath among the caller's args is passed to the resolve too (with -scheme
#     Soundpost, without which xcodebuild refuses it: rc 64, 2026-10-15), so the resolve leaves its
#     logs there rather than in the checkout's default DerivedData. Returns 1 only when another
#     process holds the resolve lock for too long. Call it in the same shell as the build:
#     LOCAL_BUILD_ARGS is a shell variable, and a warm call costs one sha256.
#
#   local_build_retry_args <project dir> [args...]
#     For a caller's wipe-and-retry: local_build_args without the shared directory, and a note
#     naming it. A damaged one (its marker still there over a half-deleted artifacts/) fails
#     every build, wiping the derived data does not touch it, and
#     -disableAutomaticPackageResolution stops xcodebuild from repairing it.
#
#   build_lock_take <lock dir> <what> / build_lock_release <lock dir>
#     The scripts' lock on their own derived data (<derived data>.lock), so two checkouts never
#     build into one build.db at once and one's wipe-and-retry cannot delete the other's root.
#     Release only from the script's EXIT trap: it first stops every child of the calling shell
#     (on a signal bash runs the EXIT trap at once while its foreground xcodebuild keeps going),
#     so never call it from an interactive shell with jobs of its own.
#
# The package directory: ~/Library/Caches/Soundpost-build/SourcePackages-<8 hex>, the sha256 of
# Package.resolved plus the project's package references (project.pbxproj's
# XCRemote/XCLocalSwiftPackageReference sections). That is NOT the global CLAUDE.md default
# (the first 8 of Package.resolved's sha alone), which is why CLAUDE.md here names the
# directory by the command that prints it. Never under ~/Documents (iCloud; codesign
# trips on its xattrs) and never under $TMPDIR (purged, and not atomically: the half-deleted
# `SourcePackages/artifacts` that both scripts' wipe-and-retry was written for). Keying by both
# files means a branch that bumps Sentry gets its own directory instead of re-resolving the one
# every other checkout builds from, and a requirement change without a matching Package.resolved
# gets a fresh resolve (which fails, and so falls back) instead of a build against the old
# checkout. SOUNDPOST_SPM_DIR=<dir> overrides the location; that directory is re-resolved
# whenever the key changes, so never share one between trees that differ in packages.
#
# Resolution happens here, once per directory, under <dir>.lock, with
# -onlyUsePackageVersionsFromResolvedFile. <dir>/.soundpost-resolved (the key) marks a finished
# resolve, so one killed half-way is resolved again rather than trusted. Builds then pass
# -disableAutomaticPackageResolution, which keeps them from resolving to versions other than
# Package.resolved's. They still rewrite <dir>/workspace-state.json; concurrent builds are safe
# because SwiftPM serializes that with its own lock files in $TMPDIR, keyed by the directory's
# path (measured in Stride, 2026-10-14). So builds that share a directory must share a $TMPDIR,
# and local_build_args leaves the package flags out (with a note) when $TMPDIR is not the
# user's default, `getconf DARWIN_USER_TEMP_DIR`. A run with its own TMPDIR (the scripts' way
# to a separate derived data) is therefore safe, but resolves its own packages again.
#
# Never move or rename the directory: workspace-state.json records absolute paths. Never delete
# it while a build may be using it. Deleting it otherwise is safe: the next build resolves it
# again. It is a shared cache, not session leftovers (global CLAUDE.md "Never trash"). Each
# package set (every Sentry bump) gets its own ~1.9 GB directory, so old ones are retired at
# release end, by the orchestrator, when nothing is building: every use touches
# <dir>/.soundpost-resolved, so its mtime is the directory's last use.
#
# Environment:
#   SOUNDPOST_SPM_DIR          the package directory, or `off` (above)
#   SOUNDPOST_BUILD_LOCK_WAIT  seconds to wait for a held lock before giving up (default 2400)

LOCAL_BUILD_ARGS=()
LOCAL_SPM_DIR=""

# 0 when the lock's holder, or the child it recorded (a resolve run in the background), is alive.
_build_lock_alive() {
  local p
  for p in "$(cat "$1/pid" 2>/dev/null || true)" "$(cat "$1/child" 2>/dev/null || true)"; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}

# Removes a lock whose holder is gone, but only if it still shows the state the caller saw:
# under <lock>.reap, so two waiters that both saw the same dead holder cannot have the second
# remove the lock the first has just retaken.
#   0 removed, or the lock changed since the caller looked (try mkdir again)
#   1 someone else is reaping (retry shortly)
#   2 it could not be removed (treat it as held)
_build_lock_reap() {
  local lock="$1" seen="$2" holder age now rc=0
  now=$(date +%s)
  if ! mkdir "$lock.reap" 2>/dev/null; then
    # Held for microseconds; a minute old means its holder died inside it.
    age=$(( now - $(stat -f %m "$lock.reap" 2>/dev/null || echo "$now") ))
    (( age > 60 )) && rmdir "$lock.reap" 2>/dev/null
    return 1
  fi
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
  if [[ -n "$seen" && "$holder" == "$seen" ]] && ! _build_lock_alive "$lock"; then
    printf '  %s was left by pid %s, which is gone; taking it over\n' "$lock" "$seen" >&2
    rm -f "$lock/pid" "$lock/child" "$lock/what"
    rmdir "$lock" 2>/dev/null || rc=2
  elif [[ -z "$seen" && -d "$lock" && -z "$holder" ]] && (( age > 60 )); then
    # mkdir and the pid write are microseconds apart: no pid a minute later means the holder
    # died in between.
    printf '  %s has had no pid for %ss; taking it over\n' "$lock" "$age" >&2
    rm -f "$lock/child" "$lock/what"
    rmdir "$lock" 2>/dev/null || rc=2
  fi
  rmdir "$lock.reap" 2>/dev/null || true
  return $rc
}

# Waits for, then takes, a mkdir lock (pid inside). A lock whose holder (and recorded child) are
# gone is taken over. 0 taken, 1 gave up after SOUNDPOST_BUILD_LOCK_WAIT.
build_lock_take() {
  local lock="$1" what="$2" holder age now rc stuck=0 next_note=0
  local deadline=$(( $(date +%s) + ${SOUNDPOST_BUILD_LOCK_WAIT:-2400} ))
  while ! mkdir "$lock" 2>/dev/null; do
    now=$(date +%s)
    if (( now >= deadline )); then
      printf '\033[31m✗ %s is still held (%s, pid %s); gave up after %ss\033[0m\n' "$lock" \
        "$(cat "$lock/what" 2>/dev/null || echo '?')" "$(cat "$lock/pid" 2>/dev/null || echo '?')" \
        "${SOUNDPOST_BUILD_LOCK_WAIT:-2400}" >&2
      return 1
    fi
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    rc=3
    if [[ -n "$holder" ]] && ! _build_lock_alive "$lock"; then
      rc=0; _build_lock_reap "$lock" "$holder" || rc=$?
    elif [[ -z "$holder" ]]; then
      age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
      if (( age > 60 )); then rc=0; _build_lock_reap "$lock" "" || rc=$?; fi
    fi
    (( rc == 0 )) && continue
    if (( rc == 2 && stuck == 0 )); then
      printf '  %s belongs to nobody but cannot be removed (not empty?); waiting as if it were held\n' "$lock" >&2
      stuck=1
    fi
    if (( rc == 3 && now >= next_note )); then
      printf '  waiting for %s (%s, pid %s)\n' "$lock" "$(cat "$lock/what" 2>/dev/null || echo '?')" "${holder:-?}" >&2
      next_note=$(( now + 300 ))
    fi
    if (( rc == 1 )); then sleep 1; else sleep 5; fi
  done
  echo "$$" >"$lock/pid"
  echo "$what" >"$lock/what"
}

# Removes a lock this shell took. Nothing to stop: used where the lock's work has returned.
_build_lock_drop() {
  rm -f "$1/pid" "$1/child" "$1/what"
  rmdir "$1" 2>/dev/null || true
}

# A script's EXIT trap only (header): on a signal, bash runs the EXIT trap at once while its
# foreground xcodebuild keeps going, and freeing the lock then would let the next build into a
# build.db that is still being written. So every child of this shell is stopped first, with up
# to 30 s to exit. Only after build_lock_take succeeded.
build_lock_release() {
  local i
  if pgrep -P $$ >/dev/null 2>&1; then
    pkill -TERM -P $$ 2>/dev/null || true
    for i in {1..30}; do
      pgrep -P $$ >/dev/null 2>&1 || break
      sleep 1
    done
  fi
  _build_lock_drop "$1"
}

local_build_args() {
  local proj="$1" a prev="" resolved key dir marker lock log rpid deftmp
  local dd_args=()
  shift
  LOCAL_BUILD_ARGS=()
  LOCAL_SPM_DIR=""
  [[ -n "${CI:-}" ]] && return 0
  LOCAL_BUILD_ARGS=(COMPILER_INDEX_STORE_ENABLE=NO)
  [[ "${SOUNDPOST_SPM_DIR:-}" == "off" ]] && return 0
  for a in "$@"; do
    [[ "$a" == "-clonedSourcePackagesDirPath" ]] && return 0
    [[ "$prev" == "-derivedDataPath" ]] && dd_args=(-scheme Soundpost -derivedDataPath "$a")
    prev="$a"
  done
  # SwiftPM's locks on the shared directory live in $TMPDIR (header): under any other one, this
  # build would not be serialized against the builds that use the default.
  deftmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  if [[ -n "${TMPDIR:-}" && -n "$deftmp" ]] &&
     [[ "$(cd "$TMPDIR" 2>/dev/null && pwd -P)" != "$(cd "$deftmp" 2>/dev/null && pwd -P)" ]]; then
    printf '  TMPDIR is not the default %s, so the shared Swift packages are not used: they resolve into the derived data\n' "$deftmp" >&2
    return 0
  fi
  resolved="$proj/Soundpost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  if [[ ! -f "$resolved" ]]; then
    printf '  no Package.resolved in %s: packages resolve into the derived data\n' "$proj" >&2
    return 0
  fi
  key="$( { cat "$resolved"
            sed -n -e '/Begin XCRemoteSwiftPackageReference section/,/End XCRemoteSwiftPackageReference section/p' \
                   -e '/Begin XCLocalSwiftPackageReference section/,/End XCLocalSwiftPackageReference section/p' \
                   "$proj/Soundpost.xcodeproj/project.pbxproj" 2>/dev/null || true
          } | shasum -a 256 | awk '{print $1}')"
  dir="${SOUNDPOST_SPM_DIR:-$HOME/Library/Caches/Soundpost-build/SourcePackages-${key:0:8}}"
  dir="${dir%/}"
  marker="$dir/.soundpost-resolved"
  if [[ "$(cat "$marker" 2>/dev/null || true)" == "$key" ]]; then
    # Its mtime is the directory's last use, for retiring old package sets (header).
    touch "$marker" 2>/dev/null || true
  else
    lock="$dir.lock"
    if ! mkdir -p "$(dirname "$dir")"; then
      printf '  could not create %s; packages resolve into the derived data\n' "$(dirname "$dir")" >&2
      return 0
    fi
    build_lock_take "$lock" "resolving packages for $proj" || return 1
    # Someone else may have finished the same resolve while this waited.
    if [[ "$(cat "$marker" 2>/dev/null || true)" != "$key" ]]; then
      log="$dir.resolve.log"
      printf '  resolving Swift packages into %s (once per package set; log %s)\n' "$dir" "$log" >&2
      rm -f "$marker"
      mkdir -p "$dir"
      # In the background with its pid in the lock, so a waiter never takes the lock over from a
      # resolve that outlived its shell.
      xcodebuild -resolvePackageDependencies -project "$proj/Soundpost.xcodeproj" \
        ${dd_args[@]+"${dd_args[@]}"} \
        -clonedSourcePackagesDirPath "$dir" -onlyUsePackageVersionsFromResolvedFile \
        >"$log" 2>&1 &
      rpid=$!
      echo "$rpid" >"$lock/child"
      # wait has returned before every release below, so there is no child to stop: a plain
      # drop, never build_lock_release, which would stop the caller's own background jobs.
      if ! wait "$rpid"; then
        tail -8 "$log" | sed 's/^/    /' >&2
        printf '  could not resolve into %s (log %s); this build resolves into its own derived data instead\n' "$dir" "$log" >&2
        _build_lock_drop "$lock"
        return 0
      fi
      if ! echo "$key" 2>/dev/null >"$marker"; then
        printf '  could not write %s; this build resolves into its own derived data instead\n' "$marker" >&2
        _build_lock_drop "$lock"
        return 0
      fi
    fi
    _build_lock_drop "$lock"
  fi
  LOCAL_SPM_DIR="$dir"
  LOCAL_BUILD_ARGS+=(-clonedSourcePackagesDirPath "$dir" -disableAutomaticPackageResolution)
}

local_build_retry_args() {
  if [[ -n "$LOCAL_SPM_DIR" ]]; then
    printf '  (the retry resolves packages into the derived data; if it passes, suspect %s: move it to the Trash while nothing builds, and the next run resolves it again)\n' "$LOCAL_SPM_DIR" >&2
  fi
  SOUNDPOST_SPM_DIR=off local_build_args "$@"
}
