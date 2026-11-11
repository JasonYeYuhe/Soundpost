#!/usr/bin/env python3
"""Pick CI's simulator by NAME: the named device on the newest runtime that offers it (M23 §4C.4).

The inline picker this replaces took "the first device whose name starts with iPhone on the
newest runtime". On the `xcode-27` image the newest iOS runtimes include ones whose only
device is `iPhone Duo` (read from actions/runner-images, 2026-11-12), so it would have run
every test on whatever that device is, and a later image could move it again without a line
of this repo changing. A name is a claim this script can check; "the first iPhone" is not.

usage: xcrun simctl list devices available -j | pick_simulator.py "<name>" <min-major>
       pick_simulator.py "<name>" <min-major> <simctl-json-file>

Prints the UDID. Exits 1, saying what exists, when no runtime of at least <min-major>
offers an available device of exactly that name.
"""
import json
import re
import sys

RUNTIME = re.compile(r"iOS-(\d+)-(\d+)(?:-(\d+))?$")


def runtime_version(key):
    m = RUNTIME.search(key)
    if not m:
        return None
    return tuple(int(x) for x in m.groups(default="0"))


def pick(devices, name, min_major):
    """`devices`: simctl's `devices` dict. Returns (udid, runtime key) or raises LookupError."""
    candidates = []
    for key, items in devices.items():
        version = runtime_version(key)
        if version is None or version[0] < min_major:
            continue
        for d in items:
            if d.get("name") == name and d.get("isAvailable", True):
                candidates.append((version, key, d["udid"]))
    if not candidates:
        offered = sorted({f"{d.get('name')} (iOS {'.'.join(map(str, runtime_version(k)))})"
                          for k, items in devices.items() if runtime_version(k)
                          for d in items if d.get("isAvailable", True)})
        raise LookupError(f"no available '{name}' on an iOS {min_major}+ runtime; "
                          f"available: {', '.join(offered) or 'nothing'}")
    candidates.sort(key=lambda c: c[0])
    _, key, udid = candidates[-1]
    return udid, key


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    name, min_major = argv[1], int(argv[2])
    raw = open(argv[3]).read() if len(argv) == 4 else sys.stdin.read()
    try:
        udid, key = pick(json.loads(raw)["devices"], name, min_major)
    except LookupError as e:
        print(f"pick_simulator: {e}", file=sys.stderr)
        return 1
    print(f"pick_simulator: {name} on {key}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
