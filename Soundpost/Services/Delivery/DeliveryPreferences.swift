import Foundation

/// User preference for cloud-backed delivery. "Delete my cloud data" (§S5) sets
/// `cloudOptedOut`, which both purges the server-side tokens/jobs *and* stops the
/// app re-collecting them — so the deletion sticks rather than re-populating on
/// the next sync. The local notification path keeps working regardless
/// (offline-first). Backed by the app's own UserDefaults (PrivacyInfo CA92.1).
enum DeliveryPreferences {
    /// Shared with the gallery's `@AppStorage` so the "Delete my cloud data"
    /// control reacts to the same key the registrar/service read.
    static let optedOutKey = "delivery.cloudOptedOut"

    static var cloudOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: optedOutKey) }
        set { UserDefaults.standard.set(newValue, forKey: optedOutKey) }
    }
}
