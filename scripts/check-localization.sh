#!/bin/bash
set -euo pipefail

# Localization gate (M12 §S1): assert every String Catalog (.xcstrings) is 100%
# translated for every supported language — no `new`, no `needs_review`, no
# missing translation. Language-aware (not a blind grep): the set of required
# languages is the union of every non-source language that appears anywhere in a
# catalog, so adding a language enforces it everywhere automatically. Strings
# marked `"shouldTranslate": false` (brand names, format tokens) are skipped.
#
# It runs THREE checks, and the second exists because the first one cannot fail
# for the thing that actually went wrong (M15 §11P):
#
#   1. every string IN the catalog is translated everywhere;
#   2. every user-facing literal in the SOURCE is in the catalog at all;
#   3. Chinese store metadata uses full-width punctuation.
#
# Check 1 passed for the whole of M15 while four `Text(...)`/`.alert(...)` strings
# in SettingsView showed English to Japanese and Chinese readers — because they had
# never been added to the catalog, and a gate that iterates the catalog cannot see a
# key that isn't in it. Silence read as success. Check 2 reads the source instead of
# the catalog, so an untranslated string is now impossible to ship quietly rather
# than merely discouraged.
#
# Used by CI and runnable locally: ./scripts/check-localization.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$PROJECT_DIR" <<'PY'
import json, sys, glob, os

project_dir = sys.argv[1]
catalogs = sorted(glob.glob(os.path.join(project_dir, "Soundpost", "**", "*.xcstrings"), recursive=True))
if not catalogs:
    print("check-localization: no .xcstrings catalogs found", file=sys.stderr)
    sys.exit(1)

problems = []

for path in catalogs:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    source = data.get("sourceLanguage", "en")
    strings = data.get("strings", {})

    # Required languages = every non-source language that appears anywhere here.
    required = set()
    for entry in strings.values():
        for lang in entry.get("localizations", {}):
            if lang != source:
                required.add(lang)

    rel = os.path.relpath(path, project_dir)
    for key, entry in strings.items():
        if key == "":                                   # Xcode's placeholder row
            continue
        if entry.get("shouldTranslate") is False:        # opted out (brand/format)
            continue
        locs = entry.get("localizations", {})
        for lang in sorted(required):
            unit = locs.get(lang, {}).get("stringUnit")
            state = unit.get("state") if unit else None
            if state != "translated":
                shown = key if len(key) <= 60 else key[:57] + "..."
                problems.append(f"{rel}: [{lang}] \"{shown}\" → {state or 'missing'}")

if problems:
    print("✗ Localization gate FAILED — untranslated strings:\n", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    print(f"\n{len(problems)} issue(s). Translate them (state must be 'translated') and re-run.", file=sys.stderr)
    sys.exit(1)

# --- Check 2: every user-facing literal in the source reaches a catalog ---------
#
# The constructs below take a `LocalizedStringKey`/`String.LocalizationValue`, so a
# bare literal in one IS a translatable string whether or not anyone remembered to
# catalog it. `Text(verbatim:)` is deliberately not in the list — that spelling is
# how the code says "this one is not for translation" — and neither is anything
# holding an interpolation, which lands in the catalog under a format key instead.
import re

LOCALIZING = re.compile(
    r'(?:\bText|\bButton|\bLabel|\bToggle|\bTextField|\bNavigationLink|\bLink'
    r'|\.navigationTitle|\.alert|\.confirmationDialog|\.sheet|\.help'
    r'|String\(localized:\s*)'
    r'\(?\s*"((?:[^"\\]|\\.)*)"'
)
HAS_CONTENT = re.compile(r'[0-9A-Za-z぀-ヿ一-鿿]')

known = set()
for path in catalogs:
    known |= set(json.load(open(path, encoding="utf-8")).get("strings", {}))

STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def localized_string_key_bodies(src):
    """Spans of every declaration typed `LocalizedStringKey`.

    A bare literal assigned to one is a translatable string exactly as much as a
    `Text("…")` is, and this codebase uses the pattern for any message that varies
    (`backupMessage`, the Listening footer). Matching only call-sites missed them:
    the first version of this check passed over two new footer strings while
    failing correctly on an alert three lines away, which is the same partial
    blindness the whole check exists to remove.
    """
    for m in re.finditer(r"(?::|->)\s*LocalizedStringKey\b", src):
        brace = src.find("{", m.end())
        if brace < 0:
            continue
        depth = 0
        for i in range(brace, len(src)):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    yield brace, i
                    break


uncatalogued = []
for path in sorted(glob.glob(os.path.join(project_dir, "Soundpost", "**", "*.swift"), recursive=True)):
    src = open(path, encoding="utf-8").read()
    # DEBUG-only developer tools never ship a UI to a user, and say so by using
    # `Text(verbatim:)` throughout; skip them rather than demand translations.
    if src.lstrip().startswith("#if DEBUG"):
        continue

    found = [(m.start(), m.group(1)) for m in LOCALIZING.finditer(src)]
    for start, end in localized_string_key_bodies(src):
        for m in STRING_LITERAL.finditer(src, start, end):
            found.append((m.start(), m.group(1)))

    for offset, key in found:
        if r"\(" in key:                       # interpolated → format key
            continue
        if not HAS_CONTENT.search(key):        # "…", " " — nothing to translate
            continue
        if key in known:
            continue
        line = src.count("\n", 0, offset) + 1
        shown = key if len(key) <= 60 else key[:57] + "..."
        entry = f"{os.path.relpath(path, project_dir)}:{line}: \"{shown}\""
        if entry not in uncatalogued:
            uncatalogued.append(entry)

if uncatalogued:
    print("✗ Localization gate FAILED — user-facing strings missing from the catalog:\n", file=sys.stderr)
    for u in uncatalogued:
        print("  " + u, file=sys.stderr)
    print(
        f"\n{len(uncatalogued)} string(s) would render in English to every non-English reader."
        "\nAdd them to Soundpost/Localizable.xcstrings with ja + zh-Hans translations,"
        "\nor use Text(verbatim:) if the string genuinely must not be translated.",
        file=sys.stderr,
    )
    sys.exit(1)

# --- Check 3: Chinese store metadata uses full-width punctuation ----------------
#
# The app's own zh-Hans strings have always got this right; the App Store metadata
# is edited outside the catalog and drifted (1.6.2 shipped three half-width marks).
# A comma of the wrong width is small and reads, to a Chinese reader, exactly like
# a listing nobody proof-read.
# Two exclusions, both deliberate. `keywords.txt` is a comma-separated list that
# App Store Connect parses — its commas are syntax, not punctuation. And archived
# `release_notes-<version>.txt` are the record of what each version actually
# shipped; correcting them would make the archive say something that was never
# true, which is the one thing an archive must not do.
FULL_WIDTH = {",": "，", ";": "；", ":": "：", "!": "！", "?": "？"}
ARCHIVED = re.compile(r"release_notes-.+\.txt$")
half = []
for path in sorted(glob.glob(os.path.join(project_dir, "metadata", "zh-Hans", "*.txt"))):
    name = os.path.basename(path)
    if name == "keywords.txt" or ARCHIVED.search(name):
        continue
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r"[一-鿿]([,;:!?])", text):
        line = text.count("\n", 0, m.start()) + 1
        half.append(f"{os.path.relpath(path, project_dir)}:{line}: '{m.group(1)}' → '{FULL_WIDTH[m.group(1)]}'")

if half:
    print("✗ Localization gate FAILED — half-width punctuation in Chinese metadata:\n", file=sys.stderr)
    for h in half:
        print("  " + h, file=sys.stderr)
    sys.exit(1)

count = sum(1 for path in catalogs for _ in json.load(open(path, encoding="utf-8")).get("strings", {}))
print(f"✓ Localization gate passed — {len(catalogs)} catalog(s), {count} strings 100% translated,")
print("  every source literal catalogued, Chinese metadata punctuation clean.")
PY
