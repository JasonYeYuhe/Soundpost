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
        if let defaultsSuiteName { return UserDefaults(suiteName: defaultsSuiteName) ?? .standard }
        #if DEBUG
        // **The screenshot build gets its own preferences** (M19 §4A).
        //
        // `-seedSampleData` exists to photograph the app, and until now it
        // photographed an app from before 1.6.0: `hasStanding` is set on the
        // production launch path from `answered || hasRecordedHere`, and a demo
        // library is *seeded*, not recorded, so neither is ever true. Every "Soundpost
        // heard" line in the app is gated on it, so none of them appeared — including
        // on the sample `DemoData` gives no note to *precisely so* that one would.
        // The comment saying so has been false on every clean machine since M17.
        //
        // A separate suite rather than a write to `.standard`: granting standing is a
        // real answer about a real person's real library, and a screenshot run must
        // not leave one behind on a device that later opens the app for real.
        if AppEnvironment.isDemoSeed, let demo = UserDefaults(suiteName: demoSuiteName) {
            return demo
        }
        #endif
        return .standard
    }

    #if DEBUG
    /// Preferences for the `-seedSampleData` build, isolated from the real ones.
    static let demoSuiteName = "com.soundpost.demo-screenshots"
    #endif

    static var isEnabled: Bool {
        get {
            // `bool(forKey:)` returns false for an unset key, so default-on has to be
            // expressed explicitly rather than relying on the zero value.
            defaults.object(forKey: enabledKey) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static let hasStandingKey = "sound.hasStanding"

    /// Whether `isEnabled` on this device is a real **answer** rather than an untouched
    /// default — M15 §11Q's "standing", asked by the surfaces that *reveal* a label.
    ///
    /// M15 built standing for the retrospective drains, because the mirror above reads
    /// `true` both for someone who wants listening on and for a device that has never
    /// been told anything — and on a phone set up as new and signed into iCloud, the
    /// library arrives from CloudKit long before the `ListeningConsent` row does. Worse
    /// than "before": CloudKit returns a zone's changes in roughly modification order,
    /// so the person who opted out *most recently* has their answer sorted behind every
    /// capsule it applies to.
    ///
    /// M17 then added a second way for a label to reach someone — showing it on a card —
    /// and did not extend standing to it, so in that same window the app could display
    /// exactly what the user had opted out of. This closes that.
    ///
    /// **Monotonic, which is what makes a persisted flag safe here.** Both inputs (an
    /// account row exists; this install has recorded) only ever become true, so a stale
    /// `true` cannot be wrong. A stale `false` costs one launch of hidden labels and
    /// then corrects itself — the safe direction to be wrong in.
    static var hasStanding: Bool {
        get { defaults.object(forKey: hasStandingKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: hasStandingKey) }
    }

    /// Whether a stored label may be **revealed** on this device at all — shown on a
    /// card or a detail screen, matched by search, or matched by a sound facet.
    ///
    /// The single rule those gates default to. `isEnabled` alone is not enough: it is
    /// the *answer*, and standing is whether the answer is one.
    static var mayReveal: Bool { isEnabled && hasStanding }

    static let localHistoryKey = "sound.hasRecordedHere"

    /// Has **this install** ever been the device that recorded a capsule?
    ///
    /// It exists to answer a different question than it appears to: *is the mirror
    /// above a real answer, or merely its default?*
    ///
    /// `isEnabled` cannot tell you. It reads `true` both for someone who wants
    /// listening on and for a brand-new install that has never been told anything —
    /// and on a phone set up as new, signed into iCloud, the library arrives from
    /// CloudKit long before the `ListeningConsent` row does. (Worse than "before":
    /// CloudKit returns a zone's changes in roughly modification order, so the person
    /// who opted out *most recently* has their answer sorted behind every capsule.)
    /// The launch backfill would then analyse the whole imported library of somebody
    /// who had said no — the exact failure account-wide consent exists to prevent.
    ///
    /// The correlation that makes this work: **the mirror is only untrustworthy when
    /// `UserDefaults` was wiped, and the same wipe clears this key.** A restore from
    /// backup brings `UserDefaults` with it, so an opted-out user's `false` comes back
    /// too and there is nothing to protect against; a device set up as new brings the
    /// library without the preferences, which is precisely the dangerous case.
    ///
    /// Seeded from `hasCompletedOnboarding` for installs that predate the key — the
    /// same wipe semantics, so it cannot resurrect standing that a wipe removed.
    static var hasRecordedHere: Bool {
        get {
            if defaults.object(forKey: localHistoryKey) as? Bool == true { return true }
            return defaults.object(forKey: "hasCompletedOnboarding") as? Bool == true
        }
        set { defaults.set(newValue, forKey: localHistoryKey) }
    }
}
