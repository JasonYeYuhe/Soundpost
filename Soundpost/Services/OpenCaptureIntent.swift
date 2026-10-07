import AppIntents

/// "New capsule" from Siri, Spotlight, Shortcuts and the Action Button (M20 §4F).
///
/// It opens the app on the capture screen, **idle**: it never starts a recording, and
/// it exposes no capsule content — no entity, no Spotlight items. Starting a recording
/// straight from an intent is a decision the plan leaves to Jason (§8 D2).
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "New capsule"
    static let description = IntentDescription("Opens Soundpost ready to record. Recording starts only when you tap.")

    /// **Both mode declarations, with no `#if`.** iOS 17–25 read only `openAppWhenRun`;
    /// iOS 26 introduced `supportedModes` and deprecated `openAppWhenRun` in its favour.
    /// A deprecation is reported only when the deployment target is at or above the
    /// version it happened in, so at iOS 17.0 neither declaration warns under Xcode 26.6
    /// or 27 — the way `CLGeocoder` already compiles clean in `LocationProvider`. Gating
    /// either on `#if compiler` would have CI build a different intent from the one
    /// that ships.
    static let openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequests.request()
        return .result()
    }
}

/// The phrases Siri and Spotlight offer for `OpenCaptureIntent`, translated in
/// `AppShortcuts.xcstrings`.
struct SoundpostShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCaptureIntent(),
            phrases: [
                "New capsule in \(.applicationName)",
                "Record a sound in \(.applicationName)",
                "Capture a sound with \(.applicationName)",
            ],
            shortTitle: "New capsule",
            systemImageName: "waveform"
        )
    }
}
