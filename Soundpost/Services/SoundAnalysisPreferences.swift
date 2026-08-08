import Foundation

/// Consent for **listening** — whether Soundpost may analyse recordings on this
/// device at all (M15 §4I).
///
/// This exists because reusing `NotificationPreferences.personalized` would have
/// been consent theatre (Codex F6). That switch governs what appears on a lock
/// screen; the analysis happens at capture time regardless of it. A user who wants
/// labelled search but no notifications — or the reverse — could not say so, and
/// turning notifications off would not have stopped a single classification.
///
/// So the two are layered, not conflated:
///   1. **this** switch decides whether we listen at all;
///   2. `NotificationPreferences.personalized` decides whether what we heard may
///      appear on a lock screen.
///
/// **Default: on.** Unlike personalized notifications — which put private words
/// somewhere other people can read them, and so are opt-in — classification creates
/// no new exposure: inference is on-device, and the label is stored with the capsule
/// it describes. Off by default would also mean almost nobody ever has it. The
/// setting says plainly what it does, and turning it off **deletes** what was
/// already heard rather than merely hiding it — a switch that only stops future
/// analysis while quietly keeping past results would be the dishonest version.
/// **This device's mirror of an account-wide answer.** The authoritative record is
/// `ListeningConsent` in the SwiftData store, which syncs; this stays as the fast,
/// synchronous, offline-safe read that every gate uses, kept in step by
/// `ListeningConsentStore.applyToDevice` at launch and on each remote merge. Write
/// through `ListeningConsentStore.set` rather than here, or the answer will not
/// leave the device.
enum SoundAnalysisPreferences {
    static let enabledKey = "sound.analysisEnabled"

    /// Test-only override of where the answer is stored. **`nil` — and therefore
    /// `.standard` — in the app**; nothing outside the test target ever sets it.
    ///
    /// It is a `@TaskLocal` rather than a plain `static var` on purpose. Three
    /// separate suites drive this one key, Swift Testing runs suites in parallel,
    /// and `.serialized` orders a suite's tests against each other and nothing else.
    /// A mutable static would only move the race from the *key* to the *pointer*:
    /// one suite swapping the store while another reads it is the same bug wearing a
    /// hat. A task-local is scoped to the task tree that bound it, so each test sees
    /// its own value no matter what runs beside it — the preference-shaped version
    /// of the container isolation `TestSupport.isolatedStore()` already provides
    /// (commit `b4c72a0`).
    /// Carries the suite *name* rather than a `UserDefaults` instance: the class is
    /// not `Sendable`, and a task-local value must be.
    @TaskLocal static var defaultsSuiteName: String?

    static var defaults: UserDefaults {
        guard let defaultsSuiteName else { return .standard }
        return UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    static var isEnabled: Bool {
        get {
            // `bool(forKey:)` returns false for an unset key, so default-on has to be
            // expressed explicitly rather than relying on the zero value.
            defaults.object(forKey: enabledKey) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: enabledKey) }
    }
}
