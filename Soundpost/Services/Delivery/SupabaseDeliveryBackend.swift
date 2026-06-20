import Foundation

/// Public (non-secret) connection info for the `sync-delivery` Edge Function.
/// The URL and anon key are NOT secrets — they're safe in the binary. The only
/// secret is the per-user CloudKit key, which is sent as the Bearer at call time
/// and never stored here. The real APNs `.p8` + service-role key live ONLY in
/// the function env (§G).
struct SupabaseDeliveryConfig: Sendable {
    /// e.g. `https://<project-ref>.functions.supabase.co` — empty until S2 is
    /// deployed, which keeps `SupabaseDeliveryBackend.isConfigured == false` so
    /// the app stays on the local path (fully functional) until the server lands.
    let functionsURL: String
    /// The project's anon (publishable) key, passed as the `apikey` header.
    let anonKey: String

    /// Live config. The M10 delivery backend is **co-located in the `cli-pulse`
    /// Supabase project** (org Kanousei, already Pro) — additive, namespaced
    /// tables/functions, $0 extra (docs/M10-DEVPLAN.md §13). The URL + publishable
    /// key are public, not secret; the only secret is the per-user CloudKit key
    /// sent as the bearer at call time.
    static let current = SupabaseDeliveryConfig(
        functionsURL: "https://gkjwsxotmwrgqsvfijzs.supabase.co/functions/v1",
        anonKey: "sb_publishable_cXlWLnMmPSHkYx3ZsAxTYA_L_x8mqM1"
    )
}

enum DeliveryError: Error, Equatable {
    case notConfigured
    case server(status: Int)
}

/// The real `DeliveryBackend`: a thin HTTPS client for the `sync-delivery` Edge
/// Function. Auth is the per-user CloudKit secret presented as the Bearer token
/// (§G) — the function trusts it as the user identity because only the user's
/// devices hold it. Content-free: it sends the capsule UUID, fire instant, IANA
/// tz, and kind; never note/place/audio. Zero third-party deps — raw URLSession.
struct SupabaseDeliveryBackend: DeliveryBackend {
    let config: SupabaseDeliveryConfig
    let session: URLSession

    init(config: SupabaseDeliveryConfig = .current, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var isConfigured: Bool { !config.functionsURL.isEmpty }

    func registerToken(_ registration: DeviceTokenRegistration, userKey: String) async throws {
        try await post(action: "register_token", userKey: userKey, fields: [
            "token": registration.token,
            "environment": registration.environment,
            "platform": registration.platform,
            "bundle_id": registration.bundleID,
        ])
    }

    func unregisterToken(_ token: String, userKey: String) async throws {
        try await post(action: "unregister_token", userKey: userKey, fields: ["token": token])
    }

    func upsertJob(_ job: DeliveryJob, userKey: String) async throws {
        try await post(action: "upsert_job", userKey: userKey, fields: [
            "capsule_id": job.capsuleID.uuidString,
            "kind": job.kind,
            "wall_clock": Self.wallClockString(job.fireDate, timeZoneID: job.timeZoneID),
            "time_zone": job.timeZoneID,
        ])
    }

    func cancelJob(capsuleID: UUID, userKey: String) async throws {
        try await post(action: "cancel_job", userKey: userKey, fields: ["capsule_id": capsuleID.uuidString])
    }

    func deleteAll(userKey: String) async throws {
        try await post(action: "delete_all", userKey: userKey, fields: [:])
    }

    // MARK: - Wire

    /// The local wall-clock components of `date` in `timeZoneID`, tz-naive — the
    /// exact contract the server stores (`wall_clock` + `time_zone`) and fires at
    /// `wall_clock AT TIME ZONE time_zone`, so a years-out seal stays DST-correct.
    static func wallClockString(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private func post(action: String, userKey: String, fields: [String: String]) async throws {
        guard let url = URL(string: config.functionsURL + "/sync-delivery") else {
            throw DeliveryError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The per-user secret is the bearer (proof-of-ownership).
        request.setValue("Bearer \(userKey)", forHTTPHeaderField: "Authorization")
        if !config.anonKey.isEmpty {
            request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        }
        var body = fields
        body["action"] = action
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeliveryError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}
