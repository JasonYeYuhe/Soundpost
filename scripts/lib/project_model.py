#!/usr/bin/env python3
"""What the Xcode project says it builds — read from the project file, for every gate (M22 §4B.1).

Before M22 each gate named its own folders (`Soundpost/**`) and its own binary
(`Soundpost.app/Soundpost`). A second target would have been invisible to all of them —
a gate that iterates what it was told about cannot fail for what it was not told about
(M15 §11P). So the gates now ask the project, and this module is the one place that
reads it.

**Parsed by `plutil`, never by regex.** `project.pbxproj` is an old-style (OpenStep)
property list; `plutil -convert json` reads it exactly as Xcode does, so a field order
Xcode chooses (it writes `exceptions = (…)` between `isa` and `path` once an exception
set exists) cannot make a root disappear.

**Membership exceptions** (`PBXFileSystemSynchronizedBuildFileExceptionSet`) mean
"excluded from this target" for a target that lists the folder in its
`fileSystemSynchronizedGroups`, and "added to this target" for a target that does not.
Any other exception class is refused rather than guessed at.

Usage:
  scripts/lib/project_model.py [--project DIR]           JSON for every target
  scripts/lib/project_model.py roots [--kinds app,appex]  one root folder per line
  scripts/lib/project_model.py executables                 '<target>\\t<path inside the .app>'

Exits 1, naming the problem, when the project is not what the gates can trust: no
application target, a root that does not exist or (for an app or extension) holds no
Swift file, an added file that does not exist, an exception class it does not know.
"""
import json
import os
import subprocess
import sys

KINDS = {
    "com.apple.product-type.application": "app",
    "com.apple.product-type.app-extension": "appex",
    "com.apple.product-type.bundle.unit-test": "test",
    "com.apple.product-type.bundle.ui-testing": "test",
}
KNOWN_EXCEPTION_SETS = {"PBXFileSystemSynchronizedBuildFileExceptionSet"}


class ProjectError(Exception):
    pass


def _pbxproj(project_dir):
    found = [n for n in sorted(os.listdir(project_dir)) if n.endswith(".xcodeproj")]
    if len(found) != 1:
        raise ProjectError(f"expected one .xcodeproj in {project_dir}, found {found}")
    return os.path.join(project_dir, found[0], "project.pbxproj")


def _read(pbxproj):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", pbxproj],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise ProjectError(f"plutil could not read {pbxproj}: {out.stderr.strip()}")
    return json.loads(out.stdout)


def _settings(objects, list_id):
    return {objects[c]["name"]: objects[c].get("buildSettings", {})
            for c in objects[list_id]["buildConfigurations"]}


def load(project_dir):
    """The project's targets, roots, membership exceptions and settings, validated."""
    data = _read(_pbxproj(project_dir))
    objects = data["objects"]
    project = objects[data["rootObject"]]

    roots = {}  # group id -> {"path": ..., "exceptions": [(target id, [relative paths])]}
    for oid, obj in objects.items():
        if obj.get("isa") != "PBXFileSystemSynchronizedRootGroup":
            continue
        exceptions = []
        for eid in obj.get("exceptions", []):
            exc = objects[eid]
            if exc.get("isa") not in KNOWN_EXCEPTION_SETS:
                raise ProjectError(f"root '{obj.get('path')}' has an exception set of class "
                                   f"{exc.get('isa')}, which the gates do not understand")
            exceptions.append((exc.get("target"), list(exc.get("membershipExceptions", []))))
        roots[oid] = {"path": obj["path"], "exceptions": exceptions}

    targets = []
    for tid in project["targets"]:
        t = objects[tid]
        product = objects[t["productReference"]]["path"] if t.get("productReference") else None
        own = [roots[g]["path"] for g in t.get("fileSystemSynchronizedGroups", [])]
        added, excluded = [], []
        for gid, root in roots.items():
            for target_id, paths in root["exceptions"]:
                if target_id != tid:
                    continue
                full = [os.path.join(root["path"], p) for p in paths]
                (excluded if root["path"] in own else added).extend(full)
        kind = KINDS.get(t.get("productType"), "other")
        executable = None
        if product and kind == "app":
            executable = f"{os.path.splitext(product)[0]}"
        elif product and kind == "appex":
            executable = f"PlugIns/{product}/{os.path.splitext(product)[0]}"
        targets.append({
            "name": t["name"],
            "productType": t.get("productType"),
            "kind": kind,
            "product": product,
            "executable": executable,  # relative to the .app bundle
            "roots": own,
            "added": sorted(added),
            "excluded": sorted(excluded),
            "packages": len(t.get("packageProductDependencies", [])),
            "settings": _settings(objects, t["buildConfigurationList"]),
        })

    model = {"targets": targets,
             "projectSettings": _settings(objects, project["buildConfigurationList"])}
    _validate(project_dir, model)
    return model


def _has_swift(folder):
    for _, _, files in os.walk(folder):
        if any(f.endswith(".swift") for f in files):
            return True
    return False


def _validate(project_dir, model):
    if not any(t["kind"] == "app" for t in model["targets"]):
        raise ProjectError("the project has no application target")
    for t in model["targets"]:
        for root in t["roots"]:
            folder = os.path.join(project_dir, root)
            if not os.path.isdir(folder):
                raise ProjectError(f"target {t['name']}: root '{root}' does not exist")
            if t["kind"] in ("app", "appex", "test") and not _has_swift(folder):
                raise ProjectError(f"target {t['name']}: root '{root}' holds no Swift file")
        for path in t["added"]:
            if not os.path.exists(os.path.join(project_dir, path)):
                raise ProjectError(f"target {t['name']}: added file '{path}' does not exist")


def shipping(model):
    """The targets whose code ships: the app and its extensions."""
    return [t for t in model["targets"] if t["kind"] in ("app", "appex")]


def main(argv):
    project_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    args = list(argv)
    if "--project" in args:
        i = args.index("--project")
        project_dir = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    try:
        model = load(project_dir)
    except ProjectError as e:
        print(f"✗ project model: {e}", file=sys.stderr)
        return 1
    command = args[0] if args else "json"
    if command == "json":
        print(json.dumps(model, indent=2, sort_keys=True))
    elif command == "roots":
        kinds = {"app", "appex"}
        if "--kinds" in args:
            kinds = set(args[args.index("--kinds") + 1].split(","))
        seen = []
        for t in model["targets"]:
            if t["kind"] in kinds:
                for r in t["roots"]:
                    if r not in seen:
                        seen.append(r)
        print("\n".join(seen))
    elif command == "executables":
        for t in shipping(model):
            print(f"{t['name']}\t{t['executable']}")
    else:
        print(f"unknown command {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
