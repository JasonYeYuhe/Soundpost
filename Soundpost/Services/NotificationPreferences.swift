import Foundation

/// User preference for **lock-screen notification content** (M12 §S3/§4A).
///
/// A resurface/echo notification can lead with the user's own one-line or place
/// ("'Rain on the window' — sealed 8 months ago"). That text renders on the lock
/// screen, where anyone glancing at the phone can read it, so it is the user's
/// *private words* — the honest default is **off** (generic copy), opt-in only.
/// Privacy-first, no dark pattern: turning it on is the user's deliberate choice.
///
/// Purely local: this changes only the on-device notification body. The M10 server
/// push stays content-free, so flipping this moves no privacy posture server-side.
/// Backed by the app's own UserDefaults (PrivacyInfo CA92.1).
enum NotificationPreferences {
    /// Shared with the Settings `@AppStorage` toggle and ContentView's resync
    /// trigger so all read the same key.
    static let personalizedKey = "notifications.personalized"

    /// Default **false** (generic copy). See the type doc for the rationale.
    static var personalized: Bool {
        get { UserDefaults.standard.bool(forKey: personalizedKey) }
        set { UserDefaults.standard.set(newValue, forKey: personalizedKey) }
    }

    /// A short token folded into each scheduled request's identity so that
    /// flipping the preference re-issues every owned request with fresh copy.
    /// Already-scheduled requests bake their body at schedule time, and the gallery
    /// resyncs only on the seal/echo *signature*; without a content-version bit a
    /// stale personalized body would linger on the lock screen after opt-out (the
    /// §S3 P0). Changing this string makes the old identifiers read as stale, so
    /// the scheduler removes and re-adds them.
    static func contentVersion(personalized: Bool) -> String {
        personalized ? "p1" : "g1"
    }
}
