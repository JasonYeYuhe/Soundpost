# Soundpost — project rules for Claude sessions

## Building locally: the shared Swift package checkout

Swift packages (sentry-cocoa, ~1.9 GB) are resolved once per package set into one checkout
outside the repo by `scripts/lib/build_cache.sh`, which `scripts/screenshots.sh` and
`scripts/check-debug-only.sh` source. That is this project's package directory for the global
"Build roots" rule 4. It is **not** `SourcePackages-<first 8 of the Package.resolved sha>`: its
key also covers the project's package references, so the two names differ. Don't create that
one.

- **Which directory.** Whatever this prints, from the repo root. It resolves first if the
  directory is missing (a workflow runs it once before fanning out); warm, it costs one sha256:

  ```bash
  bash -c 'source scripts/lib/build_cache.sh && local_build_args "$PWD" && printf "%s\n" "${LOCAL_BUILD_ARGS[@]}"'
  ```

  It is `~/Library/Caches/Soundpost-build/SourcePackages-<8 hex>`.
- **Your own `xcodebuild`** (tests, ad-hoc builds): in the shell that builds, run
  `source scripts/lib/build_cache.sh && local_build_args "$PWD"`, then add
  `${LOCAL_BUILD_ARGS[@]+"${LOCAL_BUILD_ARGS[@]}"}` to the command line. That is
  `COMPILER_INDEX_STORE_ENABLE=NO -clonedSourcePackagesDirPath <dir> -disableAutomaticPackageResolution`.
  A bare `"${LOCAL_BUILD_ARGS[@]}"` of an empty array fails under bash 3.2's `set -u`.
- **Keep the default `$TMPDIR`.** SwiftPM's locks on the shared directory live there, so under
  any other `TMPDIR` the helper leaves the package flags out and the build resolves its own copy
  (safe, but 1.9 GB again).
- `SOUNDPOST_SPM_DIR=off` turns it off (packages resolve into the derived data, as before the
  helper); `SOUNDPOST_SPM_DIR=<dir>` moves it. With `CI` set it adds nothing.
- Release archives (`scripts/build-upload-asc.sh`) do not use it.

## Keep / never clean up

- `~/Library/Caches/Soundpost-build/SourcePackages-*` and their `.resolve.log`: a shared cache,
  not session leftovers. Never move or rename one (`workspace-state.json` holds absolute paths).
  Old package sets (one per Sentry bump) are retired at release end, while nothing builds, by
  the mtime of their `.soundpost-resolved`, which every use touches.
