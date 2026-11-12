"""The gates see every target (M22 §4B).

Each test builds a small project tree in a temp folder — a project file, a second
target, a catalog, a log, a built `.app`, an archive — puts ONE fault in it, and
checks the gate fails for that fault and passes without it. The point of each fixture
is a fault the gate could not see before M22: a second target's untranslated string, an
English-only catalog, a warning in a checkout not called `Soundpost`, an empty extension
binary, an extension with no version of its own, a doctored archive. A gate that
iterates what it was told about cannot fail for what it was not told about (M15 §11P).

Standard library only; run by CI's `unittest discover -s scripts`. Needs macOS
(`plutil`, `strings`, `nm`, `otool`, `xcrun clang`), which every place this runs has.
"""
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "lib"))
import project_model  # noqa: E402

WIDGET_KIND = "com.soundpost.Soundpost.widget.newCapsule"


# ── A project file, written the way Xcode writes one ─────────────────────────────

def pbxproj(targets, project_settings=None, exceptions=()):
    """An OpenStep project file. `targets`: dicts with name, kind, roots, settings.
    `exceptions`: (root, target name, [paths]) membership-exception sets."""
    project_settings = project_settings or {"MARKETING_VERSION": "1.12.0", "CURRENT_PROJECT_VERSION": "24"}
    objs, ids = [], iter(range(1, 10_000))

    def oid():
        return f"{next(ids):024X}"

    def settings(d):
        return "".join(f"\t\t\t\t{k} = {json.dumps(str(v))};\n" for k, v in d.items())

    roots = {}
    for t in targets:
        for r in t["roots"]:
            roots.setdefault(r, oid())
    exc_ids = {}
    for root, tname, paths in exceptions:
        exc_ids.setdefault(root, []).append((oid(), tname, paths))
    for r, rid in roots.items():
        exc = exc_ids.get(r, [])
        exc_line = ("\t\t\texceptions = (" + "".join(f"{e[0]}, " for e in exc) + ");\n") if exc else ""
        # Xcode puts `exceptions` between `isa` and `path` — the order a line parser missed.
        objs.append(f"\t\t{rid} = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n{exc_line}"
                    f"\t\t\tpath = {r};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    target_ids = {t["name"]: oid() for t in targets}
    for r, exc in exc_ids.items():
        for eid, tname, paths in exc:
            objs.append(f"\t\t{eid} = {{\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
                        f"\t\t\tmembershipExceptions = ({''.join(json.dumps(p) + ', ' for p in paths)});\n"
                        f"\t\t\ttarget = {target_ids[tname]};\n\t\t}};\n")
    product_types = {"app": ("com.apple.product-type.application", ".app"),
                     "appex": ("com.apple.product-type.app-extension", ".appex"),
                     "test": ("com.apple.product-type.bundle.unit-test", ".xctest")}
    for t in targets:
        ptype, ext = product_types[t["kind"]]
        ref, cl, cd, cr = oid(), oid(), oid(), oid()
        objs.append(f"\t\t{ref} = {{isa = PBXFileReference; path = {t['name']}{ext}; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
        for cid, name in ((cd, "Debug"), (cr, "Release")):
            objs.append(f"\t\t{cid} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
                        f"{settings(t.get('settings', {}))}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
        objs.append(f"\t\t{cl} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = ({cd}, {cr}, );\n\t\t}};\n")
        groups = "".join(f"{roots[r]}, " for r in t["roots"])
        objs.append(f"\t\t{target_ids[t['name']]} = {{\n\t\t\tisa = PBXNativeTarget;\n"
                    f"\t\t\tbuildConfigurationList = {cl};\n\t\t\tbuildPhases = ();\n"
                    f"\t\t\tfileSystemSynchronizedGroups = ({groups});\n\t\t\tname = {t['name']};\n"
                    f"\t\t\tproductReference = {ref};\n\t\t\tproductType = \"{ptype}\";\n\t\t}};\n")
    pl, pd, pr, proj = oid(), oid(), oid(), oid()
    for cid, name in ((pd, "Debug"), (pr, "Release")):
        objs.append(f"\t\t{cid} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
                    f"{settings(project_settings)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
    objs.append(f"\t\t{pl} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = ({pd}, {pr}, );\n\t\t}};\n")
    objs.append(f"\t\t{proj} = {{\n\t\t\tisa = PBXProject;\n\t\t\tbuildConfigurationList = {pl};\n"
                f"\t\t\ttargets = ({''.join(target_ids[t['name']] + ', ' for t in targets)});\n\t\t}};\n")
    return ("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n"
            "\tobjects = {\n" + "".join(objs) + f"\t}};\n\trootObject = {proj};\n}}\n")


def catalog(strings, languages=("ja", "zh-Hans"), source="en"):
    """A String Catalog with each key translated into `languages`."""
    out = {"sourceLanguage": source, "version": "1.0", "strings": {}}
    for key in strings:
        out["strings"][key] = {"localizations": {
            lang: {"stringUnit": {"state": "translated", "value": f"{key} ({lang})"}} for lang in languages}}
    return json.dumps(out, indent=2)


APP = {"name": "Soundpost", "kind": "app", "roots": ["Soundpost"]}
WIDGET = {"name": "SoundpostWidgetExtension", "kind": "appex", "roots": ["SoundpostWidget"]}
TESTS = {"name": "SoundpostTests", "kind": "test", "roots": ["SoundpostTests"]}


class Tree:
    """A temp project tree. `write(path, text)`; `.dir` is the project root."""

    def __init__(self, test, name="Soundpost"):
        self._tmp = tempfile.mkdtemp(prefix="gates-")
        test.addCleanup(shutil.rmtree, self._tmp, True)
        self.dir = os.path.join(self._tmp, name)
        os.makedirs(self.dir)

    def write(self, rel, text):
        path = os.path.join(self.dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def project(self, targets, **kw):
        self.write("Soundpost.xcodeproj/project.pbxproj", pbxproj(targets, **kw))

    def run(self, *cmd):
        env = dict(os.environ, GATE_PROJECT_DIR=self.dir)
        return subprocess.run(cmd, capture_output=True, text=True, env=env)


def two_targets(tree, widget_catalog=None, widget_source='Text("New capsule")'):
    tree.project([APP, WIDGET, TESTS])
    tree.write("Soundpost/App.swift", 'Text("New capsule")\n')
    tree.write("Soundpost/Localizable.xcstrings", catalog(["New capsule"]))
    tree.write("SoundpostWidget/Widget.swift", widget_source + "\n")
    if widget_catalog is not None:
        tree.write("SoundpostWidget/Localizable.xcstrings", widget_catalog)
    tree.write("SoundpostTests/T.swift", "// tests\n")


# ── The project reader ───────────────────────────────────────────────────────────

class ProjectModelTests(unittest.TestCase):
    def test_the_real_project_reads(self):
        model = project_model.load(REPO)
        apps = [t for t in model["targets"] if t["kind"] == "app"]
        self.assertEqual([t["name"] for t in apps], ["Soundpost"])
        self.assertEqual(apps[0]["roots"], ["Soundpost"])
        self.assertEqual(apps[0]["executable"], "Soundpost")

    def test_a_second_target_and_its_added_file_are_seen(self):
        tree = Tree(self)
        two_targets(tree)
        tree.write("Soundpost/Services/Door.swift", "// shared\n")
        tree.project([APP, WIDGET, TESTS], exceptions=[("Soundpost", "SoundpostWidgetExtension", ["Services/Door.swift"])])
        model = project_model.load(tree.dir)
        widget = next(t for t in model["targets"] if t["name"] == "SoundpostWidgetExtension")
        self.assertEqual(widget["kind"], "appex")
        self.assertEqual(widget["executable"], "PlugIns/SoundpostWidgetExtension.appex/SoundpostWidgetExtension")
        self.assertEqual(widget["added"], ["Soundpost/Services/Door.swift"])
        app = next(t for t in model["targets"] if t["name"] == "Soundpost")
        self.assertEqual(app["added"], [], "an exception for the extension must not change the app")

    def test_an_exception_for_the_owning_target_excludes(self):
        tree = Tree(self)
        two_targets(tree)
        tree.write("Soundpost/Info.plist", "<plist/>")
        tree.project([APP, WIDGET, TESTS], exceptions=[("Soundpost", "Soundpost", ["Info.plist"])])
        app = next(t for t in project_model.load(tree.dir)["targets"] if t["name"] == "Soundpost")
        self.assertEqual(app["excluded"], ["Soundpost/Info.plist"])
        self.assertEqual(app["roots"], ["Soundpost"], "the root vanished once it had exceptions")

    def test_a_missing_or_empty_root_is_refused(self):
        tree = Tree(self)
        two_targets(tree)
        os.remove(os.path.join(tree.dir, "SoundpostWidget", "Widget.swift"))
        with self.assertRaisesRegex(project_model.ProjectError, "holds no Swift file"):
            project_model.load(tree.dir)
        shutil.rmtree(os.path.join(tree.dir, "SoundpostWidget"))
        with self.assertRaisesRegex(project_model.ProjectError, "does not exist"):
            project_model.load(tree.dir)

    def test_a_project_without_an_app_is_refused(self):
        tree = Tree(self)
        tree.project([WIDGET])
        tree.write("SoundpostWidget/W.swift", "//\n")
        with self.assertRaisesRegex(project_model.ProjectError, "no application target"):
            project_model.load(tree.dir)

    def test_an_unknown_exception_class_is_refused(self):
        tree = Tree(self)
        two_targets(tree)
        tree.project([APP, WIDGET, TESTS], exceptions=[("Soundpost", "SoundpostWidgetExtension", ["App.swift"])])
        path = os.path.join(tree.dir, "Soundpost.xcodeproj", "project.pbxproj")
        with open(path, encoding="utf-8") as f:
            text = f.read().replace("PBXFileSystemSynchronizedBuildFileExceptionSet",
                                    "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        with self.assertRaisesRegex(project_model.ProjectError, "do not understand"):
            project_model.load(tree.dir)


# ── Localization, per target ─────────────────────────────────────────────────────

LOCALIZATION = os.path.join(HERE, "check-localization.sh")


class LocalizationGateTests(unittest.TestCase):
    def test_both_targets_catalogued_passes(self):
        tree = Tree(self)
        two_targets(tree, widget_catalog=catalog(["New capsule"]))
        r = tree.run(LOCALIZATION)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("2 target(s)", r.stdout)

    def test_the_extension_is_not_covered_by_the_apps_catalog(self):
        # The key exists — in the APP's catalog. The extension looks strings up in its own
        # bundle, so for it the string is untranslated. The pooled gate passed this.
        tree = Tree(self)
        two_targets(tree, widget_catalog=catalog(["Something else"]))
        r = tree.run(LOCALIZATION)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SoundpostWidget/Widget.swift", r.stderr)
        self.assertIn("[SoundpostWidgetExtension]", r.stderr)

    def test_an_extension_with_no_catalog_fails(self):
        tree = Tree(self)
        two_targets(tree, widget_catalog=None)
        r = tree.run(LOCALIZATION)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no Localizable.xcstrings", r.stderr)

    def test_an_english_only_catalog_fails(self):
        # Required languages used to come from each catalog alone, so a catalog with no
        # translations required nothing and printed "100% translated".
        tree = Tree(self)
        two_targets(tree, widget_catalog=catalog(["New capsule"], languages=()))
        r = tree.run(LOCALIZATION)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SoundpostWidget/Localizable.xcstrings: [ja]", r.stderr)

    def test_a_file_added_to_the_extension_is_checked_against_its_catalog(self):
        tree = Tree(self)
        two_targets(tree, widget_catalog=catalog(["New capsule"]))
        tree.write("Soundpost/Door.swift", 'static let title: LocalizedStringResource = "Shared title"\n')
        tree.write("Soundpost/Localizable.xcstrings", catalog(["New capsule", "Shared title"]))
        tree.project([APP, WIDGET, TESTS], exceptions=[("Soundpost", "SoundpostWidgetExtension", ["Door.swift"])])
        r = tree.run(LOCALIZATION)
        self.assertNotEqual(r.returncode, 0, "the shared file's string is missing from the extension's catalog")
        self.assertIn("[SoundpostWidgetExtension] \"Shared title\"", r.stderr)
        tree.write("SoundpostWidget/Localizable.xcstrings", catalog(["New capsule", "Shared title"]))
        self.assertEqual(tree.run(LOCALIZATION).returncode, 0)

    def test_widget_and_intent_copy_is_scanned(self):
        for source in ('.configurationDisplayName("Widget name")', '.description("Widget words")',
                       '.displayName("Control name")', 'IntentDescription("Intent words")',
                       'static let title: LocalizedStringResource = "Intent title"',
                       'static var caseDisplayRepresentations: [Dest: DisplayRepresentation] = [.a: "Case"]',
                       'static var typeDisplayRepresentation: TypeDisplayRepresentation = "Type"',
                       '@Parameter(title: "Parameter name") var target: Dest',
                       'static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Type name")'):
            with self.subTest(source=source):
                tree = Tree(self)
                two_targets(tree, widget_catalog=catalog(["New capsule"]), widget_source=source)
                r = tree.run(LOCALIZATION)
                self.assertNotEqual(r.returncode, 0, f"{source} was not seen")

    def test_a_source_language_only_catalog_like_app_shortcuts_passes(self):
        # AppShortcuts.xcstrings has only ja and zh-Hans localizations: en is its source.
        tree = Tree(self)
        two_targets(tree, widget_catalog=catalog(["New capsule"]))
        tree.write("Soundpost/AppShortcuts.xcstrings", catalog(["Phrase in ${applicationName}"]))
        self.assertEqual(tree.run(LOCALIZATION).returncode, 0)


# ── Warnings in any of our code ──────────────────────────────────────────────────

WARNINGS = os.path.join(HERE, "check-warnings.sh")


class WarningsGateTests(unittest.TestCase):
    def checkout(self, name):
        tree = Tree(self, name=name)
        tree.write(f"{name}.xcodeproj/project.pbxproj", "{}")
        return tree

    def run_log(self, tree, text):
        log = tree.write("build/x.log", text)
        return tree.run(WARNINGS, log)

    def test_a_widget_warning_counts_in_a_checkout_not_named_soundpost(self):
        tree = self.checkout("Clone")
        r = self.run_log(tree, f"{tree.dir}/SoundpostWidget/W.swift:3:5: warning: unused variable 'x'\n")
        self.assertEqual(r.returncode, 1, "a warning in a second target's folder went unseen")

    def test_a_target_warning_with_no_path_counts(self):
        tree = self.checkout("Soundpost")
        r = self.run_log(tree, "warning: Run script build phase 'X' will be run during every build "
                               "(in target 'SoundpostWidgetExtension' from project 'Soundpost')\n")
        self.assertEqual(r.returncode, 1)

    def test_package_and_derived_data_warnings_do_not(self):
        tree = self.checkout("Soundpost")
        r = self.run_log(tree, f"{tree.dir}/../SourcePackages/checkouts/sentry/x.swift:1:1: warning: w\n"
                               "/Users/x/Library/Developer/Xcode/DerivedData/y/z.swift:1:1: warning: w\n"
                               "2026-06-27 20:11:37.778 appintentsmetadataprocessor[1:2] warning: "
                               "Metadata extraction skipped. No AppIntents.framework dependency found.\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_macro_warning_from_any_of_our_files_counts(self):
        tree = self.checkout("Clone")
        r = self.run_log(tree, "macro expansion #require:1:54: warning: '#require(_:_:)' is redundant\n"
                               f"`- {tree.dir}/SoundpostWidgetTests/T.swift:1:1: note: expanded code originates here\n")
        self.assertEqual(r.returncode, 1)


# ── Debug-only, per binary ───────────────────────────────────────────────────────

DEBUG_ONLY = os.path.join(HERE, "check-debug-only.sh")


def macho(path, strings=(), call=None, weak=None):
    """A real Mach-O executable holding `strings`, optionally calling `call` (resolved at
    run time) or a weakly imported `weak` — enough for `strings`, `nm` and `otool`."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [f'const char *s{i} = "{s}";' for i, s in enumerate(strings)]
    body = " + ".join([f"s{i}[0]" for i in range(len(strings))] or ["0"])
    decl = ""
    if call:
        decl += f"extern void {call}(void);\n"
        body += f" + (int)(long){call}"
    if weak:
        decl += f"extern void {weak}(void) __attribute__((weak_import));\n"
        body += f" + (int)(long){weak}"
    src = decl + "\n".join(lines) + f"\nint main(void) {{ return {body}; }}\n"
    r = subprocess.run(["xcrun", "clang", "-x", "c", "-w", "-o", path, "-",
                        "-Wl,-undefined,dynamic_lookup"], input=src, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def built_app(tree, widget_strings=(WIDGET_KIND,), with_widget=True):
    app = os.path.join(tree.dir, "out", "Soundpost.app")
    macho(os.path.join(app, "Soundpost"), ["Soundpost heard"])
    if with_widget:
        macho(os.path.join(app, "PlugIns/SoundpostWidgetExtension.appex/SoundpostWidgetExtension"), widget_strings)
    return app


class DebugOnlyGateTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        two_targets(self.tree, widget_catalog=catalog(["New capsule"]))

    def test_every_binary_with_its_anchor_passes(self):
        r = self.tree.run(DEBUG_ONLY, built_app(self.tree))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("2 Release binaries", r.stdout)

    def test_a_missing_extension_binary_fails(self):
        r = self.tree.run(DEBUG_ONLY, built_app(self.tree, with_widget=False))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SoundpostWidgetExtension: no binary", r.stderr)

    def test_an_extension_binary_without_its_anchor_fails(self):
        r = self.tree.run(DEBUG_ONLY, built_app(self.tree, widget_strings=("nothing here",)))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("does not look like the SoundpostWidgetExtension binary", r.stderr)

    def test_a_debug_entry_point_in_the_extension_fails(self):
        r = self.tree.run(DEBUG_ONLY, built_app(self.tree, widget_strings=(WIDGET_KIND, "seedSampleData")))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("seedSampleData is in the Release binary of SoundpostWidgetExtension", r.stderr)

    def test_a_target_with_no_anchor_fails(self):
        other = dict(WIDGET, name="OtherExtension")
        self.tree.project([APP, other, TESTS])
        app = built_app(self.tree, with_widget=False)
        macho(os.path.join(app, "PlugIns/OtherExtension.appex/OtherExtension"), ["x"])
        r = self.tree.run(DEBUG_ONLY, app)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no premise anchor", r.stderr)


# ── One version, set once ────────────────────────────────────────────────────────

STORE = os.path.join(HERE, "check-store-metadata.py")


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        shutil.copytree(os.path.join(REPO, "metadata"), os.path.join(self.tree.dir, "metadata"),
                        ignore=shutil.ignore_patterns("* 2*"))
        shutil.copy(os.path.join(REPO, "Soundpost", "Models", "ProGate.swift"),
                    self.tree.write("Soundpost/Models/ProGate.swift", ""))
        version = project_model.load(REPO)["projectSettings"]["Release"]["MARKETING_VERSION"]
        build = project_model.load(REPO)["projectSettings"]["Release"]["CURRENT_PROJECT_VERSION"]
        self.settings = {"MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": build}
        two_targets(self.tree, widget_catalog=catalog(["New capsule"]))
        self.tree.project([APP, WIDGET, TESTS], project_settings=self.settings)

    def test_versions_set_once_pass(self):
        r = self.tree.run(sys.executable, STORE)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_target_override_fails(self):
        widget = dict(WIDGET, settings={"MARKETING_VERSION": "1.0"})
        self.tree.project([APP, widget, TESTS], project_settings=self.settings)
        r = self.tree.run(sys.executable, STORE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SoundpostWidgetExtension (Debug) overrides MARKETING_VERSION", r.stderr)

    def test_a_version_missing_from_the_project_fails(self):
        self.tree.project([APP, WIDGET, TESTS], project_settings={"MARKETING_VERSION": self.settings["MARKETING_VERSION"]})
        r = self.tree.run(sys.executable, STORE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("CURRENT_PROJECT_VERSION must be set once", r.stderr)

    def test_an_info_plist_with_its_own_version_fails(self):
        self.tree.write("SoundpostWidget-Info.plist", "<plist><dict><key>CFBundleVersion</key><string>1</string></dict></plist>")
        r = self.tree.run(sys.executable, STORE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SoundpostWidget-Info.plist sets CFBundleVersion", r.stderr)

    def test_a_version_bump_without_its_notes_fails(self):
        self.tree.project([APP, WIDGET, TESTS], project_settings=dict(self.settings, MARKETING_VERSION="9.9.9"))
        r = self.tree.run(sys.executable, STORE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("release_notes-9.9.9.txt is missing", r.stderr)

    def test_a_blocked_word_in_the_versioned_notes_fails(self):
        version = self.settings["MARKETING_VERSION"]
        for locale in ("en-US",):
            path = os.path.join(self.tree.dir, "metadata", locale, f"release_notes-{version}.txt")
            with open(path, "a", encoding="utf-8") as f:
                f.write("\nUpgrade to Pro.\n")
        r = self.tree.run(sys.executable, STORE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"release_notes-{version}.txt", r.stderr)



# The M8 promotional text — what the repo held until M23 §4H. It passed the old gate.
M8_PROMO = {
    "en-US": "Capture how a moment actually sounds — keep it as a mood-tinted waveform card, and seal it "
             "to open again on a future day. Private, offline, and honest by design.",
    "ja": "その瞬間の「音」を残そう。気分で色づく波形カードになり、未来の日付まで封印して開くこともできます。"
          "プライベートでオフライン、そして正直な設計。",
    "zh-Hans": "留住一个瞬间真实的声音。它会化作随心情上色的波形卡片，还能封存到未来某天再开启。私密、离线、坦诚设计。",
}


class PromoOfflineTests(unittest.TestCase):
    """M23 §4H: promotional text says "offline" only as "works offline" (and its JA / ZH forms)."""

    def setUp(self):
        VersionTests.setUp(self)

    def _promo(self, locale, text):
        self.tree.write(f"metadata/{locale}/promotional_text.txt", text)

    def test_the_new_texts_pass(self):
        r = self.tree.run(sys.executable, STORE)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_the_m8_text_fails_in_each_locale(self):
        for locale, text in M8_PROMO.items():
            with self.subTest(locale):
                VersionTests.setUp(self)
                self._promo(locale, text)
                r = self.tree.run(sys.executable, STORE)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(f"{locale}/promotional_text.txt says", r.stderr)

    def test_works_offline_does_not_cover_a_second_bare_offline(self):
        self._promo("en-US", "Private, and it works offline. Offline-first.")
        r = self.tree.run(sys.executable, STORE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("en-US/promotional_text.txt says 'Offline'", r.stderr)

# ── The archive ──────────────────────────────────────────────────────────────────

VERIFY = os.path.join(HERE, "verify-archive.sh")


TOOLCHAIN_ENV = "EXPECTED_RELEASE_XCODE_BUILD=27B52\nMIN_SDK=iphoneos26\n"
# What a good archive's bundles record, written as LITERALS — never read from the pin file,
# or a missing pin would compare '' with '' and pass (M23 §4C.3).
GOOD_TOOLCHAIN = {"DTXcodeBuild": "27B52", "DTSDKName": "iphoneos27.2"}


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        two_targets(self.tree, widget_catalog=catalog(["New capsule"]))
        self.tree.write("scripts/release-toolchain.env", TOOLCHAIN_ENV)

    def archive(self, widget_version=("1.12.0", "24"), point="com.apple.widgetkit-extension",
                widget_call=None, widget_weak=None, app_dsym=True, with_widget=True,
                app_toolchain=GOOD_TOOLCHAIN, widget_toolchain=GOOD_TOOLCHAIN):
        root = os.path.join(self.tree.dir, "out", "Soundpost.xcarchive")
        if os.path.exists(root):
            shutil.rmtree(root)
        app = os.path.join(root, "Products", "Applications", "Soundpost.app")
        macho(os.path.join(app, "Soundpost"), ["Soundpost heard"])
        with open(os.path.join(app, "Info.plist"), "wb") as f:
            plistlib.dump(dict({"CFBundleShortVersionString": "1.12.0", "CFBundleVersion": "24"}, **app_toolchain), f)
        if with_widget:
            ext = os.path.join(app, "PlugIns", "SoundpostWidgetExtension.appex")
            macho(os.path.join(ext, "SoundpostWidgetExtension"), [WIDGET_KIND], call=widget_call, weak=widget_weak)
            with open(os.path.join(ext, "Info.plist"), "wb") as f:
                plistlib.dump(dict({"CFBundleShortVersionString": widget_version[0], "CFBundleVersion": widget_version[1],
                                    "NSExtension": {"NSExtensionPointIdentifier": point}}, **widget_toolchain), f)
        os.makedirs(os.path.join(root, "dSYMs", "SoundpostWidgetExtension.appex.dSYM"))
        if app_dsym:
            os.makedirs(os.path.join(root, "dSYMs", "Soundpost.app.dSYM"))
        return root

    def verify(self, root):
        return self.tree.run(VERIFY, root)

    def test_a_good_archive_passes(self):
        r = self.verify(self.archive(widget_weak="ControlWidgetProbe"))
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.verify(self.archive(widget_weak="IntentExecutionTargetsProbe"))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_faults_are_each_refused(self):
        cases = {
            "a different extension version": (dict(widget_version=("1.0", "1")), "but the app is 1.12.0 (24)"),
            "the wrong extension point": (dict(point="com.apple.share-services"), "extension point is"),
            "a boot-time import": (dict(widget_call="mach_absolute_time"), "imports boot time symbols"),
            "a UserDefaults import": (dict(widget_call="NSUserDefaultsProbe"), "imports UserDefaults symbols"),
            "a network import": (dict(widget_call="NSURLSessionProbe"), "imports network symbols"),
            "an iOS 18 symbol bound strongly": (dict(widget_call="ControlWidgetProbe"), "binds a post-iOS-17 symbol strongly"),
            # W7 (M23 §4C.6): the control's intent names an iOS 27 type in the extension.
            "an iOS 27 symbol bound strongly": (dict(widget_call="IntentExecutionTargetsProbe"),
                                                "binds a post-iOS-17 symbol strongly"),
            "only the extension's dSYM": (dict(app_dsym=False), "no Soundpost.app.dSYM"),
            "the extension missing": (dict(with_widget=False), "SoundpostWidgetExtension: no executable"),
        }
        for name, (kwargs, message) in cases.items():
            with self.subTest(name):
                r = self.verify(self.archive(**kwargs))
                self.assertNotEqual(r.returncode, 0, f"{name} passed")
                self.assertIn(message, r.stderr)

    # M23 §4C.3 — the release refuses an untested toolchain
    def test_the_toolchain_is_printed_for_every_binary(self):
        r = self.verify(self.archive())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Soundpost.app: DTXcodeBuild=27B52 DTSDKName=iphoneos27.2", r.stdout)
        self.assertIn("SoundpostWidgetExtension.appex: DTXcodeBuild=27B52", r.stdout)

    def test_a_missing_or_empty_pin_is_fatal(self):
        pin = os.path.join(self.tree.dir, "scripts", "release-toolchain.env")
        for content in (None, ""):
            with self.subTest(content=content):
                if content is None:
                    os.remove(pin)
                else:
                    self.tree.write("scripts/release-toolchain.env", content)
                r = self.verify(self.archive())
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("no release toolchain pin", r.stderr)

    def test_a_malformed_pin_is_fatal(self):
        self.tree.write("scripts/release-toolchain.env", "EXPECTED_RELEASE_XCODE_BUILD=latest\nMIN_SDK=iphoneos26\n")
        r = self.verify(self.archive())
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is not an Xcode build number", r.stderr)

    def test_toolchain_faults_are_each_refused(self):
        older = {"DTXcodeBuild": "27A9275", "DTSDKName": "iphoneos27.1"}
        cases = {
            "the app built by another Xcode": (dict(app_toolchain=older), "Soundpost.app was built by Xcode 27A9275"),
            "the app right, the extension not": (dict(widget_toolchain=older),
                                                 "SoundpostWidgetExtension.appex was built by Xcode 27A9275"),
            "no DTXcodeBuild in the app": (dict(app_toolchain={"DTSDKName": "iphoneos27.2"}), "Soundpost.app records no DTXcodeBuild"),
            "no DTSDKName in the extension": (dict(widget_toolchain={"DTXcodeBuild": "27B52"}),
                                              "SoundpostWidgetExtension.appex records no DTSDKName"),
            "an SDK below the minimum": (dict(app_toolchain={"DTXcodeBuild": "27B52", "DTSDKName": "iphoneos18.5"}),
                                         "built against iphoneos18.5, below the minimum iphoneos26"),
        }
        for name, (kwargs, message) in cases.items():
            with self.subTest(name):
                r = self.verify(self.archive(**kwargs))
                self.assertNotEqual(r.returncode, 0, f"{name} passed")
                self.assertIn(message, r.stderr)




# ── CI's simulator, by name (M23 §4C.4) ──────────────────────────────────────────

PICKER = os.path.join(HERE, "ci", "pick_simulator.py")


def simctl_json(runtimes):
    """{runtime suffix: [device names]} -> simctl's `list devices available -j` shape."""
    return json.dumps({"devices": {
        f"com.apple.CoreSimulator.SimRuntime.iOS-{rt}": [
            {"name": n, "udid": f"{rt}-{n}".replace(" ", "_"), "isAvailable": True} for n in names]
        for rt, names in runtimes.items()}})


class SimulatorPickerTests(unittest.TestCase):
    def pick(self, runtimes, name="iPhone 17", min_major="27"):
        return subprocess.run([sys.executable, PICKER, name, min_major], input=simctl_json(runtimes),
                              capture_output=True, text=True)

    # The xcode-27 image (actions/runner-images, read 2026-11-12) has runtimes whose only
    # device is `iPhone Duo`; "the first iPhone on the newest runtime" picks it.
    def test_the_named_device_on_the_newest_runtime_that_offers_it(self):
        r = self.pick({"27-2": ["iPhone Duo"], "27-0": ["iPhone 17", "iPhone 17e"]})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "27-0-iPhone_17")

    def test_a_newer_runtime_wins_when_it_has_the_device(self):
        r = self.pick({"27-2": ["iPhone 17", "iPhone Duo"], "27-1": ["iPhone Duo"], "27-0": ["iPhone 17"]})
        self.assertEqual(r.stdout.strip(), "27-2-iPhone_17")

    def test_no_such_device_fails_and_says_what_exists(self):
        r = self.pick({"27-2": ["iPhone Duo"]})
        self.assertEqual(r.returncode, 1)
        self.assertIn("no available 'iPhone 17' on an iOS 27+ runtime", r.stderr)
        self.assertIn("iPhone Duo (iOS 27.2.0)", r.stderr)

    def test_a_runtime_below_the_minimum_does_not_count(self):
        r = self.pick({"26-5": ["iPhone 17"], "27-2": ["iPhone Duo"]})
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.pick({"26-5": ["iPhone 17"]}, min_major="26").stdout.strip(), "26-5-iPhone_17")

    def test_ci_uses_the_picker_by_name(self):
        ci = read_ci()
        self.assertTrue("scripts/ci/pick_simulator.py" in ci, "ci.yml does not use the picker")
        self.assertFalse("startswith('iPhone')" in ci, "the old first-iPhone picker is still in ci.yml")


def read_ci():
    with open(os.path.join(REPO, ".github", "workflows", "ci.yml"), encoding="utf-8") as f:
        return f.read()


class CiParityTests(unittest.TestCase):
    """M23 §4C.2: every toolchain CI runs is an entry of one matrix job, so each runs every
    step; the only step gated on an entry is the release-pin assertion (the delivery-server
    step moved to the `server` job, §4C.5). Since D23 the 27.2 entry is the only one."""

    def test_the_shipping_toolchain_is_an_entry_of_the_one_job(self):
        # D23 retired the 26.6 entry; the 27.2 one is the build releases are made with.
        ci = read_ci()
        for line in ('xcode: "Xcode 27.2"', "image: xcode-27",
                     "developer_dir: /Applications/Xcode_27.2.app/Contents/Developer",
                     "release_toolchain: true"):
            self.assertTrue(line in ci, f"ci.yml lacks {line!r}")
        self.assertEqual(ci.count("          - xcode: "), 1 + ci.count('          - xcode: "Xcode 26'),
                         "an entry that is neither 27.2 nor a restored 26.x")

    def test_only_the_release_pin_differs_between_the_toolchains(self):
        lines = read_ci().splitlines()
        gated = [lines[i - 1].strip() for i, l in enumerate(lines) if l.strip().startswith("if: matrix.")]
        self.assertEqual(gated, ["- name: Assert the release toolchain pin"])

    def test_the_floors_are_workflow_level(self):
        ci = read_ci()
        top = ci[:ci.index("\njobs:")]
        self.assertRegex(top, r'\n  MIN_TESTS: "\d+"')
        self.assertRegex(top, r'\n  MIN_PY_TESTS: "\d+"')
        self.assertFalse(re.search(r'\n {6,}MIN_TESTS:', ci), "a job sets its own MIN_TESTS")

# ── The release path (M23 §4B) ───────────────────────────────────────────────────
#
# The decisions live in scripts/lib/release_policy.sh so these fixtures reach them
# without an ASC key, a keychain or a network: each fixture fails against the old scripts
# for the reason under test (an archive overwritten, a lock file counted as a dirty
# tree, an upload without dSYMs), never because a credential is missing (§4B.0).

POLICY = os.path.join(HERE, "lib", "release_policy.sh")
PREFLIGHT = os.path.join(HERE, "release-preflight.sh")
DSYMS = os.path.join(HERE, "upload-dsyms.sh")
TODAY = "2026-11-12"


def bash_policy(call, env=None, cwd=None):
    """Run one release_policy.sh function: `bash -c 'source …; <call>'`."""
    full = dict(os.environ)
    full.pop("RELEASE_PREFLIGHT_OVERRIDE", None)
    full.pop("RELEASE_PREFLIGHT_ALLOW", None)
    full.update(env or {})
    return subprocess.run(["/bin/bash", "-c", f'source "{POLICY}"; {call}'],
                          capture_output=True, text=True, env=full, cwd=cwd)


def make_archive(root, date, name, upload=None, marker=None):
    """An .xcarchive whose Info.plist records `upload`: None, "success" or "failed"."""
    path = os.path.join(root, date, name)
    os.makedirs(path)
    info = {"ApplicationProperties": {"CFBundleShortVersionString": "1.13.0", "CFBundleVersion": "25"}}
    if upload:
        info["Distributions"] = [{"destination": "upload", "uploadEvent": {"state": upload}}]
    with open(os.path.join(path, "Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    if marker:
        with open(os.path.join(path, marker), "w") as f:
            f.write("an earlier attempt\n")
    return path


def stub(bin_dir, name, body):
    os.makedirs(bin_dir, exist_ok=True)
    path = os.path.join(bin_dir, name)
    with open(path, "w") as f:
        f.write("#!/bin/bash\n" + body + "\n")
    os.chmod(path, 0o755)
    return path


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
                   cwd=cwd, check=True, capture_output=True)


def shipping_tree(test):
    """A project tree with every root the copy scan requires."""
    tree = Tree(test)
    two_targets(tree, widget_catalog=catalog(["New capsule"]))
    for d in ("metadata/en-US", "scripts", "backend/supabase"):
        tree.write(f"{d}/keep.txt", "x\n")
    tree.write("scripts/release-toolchain.env", TOOLCHAIN_ENV)
    return tree


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="archives-")
        self.addCleanup(shutil.rmtree, self.root, True)

    def plan(self, version="1.13.0", build="25"):
        return bash_policy(f'archive_plan "{self.root}" {version} {build} {TODAY}')

    # §4B.2 — archives leave iCloud, and nothing is overwritten
    def test_the_default_archive_is_in_xcodes_archives_under_its_version(self):
        r = bash_policy(f'default_archive_path "$HOME/Library/Developer/Xcode/Archives" 1.13.0 25 {TODAY}')
        self.assertEqual(r.stdout.strip(), os.path.expanduser(
            f"~/Library/Developer/Xcode/Archives/{TODAY}/Soundpost 1.13.0 (25).xcarchive"))
        r = self.plan()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), f"{self.root}/{TODAY}/Soundpost 1.13.0 (25).xcarchive")

    def test_a_build_already_uploaded_is_refused(self):
        uploaded = make_archive(self.root, "2026-11-10", "Soundpost 1.13.0 (25).xcarchive", upload="success")
        r = self.plan()
        self.assertEqual(r.returncode, 1)
        self.assertIn("was already uploaded to App Store Connect", r.stderr)
        self.assertIn(uploaded, r.stderr)

    def test_a_failed_upload_moves_on_to_the_next_name(self):
        make_archive(self.root, TODAY, "Soundpost 1.13.0 (25).xcarchive", upload="failed")
        r = self.plan()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), f"{self.root}/{TODAY}/Soundpost 1.13.0 (25) - attempt 2.xcarchive")

    def test_an_earlier_unuploaded_attempt_is_left_intact(self):
        # A plain existence check would refuse here, and dead-end every retry after a
        # failure between the archive and the upload.
        old = make_archive(self.root, "2026-11-11", "Soundpost 1.13.0 (25).xcarchive", marker="kept")
        r = self.plan()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), f"{self.root}/{TODAY}/Soundpost 1.13.0 (25) - attempt 2.xcarchive")
        self.assertTrue(os.path.isfile(os.path.join(old, "kept")))
        self.assertIn("left as they are", r.stderr)

    def test_attempt_numbers_skip_names_already_taken(self):
        make_archive(self.root, "2026-11-11", "Soundpost 1.13.0 (25).xcarchive")
        make_archive(self.root, "2026-11-11", "Soundpost 1.13.0 (25) - attempt 2.xcarchive")
        self.assertTrue(self.plan().stdout.strip().endswith("Soundpost 1.13.0 (25) - attempt 3.xcarchive"))

    def test_other_builds_and_versions_do_not_count(self):
        make_archive(self.root, "2026-11-10", "Soundpost 1.13.0 (24).xcarchive", upload="success")
        make_archive(self.root, "2026-11-10", "Soundpost 1.13.0 (250).xcarchive", upload="success")
        make_archive(self.root, "2026-11-10", "Soundpost 1.12.0 (25).xcarchive", upload="success")
        r = self.plan()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.strip().endswith(f"{TODAY}/Soundpost 1.13.0 (25).xcarchive"))

    # §4B.3 — one dirty rule
    def repo(self):
        repo = os.path.join(self.root, "repo")
        os.makedirs(os.path.join(repo, ".claude"))
        with open(os.path.join(repo, ".claude", "settings.json"), "w") as f:
            f.write("{}\n")
        with open(os.path.join(repo, "README"), "w") as f:
            f.write("x\n")
        git(repo, "init", "-q")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "init")
        return repo

    def dirty(self, repo):
        return bash_policy(f'tree_is_dirty "{repo}"')

    def touch(self, repo, rel, text=""):
        path = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def test_another_sessions_untracked_lock_is_not_dirt(self):
        repo = self.repo()
        self.touch(repo, ".claude/scheduled_tasks 2.lock")
        self.touch(repo, ".claude/worktrees/w/Soundpost/X 2.swift")
        r = self.dirty(repo)
        self.assertEqual(r.returncode, 1, f"counted as dirty: {r.stdout}")

    def test_an_untracked_file_elsewhere_is_dirt(self):
        repo = self.repo()
        self.touch(repo, "Soundpost/X 2.swift")
        r = self.dirty(repo)
        self.assertEqual(r.returncode, 0)
        self.assertIn("Soundpost/X 2.swift", r.stdout)

    def test_a_tracked_change_under_claude_is_dirt(self):
        # A pathspec exclude of .claude would hide this one too.
        repo = self.repo()
        self.touch(repo, ".claude/settings.json", '{"changed": true}\n')
        r = self.dirty(repo)
        self.assertEqual(r.returncode, 0)
        self.assertIn(".claude/settings.json", r.stdout)

    def test_a_git_that_cannot_answer_is_dirt(self):
        r = self.dirty(os.path.join(self.root, "not-a-repo"))
        self.assertEqual(r.returncode, 0)
        self.assertIn("git status failed", r.stdout)

    # §4B.3 — named overrides only
    def test_only_three_checks_can_be_named(self):
        ok = bash_policy("allow_validate && allow_has keychain && ! allow_has dirty",
                         {"RELEASE_PREFLIGHT_ALLOW": "copies,keychain,build-number"})
        self.assertEqual(ok.returncode, 0, ok.stderr)
        for name, message in (("dirty", "HEAD/clean guard decides"), ("sentry", "requires its dSYMs"),
                              ("everything", "unknown check 'everything'")):
            with self.subTest(name):
                r = bash_policy("allow_validate", {"RELEASE_PREFLIGHT_ALLOW": f"copies,{name}"})
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(message, r.stderr)

    def test_the_old_override_is_refused_by_name(self):
        r = bash_policy("legacy_override_refused", {"RELEASE_PREFLIGHT_OVERRIDE": "yes"})
        self.assertEqual(r.returncode, 0)
        self.assertIn("RELEASE_PREFLIGHT_ALLOW=<check>", r.stderr)
        self.assertEqual(bash_policy("legacy_override_refused").returncode, 1)

    # §4B.3 — the copy scan covers what ships, and fails closed
    def scan(self, tree, shots=""):
        return bash_policy(f'copy_scan "{tree.dir}" "{shots}"')

    def test_a_copy_in_a_source_root_is_found(self):
        tree = shipping_tree(self)
        tree.write("Soundpost/X 2.swift", "//\n")
        r = self.scan(tree)
        self.assertEqual(r.returncode, 1)
        self.assertIn("Soundpost/X 2.swift", r.stdout)

    def test_copies_under_claude_are_ignored(self):
        tree = shipping_tree(self)
        tree.write(".claude/x 2.lock", "")
        tree.write(".claude/worktrees/w/Soundpost/X 2.swift", "//\n")
        r = self.scan(tree)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_a_missing_required_root_fails_closed(self):
        tree = shipping_tree(self)
        shutil.rmtree(os.path.join(tree.dir, "backend"))
        r = self.scan(tree)
        self.assertEqual(r.returncode, 2)
        self.assertIn("required scan root(s) missing: backend/", r.stdout)

    def test_a_project_that_cannot_be_read_fails_closed(self):
        tree = shipping_tree(self)
        shutil.rmtree(os.path.join(tree.dir, "Soundpost.xcodeproj"))
        r = self.scan(tree)
        self.assertEqual(r.returncode, 2)
        self.assertIn("project reader failed", r.stdout)

    def test_the_screenshot_folder_counts_only_when_present(self):
        tree = shipping_tree(self)
        self.assertEqual(self.scan(tree, os.path.join(self.root, "no-shots")).returncode, 0)
        shots = os.path.join(self.root, "shots")
        os.makedirs(os.path.join(shots, "ja"))
        open(os.path.join(shots, "ja", "01-gallery 2.png"), "w").close()
        r = self.scan(tree, shots)
        self.assertEqual(r.returncode, 1)
        self.assertIn("01-gallery 2.png", r.stdout)

    # §4B.6 — a rejected token is fatal, anything else only warns
    def test_the_sentry_probe_verdicts(self):
        for code, status in (("200", 0), ("401", 1), ("403", 2), ("000", 2), ("500", 2)):
            with self.subTest(code):
                self.assertEqual(bash_policy(f"sentry_probe_verdict {code}").returncode, status)

    def test_only_an_upload_pushes_a_tag(self):
        self.assertEqual(bash_policy("should_push_tag upload").returncode, 0)
        self.assertEqual(bash_policy("should_push_tag archive").returncode, 1)


class PreflightTests(unittest.TestCase):
    """The preflight on a fixture tree (GATE_PROJECT_DIR), archive mode unless stated, with a
    stub `security` that reports a locked keychain — allowed by name, so the check under
    test is the one that decides."""

    def run_preflight(self, tree, mode="archive", allow="keychain", extra=None, xcode_build="27B52"):
        bin_dir = os.path.join(tree.dir, "..", "bin")
        stub(bin_dir, "security", 'echo "User interaction is not allowed."; exit 51')
        stub(bin_dir, "xcodebuild", f'[ "$1" = "-version" ] && printf "Xcode 27.2\\nBuild version {xcode_build}\\n"; exit 0')
        stub(bin_dir, "sentry-cli", "exit 0")
        env = dict(os.environ, GATE_PROJECT_DIR=tree.dir, PATH=f"{bin_dir}:{os.environ['PATH']}",
                   SOUNDPOST_SCREENSHOT_DIR=os.path.join(tree.dir, "..", "no-shots"),
                   ASC_PYTHON=os.path.join(tree.dir, "..", "no-venv", "python3"))
        env.pop("RELEASE_PREFLIGHT_OVERRIDE", None)
        env.pop("SENTRY_AUTH_TOKEN", None)
        if allow is not None:
            env["RELEASE_PREFLIGHT_ALLOW"] = allow
        else:
            env.pop("RELEASE_PREFLIGHT_ALLOW", None)
        env.update(extra or {})
        return subprocess.run([PREFLIGHT, mode], capture_output=True, text=True, env=env)

    def test_a_clean_tree_passes(self):
        r = self.run_preflight(shipping_tree(self))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("no iCloud conflict copies", r.stdout)

    def test_a_copy_in_the_app_is_refused_and_named(self):
        tree = shipping_tree(self)
        tree.write("Soundpost/X 2.swift", "//\n")
        r = self.run_preflight(tree)
        self.assertEqual(r.returncode, 1)
        self.assertIn("iCloud conflict copies would compile into the build", r.stdout)
        self.assertIn("Soundpost/X 2.swift", r.stdout)

    def test_other_sessions_files_do_not_block_a_release(self):
        tree = shipping_tree(self)
        tree.write(".claude/scheduled_tasks 2.lock", "")
        tree.write(".claude/worktrees/w/Soundpost/X 2.swift", "//\n")
        r = self.run_preflight(tree)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_a_missing_scan_root_is_a_failure_not_a_pass(self):
        tree = shipping_tree(self)
        shutil.rmtree(os.path.join(tree.dir, "metadata"))
        r = self.run_preflight(tree)
        self.assertEqual(r.returncode, 1)
        self.assertIn("the copy scan could not run", r.stdout)

    def test_copies_can_be_named_and_only_then_pass(self):
        tree = shipping_tree(self)
        tree.write("Soundpost/X 2.swift", "//\n")
        r = self.run_preflight(tree, allow="keychain,copies")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("allowed: RELEASE_PREFLIGHT_ALLOW=copies", r.stdout)

    def test_the_old_override_and_unknown_names_are_refused(self):
        tree = shipping_tree(self)
        r = self.run_preflight(tree, extra={"RELEASE_PREFLIGHT_OVERRIDE": "yes"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("RELEASE_PREFLIGHT_OVERRIDE is retired", r.stderr)
        for name in ("dirty", "sentry"):
            r = self.run_preflight(tree, allow=f"keychain,{name}")
            self.assertEqual(r.returncode, 1, name)
            self.assertIn(f"RELEASE_PREFLIGHT_ALLOW={name} is not a check you can go past", r.stderr)

    def test_another_xcode_is_refused_with_the_two_ways_out(self):
        # §4C.3: an Xcode that auto-updated is caught before the archive, and no ALLOW name
        # reaches this check.
        r = self.run_preflight(shipping_tree(self), xcode_build="27C10", allow="keychain,copies,build-number")
        self.assertEqual(r.returncode, 1)
        self.assertIn("this Mac's Xcode is build 27C10, but releases are pinned to 27B52", r.stdout)
        self.assertIn("DEVELOPER_DIR=", r.stdout)
        self.assertIn("bump the pin in a commit whose CI ran on the new build", r.stdout)

    def test_a_missing_pin_is_refused(self):
        tree = shipping_tree(self)
        os.remove(os.path.join(tree.dir, "scripts", "release-toolchain.env"))
        r = self.run_preflight(tree)
        self.assertEqual(r.returncode, 1)
        self.assertIn("no release toolchain pin", r.stdout)

    def test_the_pinned_xcode_passes(self):
        r = self.run_preflight(shipping_tree(self))
        self.assertIn("Xcode build 27B52, as pinned", r.stdout)

    def committed(self):
        tree = shipping_tree(self)
        tree.write(".claude/settings.json", "{}\n")
        git(tree.dir, "init", "-q")
        git(tree.dir, "add", "-A")
        git(tree.dir, "commit", "-qm", "init")
        return tree

    def upload(self, tree):
        return self.run_preflight(tree, mode="upload", allow="keychain,build-number",
                                  extra={"SENTRY_AUTH_TOKEN": "sntryu_fixture"})

    def test_upload_counts_untracked_claude_files_as_clean(self):
        tree = self.committed()
        tree.write(".claude/scheduled_tasks 2.lock", "")
        r = self.upload(tree)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("working tree clean", r.stdout)

    def test_upload_refuses_any_other_change(self):
        for rel, text in (("docs/new.md", "x\n"), (".claude/settings.json", '{"changed": 1}\n')):
            with self.subTest(rel):
                tree = self.committed()
                tree.write(rel, text)
                r = self.upload(tree)
                self.assertEqual(r.returncode, 1)
                self.assertIn("the working tree is not clean", r.stdout)
                self.assertIn(rel, r.stdout)

    def test_upload_without_a_token_is_refused_and_cannot_be_allowed(self):
        tree = self.committed()
        r = self.run_preflight(tree, mode="upload", allow="keychain,build-number,copies")
        self.assertEqual(r.returncode, 1)
        self.assertIn("SENTRY_AUTH_TOKEN is not set", r.stdout)


XCODEBUILD_STUB = r'''
prev=""; ap=""; ep=""
for a in "$@"; do
  [ "$prev" = "-archivePath" ] && ap="$a"
  [ "$prev" = "-exportPath" ] && ep="$a"
  prev="$a"
done
if [ "$1" = "archive" ]; then
  mkdir -p "$ap/dSYMs/Soundpost.app.dSYM" "$ap/Products/Applications/Soundpost.app"
  printf '<plist version="1.0"><dict/></plist>' > "$ap/Info.plist"
elif [ "$1" = "-exportArchive" ]; then
  mkdir -p "$ep"
fi'''

# git: HEAD is $GIT_HEAD, or $GIT_HEAD_LATER after the first answer; status is a file.
GIT_STUB = r'''
args=" $* "
case "$args" in
  *" rev-parse -q --verify refs/tags/"*) exit 1 ;;
  *" rev-parse --verify HEAD "*)
    n=$(cat "$STUB_STATE/heads" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_STATE/heads"
    if [ "$n" -gt 0 ] && [ -n "${GIT_HEAD_LATER:-}" ]; then echo "$GIT_HEAD_LATER"; else echo "${GIT_HEAD:-abc1234def}"; fi ;;
  *" status --porcelain"*) cat "$STUB_STATE/status" 2>/dev/null; exit 0 ;;
  *" push origin "*) exit "${GIT_PUSH_EXIT:-0}" ;;
  *) exit 0 ;;
esac'''


class BuildUploadTests(unittest.TestCase):
    """build-upload-asc.sh end to end, in a temp tree: the real script and policy, stub
    preflight / verify-archive / upload-dsyms scripts, and stub xcodebuild, git and curl on
    PATH that log every call. HOME is a temp folder, so the default archives root is too."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="upload-")
        self.addCleanup(shutil.rmtree, self.base, True)
        self.dir = os.path.join(self.base, "Soundpost")
        self.home = os.path.join(self.base, "home")
        self.log = os.path.join(self.base, "calls.log")
        scripts = os.path.join(self.dir, "scripts")
        os.makedirs(os.path.join(scripts, "lib"))
        shutil.copy(os.path.join(HERE, "build-upload-asc.sh"), scripts)
        shutil.copy(POLICY, os.path.join(scripts, "lib"))
        log = 'echo "$(basename "$0") $*" >> "$STUB_LOG"'
        stub(scripts, "release-preflight.sh", log + "\nexit 0")
        stub(scripts, "verify-archive.sh", log + "\nexit 0")
        stub(scripts, "upload-dsyms.sh", log + '\n'
             'if [ "$1" = "--required" ] && [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then exit 1; fi\n'
             'exit "${DSYM_EXIT:-0}"')
        os.makedirs(os.path.join(self.dir, "Soundpost.xcodeproj"))
        with open(os.path.join(self.dir, "Soundpost.xcodeproj", "project.pbxproj"), "w") as f:
            f.write("\t\t\t\tMARKETING_VERSION = 1.13.0;\n\t\t\t\tCURRENT_PROJECT_VERSION = 25;\n"
                    "\t\t\t\tMARKETING_VERSION = 1.13.0;\n\t\t\t\tCURRENT_PROJECT_VERSION = 25;\n")
        self.bin = os.path.join(self.base, "bin")
        stub(self.bin, "xcodebuild", log + XCODEBUILD_STUB)
        stub(self.bin, "git", log + GIT_STUB)
        stub(self.bin, "curl", 'echo -n "${CURL_CODE:-200}"')
        stub(self.bin, "sentry-cli", "exit 0")
        self.key = os.path.join(self.base, "AuthKey_TEST.p8")
        open(self.key, "w").close()

    def status(self, text):
        with open(os.path.join(self.base, "status"), "w") as f:
            f.write(text)

    def run_upload(self, mode="upload", **env):
        full = dict(os.environ, HOME=self.home, PATH=f"{self.bin}:{os.environ['PATH']}",
                    ASC_API_KEY_PATH=self.key, CK_SKIP_SCHEMA_CHECK="yes", SENTRY_AUTH_TOKEN="sntryu_fixture",
                    STUB_LOG=self.log, STUB_STATE=self.base)
        for k in ("RELEASE_PREFLIGHT_OVERRIDE", "RELEASE_PREFLIGHT_ALLOW", "ARCHIVE_PATH", "EXPORT_PATH",
                  "ARCHIVES_ROOT"):
            full.pop(k, None)
        for k, v in env.items():
            if v is None:
                full.pop(k, None)
            else:
                full[k] = v
        r = subprocess.run([os.path.join(self.dir, "scripts", "build-upload-asc.sh"), mode],
                           capture_output=True, text=True, env=full)
        calls = ""
        if os.path.exists(self.log):
            with open(self.log, encoding="utf-8") as f:
                calls = f.read()
        return r, calls

    @property
    def archives(self):
        return os.path.join(self.home, "Library", "Developer", "Xcode", "Archives")

    def today_archive(self, suffix=""):
        import datetime
        return os.path.join(self.archives, datetime.date.today().isoformat(),
                            f"Soundpost 1.13.0 (25){suffix}.xcarchive")

    def test_an_upload_archives_into_xcodes_archives_and_pushes_its_tag_once(self):
        r, calls = self.run_upload()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"-archivePath {self.today_archive()}", calls)
        self.assertTrue(os.path.isdir(self.today_archive()))
        self.assertEqual(len([l for l in calls.splitlines() if " push origin v1.13.0-b25" in l]), 1)
        self.assertIn("Pushed v1.13.0-b25 to origin.", r.stdout)
        self.assertIn(os.path.join(self.home, "Library/Caches/Soundpost-build/export/1.13.0-25"), calls)

    def test_a_failed_tag_push_still_reports_the_upload(self):
        r, calls = self.run_upload(GIT_PUSH_EXIT="1")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("Push it by hand: git push origin v1.13.0-b25", r.stdout)

    def test_archive_mode_never_tags_or_pushes(self):
        r, calls = self.run_upload("archive")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn(" push ", calls)
        self.assertNotIn(" tag ", calls)

    def test_an_upload_without_a_token_is_refused_before_archiving(self):
        r, calls = self.run_upload(SENTRY_AUTH_TOKEN=None)
        self.assertEqual(r.returncode, 1)
        self.assertIn("refusing to upload — SENTRY_AUTH_TOKEN is not set", r.stdout)
        self.assertNotIn("xcodebuild archive", calls)

    def test_a_rejected_token_is_refused_before_archiving(self):
        r, calls = self.run_upload(CURL_CODE="401")
        self.assertEqual(r.returncode, 1)
        self.assertIn("token rejected", r.stdout)
        self.assertNotIn("xcodebuild archive", calls)

    def test_a_forbidden_probe_only_warns(self):
        r, calls = self.run_upload(CURL_CODE="403")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("WARN: the Sentry probe answered HTTP 403", r.stdout)
        self.assertIn("upload-dsyms.sh --required", calls)

    def test_an_upload_requires_its_dsyms(self):
        r, calls = self.run_upload(DSYM_EXIT="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("the dSYM upload to Sentry failed", r.stdout)
        self.assertIn("upload-dsyms.sh --required", calls)
        self.assertNotIn("-exportArchive", calls)
        self.assertTrue(os.path.isdir(self.today_archive()), "the archive was not kept")

    def test_an_uploaded_build_is_refused_before_archiving(self):
        make_archive(self.archives, "2026-11-01", "Soundpost 1.13.0 (25).xcarchive", upload="success")
        r, calls = self.run_upload()
        self.assertEqual(r.returncode, 1)
        self.assertIn("was already uploaded to App Store Connect", r.stderr)
        self.assertNotIn("xcodebuild archive", calls)

    def test_a_failed_attempt_is_kept_and_the_next_name_used(self):
        import datetime
        old = make_archive(self.archives, datetime.date.today().isoformat(),
                           "Soundpost 1.13.0 (25).xcarchive", upload="failed", marker="kept")
        r, calls = self.run_upload()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"-archivePath {self.today_archive(' - attempt 2')}", calls)
        self.assertTrue(os.path.isfile(os.path.join(old, "kept")), "an earlier attempt was touched")

    def test_an_existing_explicit_archive_path_is_refused(self):
        existing = make_archive(self.base, "x", "Mine.xcarchive", marker="kept")
        r, calls = self.run_upload("archive", ARCHIVE_PATH=existing)
        self.assertEqual(r.returncode, 1)
        self.assertIn("nothing here overwrites an archive", r.stdout)
        self.assertTrue(os.path.isfile(os.path.join(existing, "kept")))

    def test_another_sessions_lock_does_not_block_the_upload(self):
        self.status('?? ".claude/scheduled_tasks 2.lock"\n')
        r, calls = self.run_upload()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_change_during_the_archive_is_refused(self):
        self.status('?? "Soundpost/X 2.swift"\n')
        r, calls = self.run_upload()
        self.assertEqual(r.returncode, 1)
        self.assertIn("the checkout changed while the archive ran", r.stdout)
        self.assertNotIn("-exportArchive", calls)

    def test_head_moving_during_the_archive_is_refused(self):
        r, calls = self.run_upload(GIT_HEAD_LATER="fff9999aaa")
        self.assertEqual(r.returncode, 1)
        self.assertIn("now fff9999aaa", r.stdout)
        self.assertNotIn("-exportArchive", calls)

    def test_no_setting_skips_the_head_guard_or_the_dsyms(self):
        r, calls = self.run_upload(RELEASE_PREFLIGHT_OVERRIDE="yes")
        self.assertEqual(r.returncode, 1)
        self.assertIn("RELEASE_PREFLIGHT_OVERRIDE is retired", r.stderr)
        self.assertNotIn("xcodebuild archive", calls)
        for name in ("dirty", "sentry"):
            r, _ = self.run_upload(RELEASE_PREFLIGHT_ALLOW=name)
            self.assertEqual(r.returncode, 1, name)


class UploadDsymsTests(unittest.TestCase):
    def run_dsyms(self, *args, token=None, with_cli=True):
        bin_dir = tempfile.mkdtemp(prefix="dsym-bin-")
        self.addCleanup(shutil.rmtree, bin_dir, True)
        if with_cli:
            stub(bin_dir, "sentry-cli", "exit 0")
        env = dict(os.environ, PATH=f"{bin_dir}:/usr/bin:/bin")
        env.pop("SENTRY_AUTH_TOKEN", None)
        if token:
            env["SENTRY_AUTH_TOKEN"] = token
        return subprocess.run(["/bin/bash", DSYMS, *args], capture_output=True, text=True, env=env)

    def test_required_without_a_token_fails(self):
        r = self.run_dsyms("--required", "/nowhere.xcarchive")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("were NOT uploaded", r.stderr)

    def test_required_without_sentry_cli_fails(self):
        r = self.run_dsyms("--required", "/nowhere.xcarchive", token="t", with_cli=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("sentry-cli not installed", r.stderr)

    def test_a_dry_archive_without_a_token_still_only_warns(self):
        r = self.run_dsyms("/nowhere.xcarchive")
        self.assertEqual(r.returncode, 0)
        self.assertIn("skipping dSYM upload", r.stdout)

    def test_required_with_a_token_uploads(self):
        r = self.run_dsyms("--required", "/nowhere.xcarchive", token="t")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("debug-files upload (/nowhere.xcarchive)", r.stdout)

if __name__ == "__main__":
    unittest.main()
