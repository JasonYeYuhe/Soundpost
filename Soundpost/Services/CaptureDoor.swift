import AppIntents
import Foundation

// The capture door, in the one file the widget extension also compiles (M22 §4C).
//
// Everything outside the gallery that opens capture — the App Shortcut, the quick
// action, and from M22 a Home Screen / Lock Screen widget and a Control Center control —
// does exactly one thing: it sets the capture request through `CaptureRequests`. The
// gallery then decides with `CaptureLaunchRoute` whether and when to show capture, and
// capture always opens idle. Nothing here records, and nothing here can.
//
// **This file is compiled into the extension too.** So it imports only AppIntents and
// Foundation, names nothing that lives only in the app, and has no `#if` (the extension
// must run the same code the app does). In the extension the hook below is never set, so
// a request made there does nothing; the extension has no capture code at all.

/// What the doors ask to open capture. The app's `NotificationCoordinator` is the one
/// implementation; a protocol, so this file can be compiled where the coordinator isn't.
@MainActor
protocol CaptureRequestHandling: AnyObject {
    func requestCapture()
}

/// The one hook the doors outside the view tree use to ask for capture. Installed once at
/// app init, so it exists before any scene connects or any intent runs, and it only ever
/// *sets* the request on the owner of `pendingDeepLinkCapsuleID` — which is what lets
/// "the newest request wins" need no clock.
@MainActor
enum CaptureRequests {
    static weak var coordinator: (any CaptureRequestHandling)?

    static func request() {
        coordinator?.requestCapture()
    }
}

/// The widget's way in: a fixed URL, opened in the app by `widgetURL` (M22 §4C).
enum CaptureDoor {
    static let newCapsuleURL = URL(string: "soundpost://new-capsule")!

    /// Exactly the widget's URL, and nothing that merely starts like it: no query (a
    /// `?record=1` must not mean anything), no fragment, no user, no port, no path.
    static func opensCapture(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "soundpost" && parts.host == "new-capsule" && parts.path.isEmpty
            && parts.query == nil && parts.fragment == nil
            && parts.user == nil && parts.password == nil && parts.port == nil
    }

    /// Sets the capture request when `url` is the widget's, and does nothing otherwise.
    @MainActor
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard opensCapture(url) else { return false }
        CaptureRequests.request()
        return true
    }
}

/// Where the Control Center control opens. One case: an `OpenIntent` must name a target.
enum CaptureDestination: String, AppEnum {
    case newCapsule

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capsule"
    static let caseDisplayRepresentations: [CaptureDestination: DisplayRepresentation] = [.newCapsule: "New capsule"]
}

/// The Control Center control's action (iOS 18+, M22 §4D): opens the app on capture,
/// **idle**, through the same request as every other door.
///
/// An `OpenIntent`, compiled into both the app and the extension, because that is how
/// Apple documents a control that opens its app. It is **not** `OpenCaptureIntent`: that
/// intent (the App Shortcut, Siri, Spotlight, the Action Button) stays app-only and
/// unchanged, because the iOS 27 SDK says an intent with `openAppWhenRun` raises an error
/// if it runs in an extension, and iOS 27 may run an intent in any target that has it —
/// sharing it would have given the shipped door a second, failing home (M22 §1.11).
/// Hidden from Shortcuts, so "New capsule" is listed once.
struct NewCapsuleControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "New capsule"
    static let description = IntentDescription("Opens Soundpost ready to record. Recording starts only when you tap.")
    static let isDiscoverable = false

    /// Both mode declarations, with no `#if`, as in `OpenCaptureIntent`: iOS 17–25 read
    /// `openAppWhenRun`, iOS 26 and later read `supportedModes`.
    static let openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground

    /// Only in the app (W7, M23 §4C.6). iOS 27 may run an intent in any target that
    /// contains it, and this one is compiled into the widget extension too, where
    /// `CaptureRequests.coordinator` is nil: run there, a warm tap would open the app on the
    /// gallery with no capture request. iOS 17–26 never read it. No `#if`: every CI job
    /// builds with the iOS 27 SDK since D23.
    @available(iOS 27.0, *)
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Capsule")
    var target: CaptureDestination

    init() {
        target = .newCapsule
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequests.request()
        return .result()
    }
}
