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
                       'static var typeDisplayRepresentation: TypeDisplayRepresentation = "Type"'):
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


# ── The archive ──────────────────────────────────────────────────────────────────

VERIFY = os.path.join(HERE, "verify-archive.sh")


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        two_targets(self.tree, widget_catalog=catalog(["New capsule"]))

    def archive(self, widget_version=("1.12.0", "24"), point="com.apple.widgetkit-extension",
                widget_call=None, widget_weak=None, app_dsym=True, with_widget=True):
        root = os.path.join(self.tree.dir, "out", "Soundpost.xcarchive")
        if os.path.exists(root):
            shutil.rmtree(root)
        app = os.path.join(root, "Products", "Applications", "Soundpost.app")
        macho(os.path.join(app, "Soundpost"), ["Soundpost heard"])
        with open(os.path.join(app, "Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleShortVersionString": "1.12.0", "CFBundleVersion": "24"}, f)
        if with_widget:
            ext = os.path.join(app, "PlugIns", "SoundpostWidgetExtension.appex")
            macho(os.path.join(ext, "SoundpostWidgetExtension"), [WIDGET_KIND], call=widget_call, weak=widget_weak)
            with open(os.path.join(ext, "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleShortVersionString": widget_version[0], "CFBundleVersion": widget_version[1],
                               "NSExtension": {"NSExtensionPointIdentifier": point}}, f)
        os.makedirs(os.path.join(root, "dSYMs", "SoundpostWidgetExtension.appex.dSYM"))
        if app_dsym:
            os.makedirs(os.path.join(root, "dSYMs", "Soundpost.app.dSYM"))
        return root

    def verify(self, root):
        return self.tree.run(VERIFY, root)

    def test_a_good_archive_passes(self):
        r = self.verify(self.archive(widget_weak="ControlWidgetProbe"))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_faults_are_each_refused(self):
        cases = {
            "a different extension version": (dict(widget_version=("1.0", "1")), "but the app is 1.12.0 (24)"),
            "the wrong extension point": (dict(point="com.apple.share-services"), "extension point is"),
            "a boot-time import": (dict(widget_call="mach_absolute_time"), "imports boot time symbols"),
            "a UserDefaults import": (dict(widget_call="NSUserDefaultsProbe"), "imports UserDefaults symbols"),
            "a network import": (dict(widget_call="NSURLSessionProbe"), "imports network symbols"),
            "an iOS 18 symbol bound strongly": (dict(widget_call="ControlWidgetProbe"), "binds a post-iOS-17 symbol strongly"),
            "only the extension's dSYM": (dict(app_dsym=False), "no Soundpost.app.dSYM"),
            "the extension missing": (dict(with_widget=False), "SoundpostWidgetExtension: no executable"),
        }
        for name, (kwargs, message) in cases.items():
            with self.subTest(name):
                r = self.verify(self.archive(**kwargs))
                self.assertNotEqual(r.returncode, 0, f"{name} passed")
                self.assertIn(message, r.stderr)


if __name__ == "__main__":
    unittest.main()
