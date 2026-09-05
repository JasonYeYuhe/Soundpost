#!/usr/bin/env python3
"""App Store Connect metadata limits, and the claims the listing has to make.

M19 §4A / §10. Two things this guards, and neither was guarded before.

**The limits.** Subtitle 30 characters, keywords 100, promotional text 170,
description 4000. App Store Connect counts CHARACTERS; `wc -m` counts bytes unless
the shell's locale happens to be UTF-8, and 11 Japanese characters measure as 33
bytes. A length check that is wrong by 3x in exactly the two languages with the least
headroom is worse than no check.

**The claims.** The listing described an app without on-device listening for three
releases after it shipped — 1.6.0, 1.7.0 and 1.8.0 — because there was no step that
could notice. The store page is where somebody decides whether to install; a
privacy-relevant capability being invisible there is the one place it matters most.
So each locale's description has to say, in its own language, that Soundpost listens,
that the listening is on-device, that a wrong label can be corrected, and that the
library is searchable by sound.
"""
import re, sys, pathlib

LIMITS = {"subtitle": 30, "keywords": 100, "promotional_text": 170, "description": 4000}

# Substrings, not sentences: the copy is free to change around them. Each list is
# "at least one of these must appear", so a rewrite can pick different wording for
# the same claim without this file becoming a second copy of the description.
CLAIMS = {
    "en-US": {
        "listening":  ["recognise what a clip sounded like", "listens on your device"],
        "on-device":  ["entirely on your iPhone", "on your device"],
        "correction": ["no, it wasn't", "gets it wrong"],
        "search":     ["Search your library by what a moment sounded like", "find a memory by its sound"],
    },
    "ja": {
        "listening":  ["聞き取って", "聞き取り"],
        "on-device":  ["iPhoneの中で", "端末の中だけで"],
        "correction": ["ちがいます"],
        "search":     ["音から思い出を探せる", "どんな音だったか"],
    },
    "zh-Hans": {
        # Distinct phrases per claim. `只在设备上聆听` used to satisfy both, so one
        # string was carrying two guarantees — and a rewrite dropping the paragraph
        # that says WHERE the listening happens would have left both green.
        "listening":  ["听出那段录音里是什么", "为听到的声音命名"],
        "on-device":  ["完全在你的 iPhone 上完成", "只在设备上聆听"],
        "correction": ["不是这个"],
        "search":     ["凭声音找回", "那时听起来是什么"],
    },
}

root = pathlib.Path(__file__).resolve().parent.parent / "metadata"
failures = []

for locale in sorted(CLAIMS):
    folder = root / locale
    for field, limit in LIMITS.items():
        path = folder / f"{field}.txt"
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8").strip()
        if len(text) > limit:
            failures.append(f"{locale}/{field}.txt is {len(text)} characters, limit {limit}")
    description = (folder / "description.txt").read_text(encoding="utf-8")
    for claim, options in CLAIMS[locale].items():
        if not any(o in description for o in options):
            failures.append(
                f"{locale}/description.txt makes no '{claim}' claim "
                f"(looked for {options!r})")

# `release_notes.txt` is the notes for the version currently IN FLIGHT — `asc.py notes`
# pushes it to whatever `editable_version()` resolves to, which is matched against the
# project's MARKETING_VERSION. The archived `release_notes-<x.y.z>.txt` files are the
# record of what each version actually shipped.
#
# So the live file must match the archive for the version the project is currently on.
# Writing the NEXT release's notes into `release_notes.txt` early is the trap this
# catches: if the in-flight version comes back rejected, `asc.py notes` would push the
# unreleased version's copy onto it, and nothing would say so.
def project_marketing_version():
    pbx = (pathlib.Path(__file__).resolve().parent.parent
           / "Soundpost.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
    m = re.search(r"MARKETING_VERSION = ([0-9.]+);", pbx)
    return m.group(1) if m else None


version = project_marketing_version()
if version:
    for locale in sorted(CLAIMS):
        live = root / locale / "release_notes.txt"
        archived = root / locale / f"release_notes-{version}.txt"
        if live.exists() and archived.exists():
            if live.read_text(encoding="utf-8").strip() != archived.read_text(encoding="utf-8").strip():
                failures.append(
                    f"{locale}/release_notes.txt does not match release_notes-{version}.txt "
                    f"(the project's MARKETING_VERSION). `asc.py notes` pushes the live file.")

if failures:
    print("\033[31m✗ Store metadata gate FAILED:\033[0m", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)

print("\033[32m✓ Store metadata gate passed — 3 locales within every length limit,")
print("  each describing on-device listening, corrections and sound search.\033[0m")
