import Foundation

/// What to do about a request to open capture that came from outside the app's own
/// doors — Siri, Shortcuts, the Action Button, the Home Screen quick action (M20 §4F).
///
/// Pure, and modelled on `CapsuleOpenRoute.PendingLink`, because it has the same
/// enemy: a request set before there is anything to present it on. A notification tap
/// that launched the app used to be dropped for exactly that reason, so a request here
/// is kept until it can be honoured and is only ever *drained* by the gallery, after
/// the gallery exists.
///
/// **It opens capture idle.** Nothing on this path records; the person taps record,
/// and the nearby-voices notice is on that idle screen.
enum CaptureLaunchRoute: Equatable {
    /// Open capture now, and consume the request.
    case present
    /// Capture is already on screen: consume the request and open nothing on top of it.
    case alreadyOpen
    /// Keep the request: onboarding is not finished, the gallery is not there yet, or a
    /// reveal or another sheet is on screen and must not be covered.
    case wait
    /// Nothing is requested.
    case none

    /// The parts of the screen the decision depends on.
    struct Screen: Equatable {
        var onboardingComplete: Bool
        var galleryReady: Bool
        var captureShowing = false
        var revealShowing = false
        var otherSheetShowing = false
    }

    static func decide(requested: Bool, on screen: Screen) -> CaptureLaunchRoute {
        guard requested else { return .none }
        // Never past unfinished onboarding: the first thing a new person sees is the
        // explanation, not a microphone.
        guard screen.onboardingComplete, screen.galleryReady else { return .wait }
        if screen.captureShowing { return .alreadyOpen }
        if screen.revealShowing || screen.otherSheetShowing { return .wait }
        return .present
    }
}

/// The one hook the doors outside the view tree use to ask for capture: the App Intent
/// and the scene delegate's quick action. Installed once at app init, so it exists
/// before any scene connects or any intent runs, and it only ever *sets* the request
/// on the owner of `pendingDeepLinkCapsuleID` — which is what lets "the newest request
/// wins" need no clock.
@MainActor
enum CaptureRequests {
    static weak var coordinator: NotificationCoordinator?

    static func request() {
        coordinator?.requestCapture()
    }
}

/// The Home Screen quick action. The type is also declared in `Soundpost-Info.plist`;
/// `CaptureLaunchTests` holds the two equal.
enum QuickAction {
    static let newCapsuleType = "com.soundpost.Soundpost.newCapsule"
}
