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
        # M20: claimed only because both shipped (plan §4G).
        "seal-at-capture": ["as you save it"],
        "capture-doors":   ["Siri, Shortcuts"],
        # M22: claimed only because both ship in 1.12.0 (plan §4F).
        "widget":          ["widget"],
        "control-center":  ["Control Center"],
    },
    "ja": {
        "listening":  ["聞き取って", "聞き取り"],
        "on-device":  ["iPhoneの中で", "端末の中だけで"],
        "correction": ["ちがいます"],
        "search":     ["音から思い出を探せる", "どんな音だったか"],
        "seal-at-capture": ["保存するときにも"],
        "capture-doors":   ["Siri、ショートカット"],
        "widget":          ["ウィジェット"],
        "control-center":  ["コントロールセンター"],
    },
    "zh-Hans": {
        # Distinct phrases per claim. `只在设备上聆听` used to satisfy both, so one
        # string was carrying two guarantees — and a rewrite dropping the paragraph
        # that says WHERE the listening happens would have left both green.
        "listening":  ["听出那段录音里是什么", "为听到的声音命名"],
        "on-device":  ["完全在你的 iPhone 上完成", "只在设备上聆听"],
        "correction": ["不是这个"],
        "search":     ["凭声音找回", "那时听起来是什么"],
        "seal-at-capture": ["保存时即可封存"],
        "capture-doors":   ["Siri、快捷指令"],
        "widget":          ["小组件"],
        "control-center":  ["控制中心"],
    },
}

import os
# `GATE_PROJECT_DIR` points the gate at another tree (its own tests use fixtures).
PROJECT = pathlib.Path(os.environ.get("GATE_PROJECT_DIR") or pathlib.Path(__file__).resolve().parent.parent)
root = PROJECT / "metadata"
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

# **"Offline" only as "works offline", in promotional text** (M23 §4H). The M8 copy ended
# "Private, offline, and honest by design" — true when the app never left the device, not
# since it syncs through iCloud and keeps far-seal schedules on a server. Recording and
# playback do work offline, so that phrase is the one allowed. Limited to the promotional
# text: the description's "offline-first" is a different, still-literal claim.
PROMO_OFFLINE = {
    "en-US":   (r"(?i)offline", "works offline"),
    "ja":      (r"オフライン", "オフラインでも使え"),
    "zh-Hans": (r"离线", "离线也能用"),
}
for locale, (word, allowed) in sorted(PROMO_OFFLINE.items()):
    path = root / locale / "promotional_text.txt"
    if not path.exists():
        continue
    rest = path.read_text(encoding="utf-8").replace(allowed, "")
    for m in re.finditer(word, rest):
        failures.append(f"{locale}/promotional_text.txt says {m.group(0)!r} other than as {allowed!r}: "
                        f"the app syncs through iCloud and a server, so a bare 'offline' is not literal")

# `release_notes.txt` is the notes for the version currently IN FLIGHT — `asc.py notes`
# pushes it to whatever `editable_version()` resolves to, which is matched against the
# project's MARKETING_VERSION. The archived `release_notes-<x.y.z>.txt` files are the
# record of what each version actually shipped.
#
# So the live file must match the archive for the version the project is currently on.
# Writing the NEXT release's notes into `release_notes.txt` early is the trap this
# catches: if the in-flight version comes back rejected, `asc.py notes` would push the
# unreleased version's copy onto it, and nothing would say so.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
import project_model

VERSION_KEYS = ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION")


def project_versions():
    """`{key: value}` for the two version settings, or None after recording why not.

    **One value, set in one place** (M22 §4B.5). App Store Connect rejects an app whose
    embedded extension carries a different version or build, and every release script
    here (`release-preflight.sh`, `asc.py`, this file) reads the version by counting
    *distinct values* in the project — so an extension with no version setting at all
    would still have read as "one value". The versions therefore live in the project's
    own configurations, every target inherits them, and nothing may override them: no
    target setting, and no `*-Info.plist` with a literal version of its own.
    """
    try:
        model = project_model.load(str(PROJECT))
    except project_model.ProjectError as e:
        failures.append(f"could not read the project: {e}")
        return None
    found = {}
    for key in VERSION_KEYS:
        values = {conf.get(key) for conf in model["projectSettings"].values()}
        if len(values) != 1 or None in values:
            failures.append(f"{key} must be set once, at the project level, in every configuration "
                            f"(found {sorted(map(str, values))})")
            return None
        found[key] = values.pop()
        for t in model["targets"]:
            for name, conf in t["settings"].items():
                if key in conf:
                    failures.append(f"target {t['name']} ({name}) overrides {key}; versions are "
                                    f"inherited from the project so every bundle ships the same one")
    for plist in sorted(PROJECT.glob("*-Info.plist")):
        text = plist.read_text(encoding="utf-8")
        for k in ("CFBundleShortVersionString", "CFBundleVersion"):
            if f"<key>{k}</key>" in text:
                failures.append(f"{plist.name} sets {k} itself; it must come from the project")
    return found


versions = project_versions()
version = versions["MARKETING_VERSION"] if versions else None
if version:
    for locale in sorted(CLAIMS):
        live = root / locale / "release_notes.txt"
        archived = root / locale / f"release_notes-{version}.txt"
        # A missing archive used to skip this check silently — so bumping the version
        # before writing its notes passed (M22 §4B.9).
        if not archived.exists():
            failures.append(f"{locale}/release_notes-{version}.txt is missing "
                            f"(the project's MARKETING_VERSION is {version})")
        elif not live.exists():
            failures.append(f"{locale}/release_notes.txt is missing")
        elif live.read_text(encoding="utf-8").strip() != archived.read_text(encoding="utf-8").strip():
            failures.append(
                f"{locale}/release_notes.txt does not match release_notes-{version}.txt "
                f"(the project's MARKETING_VERSION). `asc.py notes` pushes the live file.")

# **Nothing in the listing may sell what the app does not.** 1.9.0 was rejected under
# 2.1(b) for referring to subscriptions that were never submitted, and the fix was to
# stop offering Pro (`ProOffer` in Soundpost/Models/ProGate.swift). While that switch
# is off, the listing a reviewer reads alongside the build must not mention Pro, a
# purchase, a subscription — or charging at all, which is how "we never charge you to
# open a memory" reads next to an app with nothing to buy.
#
# Keyed on the switch itself, read from source, so the day Pro goes on sale this stops
# applying without anyone remembering to edit it. If the switch cannot be found this
# FAILS: a guard that silently stopped reading its input would pass forever.
def pro_on_sale():
    src = (PROJECT / "Soundpost" / "Models" / "ProGate.swift").read_text(encoding="utf-8")
    m = re.search(r"static let isOnSaleInThisBuild = (true|false)", src)
    return None if m is None else m.group(1) == "true"


OFF_SALE_TERMS = {
    "en-US": [r"\bPro\b", r"(?i)\bupgrade", r"(?i)\bunlock", r"(?i)\bpremium\b", r"(?i)subscri",
              r"(?i)purchas", r"(?i)in-app", r"(?i)free trial", r"(?i)\bcharg", r"(?i)\bpay\b",
              r"(?i)\bprice", r"(?i)5 minutes"],
    "ja":    [r"\bPro\b", r"プロ版", r"プレミアム", r"サブスク", r"購入", r"課金", r"料金", r"有料",
              r"無料体験", r"(?<![0-9０-９])5分"],
    "zh-Hans": [r"\bPro\b", r"专业版", r"高级版", r"订阅", r"购买", r"内购", r"收费", r"付费", r"解锁",
                r"试用", r"(?<![0-9])5 ?分钟"],
}
STORE_FIELDS = ["name", "subtitle", "keywords", "promotional_text", "description", "release_notes"]

on_sale = pro_on_sale()
if on_sale is None:
    failures.append("could not find `static let isOnSaleInThisBuild` in ProGate.swift — "
                    "the off-sale wording check has nothing to key on")
elif not on_sale:
    for locale in sorted(OFF_SALE_TERMS):
        # The versioned notes too: they are what `release_notes.txt` becomes, and a
        # blocked word written there first would otherwise be found only after the copy.
        names = [f"{field}.txt" for field in STORE_FIELDS]
        if version:
            names.append(f"release_notes-{version}.txt")
        for name in names:
            field = name[:-4]
            path = root / locale / name
            if not path.exists():
                continue
            text = path.read_text(encoding="utf-8")
            for pattern in OFF_SALE_TERMS[locale]:
                for m in re.finditer(pattern, text):
                    line = text.count("\n", 0, m.start()) + 1
                    failures.append(
                        f"{locale}/{field}.txt:{line} says {m.group(0)!r} while Pro is not on sale "
                        f"(ProOffer.isOnSaleInThisBuild == false)")

if failures:
    print("\033[31m✗ Store metadata gate FAILED:\033[0m", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)

print("\033[32m✓ Store metadata gate passed — 3 locales within every length limit,")
print("  each describing on-device listening, corrections and sound search.")
if on_sale is False:
    print("  Pro is not on sale, and no listing field mentions buying anything.\033[0m")
else:
    print("\033[0m", end="")
