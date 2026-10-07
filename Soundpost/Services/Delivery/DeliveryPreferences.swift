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

    /// A private `UserDefaults` suite for the task tree that binds it — tests only, the
    /// same seam `SoundAnalysisPreferences` has (M20 §4C). The pending-cancel queue is
    /// one list for the whole app, and `reconcile` drains *all* of it: two suites
    /// running side by side would each cancel and resolve the other's ids, and a test
    /// would pass or fail by interleaving.
    @TaskLocal static var defaultsSuiteName: String?

    private static var defaults: UserDefaults {
        if let defaultsSuiteName { return UserDefaults(suiteName: defaultsSuiteName) ?? .standard }
        return .standard
    }

    static var cloudOptedOut: Bool {
        get { defaults.bool(forKey: optedOutKey) }
        set { defaults.set(newValue, forKey: optedOutKey) }
    }

    // MARK: Durable delete-path job cancels (§S4)

    /// Capsule ids whose server job must be cancelled but whose cancel hasn't yet
    /// confirmed. A deleted capsule leaves the `@Query` array, so `reconcile` can't
    /// retry it; persisting the id here lets the cancel survive a cold launch or a
    /// momentarily-unresolved key and retry on the next sign-in / sync.
    private static let pendingCancelKey = "delivery.pendingCancel"

    static var pendingCancelCapsuleIDs: [UUID] {
        (defaults.stringArray(forKey: pendingCancelKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func enqueuePendingCancel(_ capsuleID: UUID) {
        var ids = Set(defaults.stringArray(forKey: pendingCancelKey) ?? [])
        ids.insert(capsuleID.uuidString)
        defaults.set(Array(ids), forKey: pendingCancelKey)
    }

    static func resolvePendingCancel(_ capsuleID: UUID) {
        var ids = Set(defaults.stringArray(forKey: pendingCancelKey) ?? [])
        ids.remove(capsuleID.uuidString)
        defaults.set(Array(ids), forKey: pendingCancelKey)
    }
}
