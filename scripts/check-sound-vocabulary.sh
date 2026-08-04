#!/bin/bash
set -euo pipefail

# Sound-vocabulary gate (M15 §4D): every phrase in `SoundVocabulary.displayNames`
# must exist in Localizable.xcstrings and be fully translated.
#
# Why a dedicated gate: these keys are looked up with a *runtime* string
# (`String(localized: LocalizationValue(english))`), so Xcode's extractor cannot
# see them. `check-localization.sh` only validates keys that are already in the
# catalogue — it cannot notice a label added to the Swift table and never
# translated. That gap is exactly how a user ends up seeing a raw English phrase
# in a Japanese build, so it gets its own check.
#
# Used by CI and runnable locally: ./scripts/check-sound-vocabulary.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$PROJECT_DIR" <<'PY'
import json, os, re, sys

project_dir = sys.argv[1]
source = os.path.join(project_dir, "Soundpost", "Models", "SoundVocabulary.swift")
catalog_path = os.path.join(project_dir, "Soundpost", "Localizable.xcstrings")

with open(source, encoding="utf-8") as f:
    text = f.read()

# Only the displayNames table — stop before `denied`, whose entries are bare
# identifiers with no copy and must NOT be required to have translations.
start = text.index("static let displayNames")
end = text.index("static let denied")
table = text[start:end]

pairs = re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"\s*,', table)
if not pairs:
    sys.exit("check-sound-vocabulary: parsed no entries — did the table's shape change?")

with open(catalog_path, encoding="utf-8") as f:
    catalog = json.load(f)
strings = catalog.get("strings", {})
source_language = catalog.get("sourceLanguage", "en")

required = set()
for entry in strings.values():
    for lang in entry.get("localizations", {}):
        if lang != source_language:
            required.add(lang)

problems = []
for identifier, phrase in pairs:
    entry = strings.get(phrase)
    if entry is None:
        problems.append(f'{identifier}: phrase "{phrase}" is not in Localizable.xcstrings')
        continue
    locs = entry.get("localizations", {})
    for lang in sorted(required):
        unit = locs.get(lang, {}).get("stringUnit")
        state = unit.get("state") if unit else None
        if state != "translated":
            problems.append(f'{identifier}: "{phrase}" [{lang}] -> {state or "missing"}')

if problems:
    print("✗ Sound-vocabulary gate FAILED:\n", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    print(f"\n{len(problems)} issue(s) across {len(pairs)} labels.", file=sys.stderr)
    sys.exit(1)

print(f"✓ Sound-vocabulary gate passed — {len(pairs)} labels, all translated into {', '.join(sorted(required))}.")
PY
