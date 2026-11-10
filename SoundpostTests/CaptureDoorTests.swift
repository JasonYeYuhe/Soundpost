import CryptoKit
import Foundation
import Testing
@testable import Soundpost

/// The capture door the widget and the Control Center control share with every other
/// outside door (M22 §4C). The widget extension compiles `CaptureDoor.swift` and nothing
/// else of the app's, so these tests hold three things: the shared file can compile there,
/// every door only sets the one capture request, and nothing anywhere records or shows
/// capture around `CaptureLaunchRoute`.
@MainActor
@Suite("The capture door the widget and control share")
struct CaptureDoorTests {
    private typealias Screen = CaptureLaunchRoute.Screen
    private let ready = Screen(onboardingComplete: true, galleryReady: true)
    private let onboarding = Screen(onboardingComplete: false, galleryReady: true)

    /// Runs `body` with a fresh coordinator in the hook, restoring the previous one.
    private func withHook(_ body: (NotificationCoordinator) async throws -> Void) async rethrows {
        let coordinator = NotificationCoordinator()
        let previous = CaptureRequests.coordinator
        defer { CaptureRequests.coordinator = previous }
        CaptureRequests.coordinator = coordinator
        try await body(coordinator)
    }

    // MARK: Every door sets the request, and only the request

    @Test func theControlsIntentSetsTheRequestAndNothingElse() async throws {
        try await withHook { coordinator in
            coordinator.openFromNotification(UUID())   // a link waiting for its capsule
            _ = try await NewCapsuleControlIntent().perform()
            #expect(coordinator.pendingCaptureRequest)
            #expect(coordinator.pendingDeepLinkCapsuleID == nil, "the newest request did not win")
            #expect(CaptureLaunchRoute.decide(requested: coordinator.pendingCaptureRequest, on: onboarding) == .wait)
            #expect(CaptureLaunchRoute.decide(requested: coordinator.pendingCaptureRequest, on: ready) == .present)
        }
    }

    /// The App Shortcut's intent is untouched by M22 and still does exactly this.
    @Test func theShortcutsIntentStillSetsTheRequest() async throws {
        try await withHook { coordinator in
            _ = try await OpenCaptureIntent().perform()
            #expect(coordinator.pendingCaptureRequest)
        }
    }

    @Test func theControlsIntentOpensTheAppAndStaysOutOfShortcuts() {
        #expect(NewCapsuleControlIntent.openAppWhenRun)
        #expect(!NewCapsuleControlIntent.isDiscoverable, "Shortcuts would list \"New capsule\" twice")
        #expect(NewCapsuleControlIntent().target == .newCapsule)
        #expect(CaptureDestination.allCases == [.newCapsule])
    }

    /// With no coordinator installed — the extension's case — a request does nothing.
    @Test func withNoHookARequestDoesNothing() async throws {
        let previous = CaptureRequests.coordinator
        defer { CaptureRequests.coordinator = previous }
        CaptureRequests.coordinator = nil
        _ = try await NewCapsuleControlIntent().perform()
        #expect(CaptureDoor.open(CaptureDoor.newCapsuleURL), "the URL still matches; it just reaches no one")
    }

    // MARK: The widget's URL

    @Test func onlyTheWidgetsExactURLOpensCapture() {
        #expect(CaptureDoor.opensCapture(CaptureDoor.newCapsuleURL))
        let others = [
            "soundpost://new-capsule/", "soundpost://new-capsule/record", "soundpost://new-capsule?record=1",
            "soundpost://new-capsule#now", "soundpost://user@new-capsule", "soundpost://new-capsule:80",
            "soundpost://new-capsules", "soundpost://capsule", "SOUNDPOST-X://new-capsule",
            "https://new-capsule", "https://soundpost.app/new-capsule", "soundpost:new-capsule",
        ]
        for other in others {
            guard let url = URL(string: other) else {
                Issue.record("\(other) is not a URL; the table tests nothing for it")
                continue
            }
            #expect(!CaptureDoor.opensCapture(url), "\(other) opened capture")
        }
    }

    @Test func openingAURLSetsTheRequestOnlyWhenItIsTheWidgets() async {
        await withHook { coordinator in
            #expect(!CaptureDoor.open(URL(string: "soundpost://new-capsule?record=1")!))
            #expect(!coordinator.pendingCaptureRequest)
            #expect(CaptureDoor.open(CaptureDoor.newCapsuleURL))
            #expect(coordinator.pendingCaptureRequest)
        }
    }

    // MARK: Censuses over every target's code — read from the project, not assumed

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The folders of every app and app-extension target, read from the project file
    /// (an OpenStep plist, which `PropertyListSerialization` reads), plus files a
    /// membership exception adds to a target that does not own their folder.
    private static func shippingSources() throws -> [(path: String, code: String)] {
        let pbx = repo.appending(path: "Soundpost.xcodeproj/project.pbxproj")
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: pbx), format: nil) as? [String: Any])
        let objects = try #require(plist["objects"] as? [String: [String: Any]])
        var roots: [String] = []
        var added: [String] = []
        for (id, target) in objects where target["isa"] as? String == "PBXNativeTarget" {
            let type = target["productType"] as? String ?? ""
            guard type == "com.apple.product-type.application" || type == "com.apple.product-type.app-extension" else { continue }
            let own = (target["fileSystemSynchronizedGroups"] as? [String] ?? []).compactMap { objects[$0]?["path"] as? String }
            roots += own
            for group in objects.values where group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
                guard let path = group["path"] as? String, !own.contains(path) else { continue }
                for exception in (group["exceptions"] as? [String] ?? []).compactMap({ objects[$0] })
                where exception["target"] as? String == id {
                    added += (exception["membershipExceptions"] as? [String] ?? []).map { "\(path)/\($0)" }
                }
            }
        }
        try #require(roots.contains("Soundpost"), "the app's folder is not in the project's shipping roots")
        var files: [String] = []
        for root in Set(roots) {
            let base = repo.appending(path: root)
            let walker = try #require(FileManager.default.enumerator(atPath: base.path))
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                files.append("\(root)/\(relative)")
            }
        }
        files += added.filter { $0.hasSuffix(".swift") }
        try #require(files.count > 50, "the census read almost nothing; it checks nothing")
        return try Set(files).sorted().map { path in
            let text = try String(contentsOf: repo.appending(path: path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (path, code)
        }
    }

    /// Lines that call `name(` — not its declaration.
    private static func callSites(of name: String, in sources: [(path: String, code: String)]) -> [String] {
        sources.flatMap { file in
            file.code.split(separator: "\n").enumerated()
                .filter { $0.element.contains("\(name)(") && !$0.element.contains("func \(name)(") }
                .map { "\(file.path):\($0.offset + 1)" }
        }
    }

    /// Nothing outside capture's own record button starts a recording — so no door,
    /// old or new, can record (a widget or control that recorded would be this test).
    @Test func onlyTheRecordButtonStartsARecording() throws {
        let sites = Self.callSites(of: "startRecording", in: try Self.shippingSources())
        #expect(sites.count == 1, "\(sites)")
        #expect(sites.first?.hasPrefix("Soundpost/Capture/CaptureView.swift:") == true, "\(sites)")
    }

    /// Capture is shown only where it always was; a door that showed it directly would
    /// skip `CaptureLaunchRoute` and open over onboarding or a capsule's own sheet.
    @Test func captureIsShownOnlyAtItsFourKnownPlaces() throws {
        let sources = try Self.shippingSources()
        let sites = sources.flatMap { file in
            file.code.components(separatedBy: "showingCapture = true").dropFirst().map { _ in file.path }
        }
        #expect(sites == Array(repeating: "Soundpost/ContentView.swift", count: 4), "\(sites)")
    }

    /// Only the hook asks the coordinator for capture.
    @Test func onlyTheHookAsksForCapture() throws {
        let sites = Self.callSites(of: "requestCapture", in: try Self.shippingSources())
        #expect(sites.count == 1, "\(sites)")
        #expect(sites.first?.hasPrefix("Soundpost/Services/CaptureDoor.swift:") == true, "\(sites)")
    }

    /// No bundle may run in the background beyond receiving a push: a background mode
    /// such as `audio` is what recording "headless" would need.
    @Test func noBundleRunsInTheBackgroundBeyondPushes() throws {
        let app = try #require(NSDictionary(contentsOf: Self.repo.appending(path: "Soundpost-Info.plist")))
        #expect(app["UIBackgroundModes"] as? [String] == ["remote-notification"])
        let plists = try FileManager.default.contentsOfDirectory(atPath: Self.repo.path)
            .filter { $0.hasSuffix("-Info.plist") && $0 != "Soundpost-Info.plist" }
        for name in plists {
            let other = try #require(NSDictionary(contentsOf: Self.repo.appending(path: name)))
            #expect(other["UIBackgroundModes"] == nil, "\(name) declares background modes")
        }
        let project = try String(contentsOf: Self.repo.appending(path: "Soundpost.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(!project.contains("INFOPLIST_KEY_UIBackgroundModes"))
    }

    // MARK: The shared file, and the door that must not change

    private static func code(_ path: String) throws -> String {
        let url = repo.appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(path) has moved; this guard checks nothing")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The extension compiles this file; anything app-only in it breaks the extension or,
    /// worse, drags capture code into it.
    @Test func theSharedFileNamesNothingAppOnly() throws {
        let shared = try Self.code("Soundpost/Services/CaptureDoor.swift")
        let lines = shared.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let imports = Set(lines.filter { $0.hasPrefix("import ") })
        #expect(imports == ["import AppIntents", "import Foundation"], "\(imports)")
        let code = lines.filter { !$0.hasPrefix("//") }.joined(separator: "\n")
        for forbidden in ["#if", "AppShortcutsProvider", "startRecording", "NotificationCoordinator",
                          "UIApplication", "SwiftData", "UserDefaults", "Sentry"] {
            #expect(!code.contains(forbidden), "the shared file names \(forbidden)")
        }
    }

    /// `OpenCaptureIntent` — the shipped Siri / Shortcuts / Spotlight / Action Button door —
    /// stays app-only and byte-for-byte as 1.11.0 shipped it (M22 §1.11). Change it on
    /// purpose, and this hash with it.
    @Test func theShortcutsIntentIsUnchanged() throws {
        let data = try Data(contentsOf: Self.repo.appending(path: "Soundpost/Services/OpenCaptureIntent.swift"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "9f2950e8a957c21e51650aa8c1e4a09b3aa39d45b7e96bb144d05c2608328440")
    }

    /// The widget's URL reaches the door through `.onOpenURL`, outside the onboarding
    /// switch — so a tap during onboarding is kept, and the route makes it wait.
    @Test func theWidgetsURLReachesTheDoorOutsideOnboarding() throws {
        let app = try Self.code("Soundpost/SoundpostApp.swift")
        let production = try #require(app.range(of: "private var production: some View {"))
        let body = app[production.upperBound...].prefix(600)
        let switchUse = try #require(body.range(of: "mainOrOnboarding"))
        let handler = try #require(body.range(of: ".onOpenURL { CaptureDoor.open($0) }"),
                                   "the widget's URL has no handler")
        #expect(switchUse.upperBound < handler.lowerBound)
        #expect(!body[switchUse.upperBound..<handler.lowerBound].contains("}"),
                "the handler is not on the onboarding switch itself")
        #expect(app.components(separatedBy: ".onOpenURL").count == 2, "a second URL handler")
    }
}
