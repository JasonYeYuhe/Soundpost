import Foundation
import Testing
@testable import Soundpost

/// The capture doors outside the app — the App Shortcut and the Home Screen quick
/// action — and the one route they share (M20 §4F).
@MainActor
@Suite("Capture from outside the app")
struct CaptureLaunchTests {
    private typealias Screen = CaptureLaunchRoute.Screen
    private let ready = Screen(onboardingComplete: true, galleryReady: true)

    // MARK: The route, table-driven

    @Test func theRouteDecidesFromTheScreen() {
        let cases: [(String, Bool, Screen, CaptureLaunchRoute)] = [
            ("nothing asked", false, ready, .none),
            ("the gallery is up", true, ready, .present),
            ("onboarding unfinished", true, Screen(onboardingComplete: false, galleryReady: true), .wait),
            ("no gallery yet (cold launch)", true, Screen(onboardingComplete: true, galleryReady: false), .wait),
            ("capture already open", true, Screen(onboardingComplete: true, galleryReady: true, captureShowing: true), .alreadyOpen),
            ("a reveal on screen", true, Screen(onboardingComplete: true, galleryReady: true, revealShowing: true), .wait),
            ("settings on screen", true, Screen(onboardingComplete: true, galleryReady: true, otherSheetShowing: true), .wait),
            // M20 release review: a capsule's own sheet or alert, which the gallery
            // cannot see. Presenting over it left "+" dead on iOS 17–25.
            ("a capsule's own sheet on screen", true,
             Screen(onboardingComplete: true, galleryReady: true, unownedPresentationShowing: true), .declined),
            // The gallery's own flags decide first: capture open is still "already
            // open", and Settings or a reveal still keep the request for their dismissal.
            ("capture open (also a presentation)", true,
             Screen(onboardingComplete: true, galleryReady: true, captureShowing: true, unownedPresentationShowing: true), .alreadyOpen),
            ("settings open (also a presentation)", true,
             Screen(onboardingComplete: true, galleryReady: true, otherSheetShowing: true, unownedPresentationShowing: true), .wait),
            ("a reveal open (also a presentation)", true,
             Screen(onboardingComplete: true, galleryReady: true, revealShowing: true, unownedPresentationShowing: true), .wait),
            ("onboarding, with something presented", true,
             Screen(onboardingComplete: false, galleryReady: true, unownedPresentationShowing: true), .wait),
        ]
        for (name, requested, screen, expected) in cases {
            #expect(CaptureLaunchRoute.decide(requested: requested, on: screen) == expected, "\(name)")
        }
    }

    // MARK: Newest request wins

    /// (1) A link waits for a capsule that has not imported yet; then a capture request
    /// arrives. The link is dropped, capture presents, and the capsule importing later
    /// opens nothing over the person's capture.
    @Test func aCaptureRequestDropsAWaitingLink() {
        let coordinator = NotificationCoordinator()
        let late = UUID()
        coordinator.openFromNotification(late)
        #expect(CapsuleOpenRoute.pendingLink(coordinator.pendingDeepLinkCapsuleID, among: []) == .wait)

        coordinator.requestCapture()

        #expect(coordinator.pendingDeepLinkCapsuleID == nil)
        #expect(CaptureLaunchRoute.decide(requested: coordinator.pendingCaptureRequest, on: ready) == .present)
        #expect(CapsuleOpenRoute.pendingLink(coordinator.pendingDeepLinkCapsuleID, among: [late]) == .none,
                "the capsule arrived and was opened over the capture the person asked for")
    }

    /// (2) A capture request waits behind unfinished onboarding; then a notification is
    /// tapped. The request is dropped, and the link opens once the gallery exists.
    @Test func aNotificationTapDropsAWaitingCaptureRequest() {
        let coordinator = NotificationCoordinator()
        coordinator.requestCapture()
        let onboarding = Screen(onboardingComplete: false, galleryReady: false)
        #expect(CaptureLaunchRoute.decide(requested: coordinator.pendingCaptureRequest, on: onboarding) == .wait)

        let tapped = UUID()
        coordinator.openFromNotification(tapped)

        #expect(!coordinator.pendingCaptureRequest)
        #expect(CaptureLaunchRoute.decide(requested: coordinator.pendingCaptureRequest, on: ready) == .none)
        #expect(CapsuleOpenRoute.pendingLink(coordinator.pendingDeepLinkCapsuleID, among: [tapped]) == .open(tapped))
    }

    @Test func theHookReachesTheCoordinatorAndConsumingClearsIt() {
        let coordinator = NotificationCoordinator()
        let previous = CaptureRequests.coordinator
        defer { CaptureRequests.coordinator = previous }
        CaptureRequests.coordinator = coordinator

        CaptureRequests.request()
        #expect(coordinator.pendingCaptureRequest)
        coordinator.consumeCaptureRequest()
        #expect(!coordinator.pendingCaptureRequest)
    }

    // MARK: The doors, read from source — there is no UI-test target

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(path) has moved; this guard checks nothing")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// iOS 17–25 read only `openAppWhenRun`; iOS 26 reads `supportedModes`. Dropping
    /// either leaves one range of systems running the intent without opening the app.
    @Test func theIntentOpensTheAppOnEverySupportedSystemAndNeverRecords() throws {
        let intent = try Self.code("Soundpost/Services/OpenCaptureIntent.swift")
        #expect(intent.contains("static let openAppWhenRun: Bool = true"))
        #expect(intent.contains("@available(iOS 26.0, *)\n    static let supportedModes: IntentModes = .foreground"))
        #expect(!intent.contains("#if"), "the intent must be the same on every compiler")
        #expect(intent.contains("CaptureRequests.request()"))
        #expect(!intent.contains("startRecording"), "an intent opens capture idle; it never records")
        #expect(OpenCaptureIntent.openAppWhenRun)
    }

    /// The black-screen risk of a supplied scene delegate is a delegate that makes its own
    /// window. This one handles the two quick-action entry points and nothing else.
    @Test func theSceneDelegateMakesNoWindowAndAnswersTheSystem() throws {
        let scene = try Self.code("Soundpost/SoundpostSceneDelegate.swift")
        #expect(!scene.contains("UIWindow("), "the scene delegate creates a window")
        #expect(!scene.contains("var window"), "the scene delegate holds a window")
        #expect(scene.contains("connectionOptions.shortcutItem"), "the cold launch is not handled")
        #expect(scene.contains("completionHandler(handle(shortcutItem))"), "the warm launch does not answer")
        let delegate = try Self.code("Soundpost/Services/Delivery/SoundpostAppDelegate.swift")
        #expect(delegate.contains("configuration.delegateClass = SoundpostSceneDelegate.self"))
    }

    /// The type the scene delegate matches is the one Info.plist declares.
    @Test func theQuickActionInInfoPlistIsTheOneTheAppHandles() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost-Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url))
        let items = try #require(plist["UIApplicationShortcutItems"] as? [[String: Any]])
        #expect(items.map { $0["UIApplicationShortcutItemType"] as? String } == [QuickAction.newCapsuleType])
        #expect(items.first?["UIApplicationShortcutItemTitle"] as? String == "New capsule")
    }

    /// A real notification tap goes through the rule, not around it.
    @Test func aNotificationTapGoesThroughTheNewestWinsRule() throws {
        let coordinator = try Self.code("Soundpost/Services/NotificationCoordinator.swift")
        #expect(coordinator.contains("await MainActor.run { self.openFromNotification(uuid) }"))
        #expect(!coordinator.contains("self.pendingDeepLinkCapsuleID = uuid"),
                "the tap sets the link directly and leaves a capture request standing")
    }

    /// The gallery asks UIKit what is on screen, and a declined request is consumed
    /// without touching `showingCapture` — the flag nothing else would ever reset.
    @Test func theGalleryAsksUIKitAndADeclinedRequestOpensNothing() throws {
        let gallery = try Self.code("Soundpost/ContentView.swift")
        let drain = try #require(gallery.range(of: "private func drainCaptureRequest() {"))
        let end = try #require(gallery.range(of: "\n    }\n", range: drain.upperBound..<gallery.endIndex))
        let body = gallery[drain.upperBound..<end.lowerBound]
        #expect(body.contains("unownedPresentationShowing: Self.somethingIsPresented()"),
                "the route cannot see a capsule's own sheets without asking UIKit")
        let declined = try #require(body.range(of: "case .alreadyOpen, .declined:"),
                                    "a declined request must be consumed, and only consumed")
        let nextArm = body.range(of: "case .", range: declined.upperBound..<body.endIndex)?.lowerBound ?? body.endIndex
        let declinedArm = body[declined.upperBound..<nextArm]
        #expect(declinedArm.contains("notifications.consumeCaptureRequest()"))
        #expect(!declinedArm.contains("showingCapture"))
    }

    /// The gallery drains the request after it exists, and any door into capture drops a
    /// waiting link.
    @Test func theGalleryDrainsAfterItExistsAndCaptureDropsAWaitingLink() throws {
        let gallery = try Self.code("Soundpost/ContentView.swift")
        let refresh = try #require(gallery.range(of: "private func refreshAndSync() async {"))
        let refreshEnd = try #require(gallery.range(of: "\n    }\n", range: refresh.upperBound..<gallery.endIndex))
        let refreshBody = gallery[refresh.upperBound..<refreshEnd.lowerBound]
        let drain = try #require(refreshBody.range(of: "drainCaptureRequest()"),
                                 "a cold launch's request, set before any body existed, would be lost")
        let firstAwait = try #require(refreshBody.range(of: "await "))
        #expect(drain.lowerBound < firstAwait.lowerBound,
                "the cold-launch request waits behind CloudKit and the delivery server")
        // The person's own navigation supersedes a waiting request, as it does a link.
        let open = try #require(gallery.range(of: "private func openCapsule(_ capsule: Capsule) {"))
        #expect(gallery[open.upperBound...].prefix(300).contains("notifications.consumeCaptureRequest()"))
        // No rating prompt over a capture that a closing reveal released.
        let review = try #require(gallery.range(of: "private func requestReviewIfEarned() {"))
        let reviewBody = gallery[review.upperBound...].prefix(700)
        #expect(reviewBody.contains("guard earned, !showingCapture else { return }"))
        let onCapture = try #require(gallery.range(of: ".onChange(of: showingCapture) { _, presented in"))
        let block = gallery[onCapture.upperBound...].prefix(700)
        #expect(block.contains("notifications.pendingDeepLinkCapsuleID = nil"))
        #expect(block.contains("notifications.consumeCaptureRequest()"),
                "a capture opened by \"+\" leaves the request to open a second one later")
        #expect(gallery.contains("onboardingComplete: hasCompletedOnboarding"))
    }
}
