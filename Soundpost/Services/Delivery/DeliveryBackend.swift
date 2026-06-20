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

/// One far-future delivery job for a sealed capsule — a content-free SIGNAL. The
/// backend stores only the capsule UUID, the fire instant, its IANA time zone,
/// and the kind. No note / place / audio ever leaves the device.
struct DeliveryJob: Equatable, Sendable {
    let capsuleID: UUID
    /// `"seal"` (only sealed capsules are ever enqueued server-side; echoes and
    /// near seals stay on the local path).
    let kind: String
    /// The absolute fire instant (the capsule's `sealUntil`).
    let fireDate: Date
    /// IANA id captured at seal time; the server fires at this wall-clock-in-zone
    /// so a years-out seal stays DST-correct.
    let timeZoneID: String
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

    /// Upsert a far-future job (idempotent; the server re-arms only when the fire
    /// instant changed and never resurrects a `sent` job).
    func upsertJob(_ job: DeliveryJob, userKey: String) async throws

    /// Cancel a capsule's job — on delete / unseal / resurface / re-seal.
    func cancelJob(capsuleID: UUID, userKey: String) async throws

    /// "Delete my cloud data": remove every token + job for this user (§S5).
    func deleteAll(userKey: String) async throws
}

/// The placeholder backend used before the real client is configured: it is
/// *not configured* and does nothing, so the app caches/queues locally and the
/// local path keeps working. (Kept for tests / a missing config.)
struct UnconfiguredDeliveryBackend: DeliveryBackend {
    var isConfigured: Bool { false }
    func registerToken(_ registration: DeviceTokenRegistration, userKey: String) async throws {}
    func unregisterToken(_ token: String, userKey: String) async throws {}
    func upsertJob(_ job: DeliveryJob, userKey: String) async throws {}
    func cancelJob(capsuleID: UUID, userKey: String) async throws {}
    func deleteAll(userKey: String) async throws {}
}
