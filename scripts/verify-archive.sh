#!/bin/bash
# What an archive must contain before it can go to App Store Connect (M22 §4B.6).
#
# Until M22 an archive was trusted by its exit code and one loose dSYM check that any
# `.dSYM` satisfied. With a widget extension inside the app, the archive can be wrong in
# ways nothing else notices: the extension missing, carrying a different version (App
# Store Connect rejects it after the upload), linking Sentry, reaching for an API that
# would need a privacy manifest or that the launcher has no business using, or binding
# an iOS 18 symbol strongly (the extension would then fail to load on iOS 17, where
# nobody here can run it). So every one of those is read from the archive itself.
#
# Fatal in every mode, and no setting skips it: RELEASE_PREFLIGHT_ALLOW names preflight
# checks only (a conflict copy, the keychain, the build number), never a wrong binary.
#
# Usage: scripts/verify-archive.sh <path.xcarchive>
# `GATE_PROJECT_DIR` points the project reader at another project (its tests use fixtures).
set -euo pipefail

ARCHIVE="${1:?usage: verify-archive.sh <path.xcarchive>}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ARCHIVE" "${GATE_PROJECT_DIR:-$PROJECT_DIR}" "$PROJECT_DIR/scripts/lib" <<'PY'
import os, plistlib, re, subprocess, sys

archive, project_dir, lib = sys.argv[1], sys.argv[2], sys.argv[3]
pin_file = os.path.join(project_dir, "scripts", "release-toolchain.env")
sys.path.insert(0, lib)
import project_model

problems = []


def fail(msg):
    problems.append(msg)


try:
    model = project_model.load(project_dir)
except project_model.ProjectError as e:
    print(f"✗ verify-archive: {e}", file=sys.stderr)
    sys.exit(1)

if not os.path.isdir(archive):
    print(f"✗ verify-archive: no archive at {archive}", file=sys.stderr)
    sys.exit(1)

apps = [t for t in model["targets"] if t["kind"] == "app"]
extensions = [t for t in model["targets"] if t["kind"] == "appex"]
if len(apps) != 1:
    print(f"✗ verify-archive: expected one application target, found {len(apps)}", file=sys.stderr)
    sys.exit(1)
app_target = apps[0]
app = os.path.join(archive, "Products", "Applications", app_target["product"])
if not os.path.isdir(app):
    print(f"✗ verify-archive: the archive holds no {app_target['product']}", file=sys.stderr)
    sys.exit(1)


def info(bundle):
    with open(os.path.join(bundle, "Info.plist"), "rb") as f:
        return plistlib.load(f)


def run(*cmd):
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        fail(f"{' '.join(cmd[:2])} failed on {cmd[-1]}: {out.stderr.strip()[:200]}")
        return ""
    return out.stdout


app_info = info(app)
version = (app_info.get("CFBundleShortVersionString"), app_info.get("CFBundleVersion"))

# 1. Every executable the project says it ships is in the archive.
for t in project_model.shipping(model):
    exe = os.path.join(app, t["executable"])
    if not os.path.isfile(exe):
        fail(f"{t['name']}: no executable at {os.path.relpath(exe, archive)}")

# 2. Nothing is embedded that the project does not build.
plugins = os.path.join(app, "PlugIns")
expected = {t["product"] for t in extensions}
present = set(os.listdir(plugins)) if os.path.isdir(plugins) else set()
for extra in sorted(present - expected):
    fail(f"PlugIns/{extra} is in the archive but no target builds it")

# Symbols an extension must not import. Patterns over `nm -u` (undefined symbols):
# networking, UserDefaults (a required-reason API), file timestamps, boot time and disk
# space (the other required-reason categories) — the launcher needs none of them, and
# needing one would mean a privacy manifest the extension does not have.
FORBIDDEN_IMPORTS = {
    "network": r"NSURLSession|URLSession|NWConnection|nw_connection|CFNetwork|CFSocket|CFStream",
    "UserDefaults": r"NSUserDefaults|UserDefaults",
    "file timestamps": r"NSFileCreationDate|NSFileModificationDate|creationDateKey|contentModificationDateKey|_getattrlist|_fstat|_stat\b|_lstat\b",
    "boot time": r"systemUptime|_mach_absolute_time|_mach_continuous_time",
    "disk space": r"volumeAvailableCapacity|NSFileSystemFreeSize|_statfs|_fstatfs",
    "Sentry": r"Sentry",
}
# Symbols introduced after iOS 17.0, the deployment target: each must be a weak import,
# or the extension fails to load on iOS 17 instead of simply not offering the control.
LATER_THAN_17 = r"ControlWidget|StaticControlConfiguration|ControlWidgetButton|IntentModes|supportedModes|WidgetLocation.*carPlay"

for t in extensions:
    bundle = os.path.join(app, "PlugIns", t["product"])
    if not os.path.isdir(bundle):
        continue
    ext_info = info(bundle)
    got = (ext_info.get("CFBundleShortVersionString"), ext_info.get("CFBundleVersion"))
    if got != version:
        fail(f"{t['product']} is {got[0]} ({got[1]}) but the app is {version[0]} ({version[1]})")
    point = (ext_info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
    if point != "com.apple.widgetkit-extension":
        fail(f"{t['product']}: extension point is {point!r}, not com.apple.widgetkit-extension")
    if os.path.isdir(os.path.join(bundle, "Frameworks")):
        fail(f"{t['product']} embeds frameworks: {sorted(os.listdir(os.path.join(bundle, 'Frameworks')))}")
    exe = os.path.join(app, t["executable"])
    if not os.path.isfile(exe):
        continue
    if "Sentry" in run("otool", "-L", exe):
        fail(f"{t['product']} links Sentry")
    undefined = run("nm", "-u", exe).split()
    for what, pattern in FORBIDDEN_IMPORTS.items():
        hits = sorted({s for s in undefined if re.search(pattern, s)})
        if hits:
            fail(f"{t['product']} imports {what} symbols: {', '.join(hits[:5])}")
    for line in run("nm", "-m", "-u", exe).splitlines():
        if re.search(LATER_THAN_17, line) and "weak" not in line:
            fail(f"{t['product']} binds a post-iOS-17 symbol strongly: {line.strip()[:160]}")

# 3. The toolchain (M23 §4C.3): every binary built by the pinned Xcode, against an SDK no
#    older than the minimum. Read from each bundle, the app's and every appex's, and printed
#    into the release log.
def read_pin(path):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return None, None, f"no release toolchain pin at {path}"
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([A-Z_]+)=([^\s#]*)", line)
            if m:
                values[m.group(1)] = m.group(2)
    build, sdk = values.get("EXPECTED_RELEASE_XCODE_BUILD", ""), values.get("MIN_SDK", "")
    if not re.fullmatch(r"[0-9]{2}[A-Z][0-9]+[a-z]?", build):
        return None, None, f"EXPECTED_RELEASE_XCODE_BUILD {build!r} in {path} is not an Xcode build number"
    if not re.fullmatch(r"[a-z]+[0-9]+(\.[0-9]+)*", sdk):
        return None, None, f"MIN_SDK {sdk!r} in {path} is not an SDK name"
    return build, sdk, None


def sdk_parts(name):
    m = re.fullmatch(r"([a-z]+)([0-9]+(?:\.[0-9]+)*)", name or "")
    return (m.group(1), tuple(int(x) for x in m.group(2).split("."))) if m else (None, None)


want_build, min_sdk, pin_problem = read_pin(pin_file)
if pin_problem:
    fail(pin_problem)
else:
    bundles = [(app_target["product"], app)] + [
        (t["product"], os.path.join(app, "PlugIns", t["product"])) for t in extensions
        if os.path.isdir(os.path.join(app, "PlugIns", t["product"]))]
    min_platform, min_version = sdk_parts(min_sdk)
    for label, bundle in bundles:
        bi = info(bundle)
        built, sdk = bi.get("DTXcodeBuild"), bi.get("DTSDKName")
        print(f"  {label}: DTXcodeBuild={built} DTSDKName={sdk}")
        if built is None:
            fail(f"{label} records no DTXcodeBuild")
        elif built != want_build:
            fail(f"{label} was built by Xcode {built}, but releases are pinned to {want_build} (scripts/release-toolchain.env)")
        platform, version = sdk_parts(sdk)
        if sdk is None:
            fail(f"{label} records no DTSDKName")
        elif platform != min_platform or version < min_version:
            fail(f"{label} was built against {sdk}, below the minimum {min_sdk}")

# 4. The app's own dSYM, by name — the extension's must not stand in for it.
app_dsym = os.path.join(archive, "dSYMs", f"{app_target['product']}.dSYM")
if not os.path.isdir(app_dsym):
    fail(f"no {app_target['product']}.dSYM in the archive (an extension's dSYM does not count)")

if problems:
    print("✗ Archive check FAILED:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
print(f"✓ Archive check passed — {app_target['product']} {version[0]} ({version[1]}), "
      f"{len(extensions)} extension(s), each the same version, WidgetKit, no Sentry, "
      f"no networking or required-reason imports, later-than-iOS-17 symbols weak; "
      f"every binary built by Xcode {want_build} against {min_sdk} or later; app dSYM present.")
PY
