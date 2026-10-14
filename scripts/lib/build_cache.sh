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
#     after making sure <dir> holds a finished resolve for <project dir>.
#     With CI set, LOCAL_BUILD_ARGS is empty, so ci.yml's builds run exactly as before. The
#     package flags alone are left out (xcodebuild resolves into the derived data, as before)
#     when:
#       - SOUNDPOST_SPM_DIR=off;
#       - the caller's args already name -clonedSourcePackagesDirPath;
#       - the project has no Package.resolved;
#       - the resolve fails (printed as a warning, with its log): no network, or a
#         Package.resolved that no longer satisfies the project's package requirements.
#     Returns 1 only when another process holds the resolve lock for too long. Call it in the
#     same shell as the build: LOCAL_BUILD_ARGS is a shell variable, and a warm call costs one
#     sha256.
#
# The package directory: ~/Library/Caches/Soundpost-build/SourcePackages-<8 hex>, the sha256 of
# Package.resolved plus the project's package references (project.pbxproj's
# XCRemote/XCLocalSwiftPackageReference sections). Never under ~/Documents (iCloud; codesign
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
# path (measured in Stride, 2026-10-14). So builds that share a directory should share a
# $TMPDIR, which both scripts here do.
#
# Never move or rename the directory: workspace-state.json records absolute paths. Never delete
# it while a build may be using it. Deleting it otherwise is safe: the next build resolves it
# again. It is a shared cache, not session leftovers (global CLAUDE.md "Never trash").
#
# Environment:
#   SOUNDPOST_SPM_DIR          the package directory, or `off` (above)
#   SOUNDPOST_BUILD_LOCK_WAIT  seconds to wait for another process's resolve (default 2400)

LOCAL_BUILD_ARGS=()

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

# Stops this shell's own children first (a signal ran an EXIT trap while xcodebuild was still
# running), then removes the lock. Only after build_lock_take succeeded.
build_lock_release() {
  local lock="$1" i
  if pgrep -P $$ >/dev/null 2>&1; then
    pkill -TERM -P $$ 2>/dev/null || true
    for i in {1..30}; do
      pgrep -P $$ >/dev/null 2>&1 || break
      sleep 1
    done
  fi
  rm -f "$lock/pid" "$lock/child" "$lock/what"
  rmdir "$lock" 2>/dev/null || true
}

local_build_args() {
  local proj="$1" a resolved key dir marker lock log rpid
  shift
  LOCAL_BUILD_ARGS=()
  [[ -n "${CI:-}" ]] && return 0
  LOCAL_BUILD_ARGS=(COMPILER_INDEX_STORE_ENABLE=NO)
  [[ "${SOUNDPOST_SPM_DIR:-}" == "off" ]] && return 0
  for a in "$@"; do
    [[ "$a" == "-clonedSourcePackagesDirPath" ]] && return 0
  done
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
  if [[ "$(cat "$marker" 2>/dev/null || true)" != "$key" ]]; then
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
        -clonedSourcePackagesDirPath "$dir" -onlyUsePackageVersionsFromResolvedFile \
        >"$log" 2>&1 &
      rpid=$!
      echo "$rpid" >"$lock/child"
      if ! wait "$rpid"; then
        tail -8 "$log" | sed 's/^/    /' >&2
        printf '  could not resolve into %s (log %s); this build resolves into its own derived data instead\n' "$dir" "$log" >&2
        build_lock_release "$lock"
        return 0
      fi
      if ! echo "$key" 2>/dev/null >"$marker"; then
        printf '  could not write %s; this build resolves into its own derived data instead\n' "$marker" >&2
        build_lock_release "$lock"
        return 0
      fi
    fi
    build_lock_release "$lock"
  fi
  LOCAL_BUILD_ARGS+=(-clonedSourcePackagesDirPath "$dir" -disableAutomaticPackageResolution)
}
