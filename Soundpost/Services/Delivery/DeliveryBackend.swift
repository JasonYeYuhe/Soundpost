import Foundation

/// One device's APNs token registration, as sent to the delivery backend. There
/// is deliberately no user identity in here — the caller pairs it with the
/// per-user key (the bearer) out of band, so the struct stays content-free and
/// `Sendable`.
struct DeviceTokenRegistration: Equatable, Sendable {
    /// Lowercase-hex APNs device token.
    let token: String
    /// Always `"ios"` for Soundpost.
    let platform: String
    /// `"development"` | `"production"` — selects the APNs host per token (§F).
    let environment: String
    /// The app's bundle id (`apns-topic`).
    let bundleID: String
}

/// The seam between the app and the (Supabase) delivery server. Abstracted so
/// S1's token-registration plumbing compiles and unit-tests **before** the
/// backend exists (S2): production wires a not-yet-configured stub; tests inject
/// a mock; S3 swaps in the real Supabase-backed client.
///
/// Every call carries the per-user `userKey` (the CloudKit-private-DB secret,
/// §B) as the proof-of-ownership bearer — the server trusts it as the user
/// identity because only the user's own devices hold it, so no caller can spoof
/// another user's delivery.
protocol DeliveryBackend: Sendable {
    /// Whether a real backend is wired. `false` for the S1 stub, so the
    /// registrar caches tokens but performs no network / iCloud work until the
    /// server lands — keeping S1 inert in production.
    var isConfigured: Bool { get }

    /// Upsert this device's token under `userKey` (idempotent; the server's
    /// `ON CONFLICT(token)` transfers ownership across an Apple-ID switch, §E).
    func registerToken(_ registration: DeviceTokenRegistration, userKey: String) async throws

    /// Remove **only this device's** token (sign-out). User-scoped jobs are left
    /// untouched, so the user's other signed-in devices keep delivering (§4A).
    func unregisterToken(_ token: String, userKey: String) async throws
}

/// The S1 placeholder backend: no server exists yet, so it is *not configured*
/// and does nothing. Swapped for the real Supabase client in S3.
struct UnconfiguredDeliveryBackend: DeliveryBackend {
    var isConfigured: Bool { false }
    func registerToken(_ registration: DeviceTokenRegistration, userKey: String) async throws {}
    func unregisterToken(_ token: String, userKey: String) async throws {}
}
