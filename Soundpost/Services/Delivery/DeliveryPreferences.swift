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

    // MARK: Durable delete-path job cancels (§S4)

    /// Capsule ids whose server job must be cancelled but whose cancel hasn't yet
    /// confirmed. A deleted capsule leaves the `@Query` array, so `reconcile` can't
    /// retry it; persisting the id here lets the cancel survive a cold launch or a
    /// momentarily-unresolved key and retry on the next sign-in / sync.
    private static let pendingCancelKey = "delivery.pendingCancel"

    static var pendingCancelCapsuleIDs: [UUID] {
        (UserDefaults.standard.stringArray(forKey: pendingCancelKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func enqueuePendingCancel(_ capsuleID: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: pendingCancelKey) ?? [])
        ids.insert(capsuleID.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: pendingCancelKey)
    }

    static func resolvePendingCancel(_ capsuleID: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: pendingCancelKey) ?? [])
        ids.remove(capsuleID.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: pendingCancelKey)
    }
}
