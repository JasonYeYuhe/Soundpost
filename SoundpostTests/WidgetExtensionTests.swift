import Foundation
import Testing

/// The widget extension, held from its source and the project file (M22 §4D).
///
/// The extension cannot be imported into this test bundle — its host is the app — so what
/// it is allowed to be is pinned here instead: which files it holds, what it imports, what
/// it may never name, how it opens the app, that its control is iOS 18 only, that its kinds
/// never change, that its strings match the app's, and that the project builds it with no
/// entitlement, no package, no version of its own and the app's deployment target.
/// Every scan first proves it found what it scans, so an empty folder fails (M15 §11P).
struct WidgetExtensionTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let folder = "SoundpostWidget"
    private static let sources = ["LauncherWidget.swift", "NewCapsuleControl.swift", "SoundpostWidgets.swift"]
    private static let widgetKind = "com.soundpost.Soundpost.widget.newCapsule"
    private static let controlKind = "com.soundpost.Soundpost.control.newCapsule"

    private static func text(_ path: String) throws -> String {
        let url = repo.appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(path) is missing; this guard checks nothing")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code without comment lines, so a doc comment may explain what the code must not do.
    private static func code(_ path: String) throws -> String {
        try text(path).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func extensionCode() throws -> [(String, String)] {
        try sources.map { ("\(folder)/\($0)", try code("\(folder)/\($0)")) }
    }

    // MARK: Source

    /// Exactly these files: a new one is a new decision, made here on purpose.
    @Test func theExtensionHoldsExactlyItsFiles() throws {
        let found = try FileManager.default.contentsOfDirectory(atPath: Self.repo.appending(path: Self.folder).path)
            .filter { !$0.hasPrefix(".") }.sorted()
        #expect(found == (Self.sources + ["Localizable.xcstrings"]).sorted(), "\(found)")
    }

    @Test func itImportsOnlyTheWidgetFrameworks() throws {
        for (path, code) in try Self.extensionCode() {
            let imports = Set(code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") })
            #expect(!imports.isEmpty, "\(path) imports nothing; the scan read the wrong file")
            #expect(imports.isSubset(of: ["import SwiftUI", "import WidgetKit", "import AppIntents"]), "\(path): \(imports)")
        }
    }

    /// No capture code, no Pro, no store, and no API that would need a privacy manifest
    /// the extension does not have — in its own files and in the shared one.
    @Test func itNamesNothingItMustNot() throws {
        let forbidden = [#"CaptureRequests"#, #"NotificationCoordinator"#, #"startRecording"#, #"\bPro\b"#,
                         #"\bPro[A-Z]\w*"#, #"StoreKit"#, #"StoreService"#, #"UserDefaults"#, #"@AppStorage"#,
                         #"URLSession"#, #"FileManager"#, #"systemUptime"#, #"mach_absolute_time"#,
                         #"OpenCaptureIntent"#]
        for (path, code) in try Self.extensionCode() {
            for pattern in forbidden {
                #expect(code.range(of: pattern, options: .regularExpression) == nil, "\(path) names \(pattern)")
            }
        }
        let shared = try Self.code("Soundpost/Services/CaptureDoor.swift")
        for pattern in [#"UserDefaults"#, #"@AppStorage"#, #"URLSession"#, #"FileManager"#, #"systemUptime"#,
                        #"mach_absolute_time"#] {
            #expect(shared.range(of: pattern, options: .regularExpression) == nil, "the shared file names \(pattern)")
        }
    }

    /// The whole widget is the door, and only through the app's URL handler: no button
    /// that runs an intent in the extension, no second link.
    @Test func theWholeWidgetOpensTheAppThroughTheDoor() throws {
        let all = try Self.extensionCode().map(\.1).joined(separator: "\n")
        #expect(all.components(separatedBy: ".widgetURL(CaptureDoor.newCapsuleURL)").count == 2,
                "the launcher must set the door's URL exactly once")
        #expect(!all.contains("Button(intent:"))
        #expect(!all.contains("Link("))
        #expect(!all.contains(".widgetURL(URL("), "a URL other than the door's")
    }

    /// The control is iOS 18 only; the extension's deployment target is 17.0.
    @Test func theControlIsBehindIOS18AndOpensThroughTheControlIntent() throws {
        let bundle = try Self.code("\(Self.folder)/SoundpostWidgets.swift")
        #expect(bundle.contains("if #available(iOS 18.0, *) {\n            NewCapsuleControl()\n        }"))
        #expect(bundle.components(separatedBy: "NewCapsuleControl()").count == 2, "the control outside its guard")
        let control = try Self.code("\(Self.folder)/NewCapsuleControl.swift")
        #expect(control.contains("@available(iOS 18.0, *)\nstruct NewCapsuleControl: ControlWidget"))
        #expect(control.contains("ControlWidgetButton(action: NewCapsuleControlIntent())"))
    }

    /// A placed widget or control is bound to its kind; a new kind deletes it from the
    /// person's Home Screen or Control Center. The debug-only gate's premise for the
    /// extension's binary is the widget kind, so it must stay the same string too.
    @Test func theKindsNeverChange() throws {
        #expect(try Self.code("\(Self.folder)/LauncherWidget.swift").contains("static let kind = \"\(Self.widgetKind)\""))
        #expect(try Self.code("\(Self.folder)/NewCapsuleControl.swift").contains("static let kind = \"\(Self.controlKind)\""))
        #expect(try Self.text("scripts/check-debug-only.sh").contains("SoundpostWidgetExtension) printf '%s' \"\(Self.widgetKind)\""))
    }

    @Test func theLauncherOffersTheThreeFamiliesAndNoContent() throws {
        let launcher = try Self.code("\(Self.folder)/LauncherWidget.swift")
        #expect(launcher.contains(".supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])"))
        #expect(launcher.contains("policy: .never"), "a launcher has nothing to refresh")
        #expect(launcher.contains(".containerBackground("), "iOS 17 shows a placeholder without one")
    }

    // MARK: Strings — the extension looks them up in its own bundle

    private static func catalog(_ path: String) throws -> [String: [String: String]] {
        let data = try Data(contentsOf: repo.appending(path: path))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        return strings.mapValues { entry in
            let locs = entry["localizations"] as? [String: [String: [String: String]]] ?? [:]
            return locs.compactMapValues { $0["stringUnit"]?["value"] }
        }
    }

    /// Every key the extension shares with the app is translated exactly as the app
    /// translates it: one product, one voice. The one new key is the widget's description.
    @Test func theExtensionsStringsAreTheApps() throws {
        let app = try Self.catalog("Soundpost/Localizable.xcstrings")
        let ext = try Self.catalog("\(Self.folder)/Localizable.xcstrings")
        let new = "Opens Soundpost ready to record. Nothing records until you tap the record button."
        #expect(Set(ext.keys) == ["Capsule", "New capsule", new,
                                  "Opens Soundpost ready to record. Recording starts only when you tap."])
        for (key, translations) in ext where key != new {
            #expect(translations == app[key], "\(key) is translated differently in the extension")
        }
        #expect(Set(ext[new]?.keys ?? [:].keys) == ["ja", "zh-Hans"])
    }

    // MARK: The project

    private static func project() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: repo.appending(path: "Soundpost.xcodeproj/project.pbxproj"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(plist["objects"] as? [String: [String: Any]])
    }

    private static func target(_ name: String, in objects: [String: [String: Any]]) throws -> (String, [String: Any]) {
        let match = objects.first { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == name }
        let found = try #require(match, "no target \(name)")
        return (found.key, found.value)
    }

    private static func settings(_ target: [String: Any], in objects: [String: [String: Any]]) throws -> [[String: Any]] {
        let list = try #require(objects[target["buildConfigurationList"] as? String ?? ""])
        return (list["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0]?["buildSettings"] as? [String: Any] }
    }

    @Test func theProjectBuildsTheExtensionWithNothingExtra() throws {
        let objects = try Self.project()
        let (id, ext) = try Self.target("SoundpostWidgetExtension", in: objects)
        #expect(ext["productType"] as? String == "com.apple.product-type.app-extension")
        let roots = (ext["fileSystemSynchronizedGroups"] as? [String] ?? []).compactMap { objects[$0]?["path"] as? String }
        #expect(roots == [Self.folder], "the extension owns one folder and no other: \(roots)")
        #expect((ext["packageProductDependencies"] as? [String] ?? []).isEmpty, "the extension links a package")

        // Exactly one file of the app's, added by one membership exception.
        var added: [String] = []
        for group in objects.values where group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            for exception in (group["exceptions"] as? [String] ?? []).compactMap({ objects[$0] })
            where exception["target"] as? String == id {
                added += (exception["membershipExceptions"] as? [String] ?? []).map { "\(group["path"] ?? "")/\($0)" }
            }
        }
        #expect(added == ["Soundpost/Services/CaptureDoor.swift"], "\(added)")

        let configs = try Self.settings(ext, in: objects)
        #expect(configs.count == 2)
        for s in configs {
            #expect(s["CODE_SIGN_ENTITLEMENTS"] == nil, "the extension has an entitlement")
            #expect(s["MARKETING_VERSION"] == nil && s["CURRENT_PROJECT_VERSION"] == nil, "a version of its own")
            #expect(s["IPHONEOS_DEPLOYMENT_TARGET"] as? String == "17.0")
            #expect(s["APPLICATION_EXTENSION_API_ONLY"] as? String == "YES")
            #expect(s["SKIP_INSTALL"] as? String == "YES", "the archive would not be an app archive")
            #expect(s["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "com.soundpost.Soundpost.Widgets")
            #expect(s["INFOPLIST_FILE"] as? String == "SoundpostWidget-Info.plist")
            #expect(s["SWIFT_VERSION"] as? String == "5.0")
            for key in s.keys where key.hasPrefix("SWIFT_DEFAULT_ACTOR_ISOLATION") || key.hasPrefix("SWIFT_APPROACHABLE") {
                Issue.record("a template concurrency setting: \(key)")
            }
        }
    }

    /// The app embeds the extension and builds it first.
    @Test func theAppEmbedsTheExtension() throws {
        let objects = try Self.project()
        let (extID, ext) = try Self.target("SoundpostWidgetExtension", in: objects)
        let (_, app) = try Self.target("Soundpost", in: objects)
        let product = try #require(ext["productReference"] as? String)
        let phases = (app["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
        let embed = try #require(phases.first { $0["isa"] as? String == "PBXCopyFilesBuildPhase" }, "nothing embeds it")
        #expect(embed["dstSubfolderSpec"] as? String == "13", "not copied into PlugIns")
        let refs = (embed["files"] as? [String] ?? []).compactMap { objects[$0]?["fileRef"] as? String }
        #expect(refs == [product])
        let deps = (app["dependencies"] as? [String] ?? []).compactMap { objects[$0]?["target"] as? String }
        #expect(deps.contains(extID))
    }

    /// No App Group, anywhere: the launcher reads no data (D10).
    @Test func noTargetHasAnAppGroup() throws {
        let entitlements = try FileManager.default.subpathsOfDirectory(atPath: Self.repo.path)
            .filter { $0.hasSuffix(".entitlements") && !$0.contains("/build/") && !$0.hasPrefix("build/") && !$0.hasPrefix(".") }
        #expect(entitlements == ["Soundpost/Soundpost.entitlements"], "\(entitlements)")
        #expect(!(try Self.text("Soundpost/Soundpost.entitlements")).contains("application-groups"))
    }

    @Test func theExtensionsInfoPlistIsAWidgetWithNoVersionOfItsOwn() throws {
        let plist = try #require(NSDictionary(contentsOf: Self.repo.appending(path: "SoundpostWidget-Info.plist")))
        let point = (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
        #expect(point == "com.apple.widgetkit-extension")
        #expect(plist["CFBundleShortVersionString"] == nil && plist["CFBundleVersion"] == nil)
        #expect(plist["UIBackgroundModes"] == nil)
    }
}
