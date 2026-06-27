#!/bin/bash
set -euo pipefail

# Localization gate (M12 §S1): assert every String Catalog (.xcstrings) is 100%
# translated for every supported language — no `new`, no `needs_review`, no
# missing translation. Language-aware (not a blind grep): the set of required
# languages is the union of every non-source language that appears anywhere in a
# catalog, so adding a language enforces it everywhere automatically. Strings
# marked `"shouldTranslate": false` (brand names, format tokens) are skipped.
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

count = sum(1 for path in catalogs for _ in json.load(open(path, encoding="utf-8")).get("strings", {}))
print(f"✓ Localization gate passed — {len(catalogs)} catalog(s), all translatable strings 100% translated.")
PY
