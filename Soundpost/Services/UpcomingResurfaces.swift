import Foundation

/// The "next to resurface" anticipation data (M12 §S8/§4F): the nearest upcoming
/// seals and echoes, nearest-first. **Metadata-only** — each item carries only the
/// fire date and kind, never a capsule's hidden note/place, so the strip can show
/// "a capsule opens in N days" without leaking sealed content.
///
/// Deliberately distinct from `NotificationPlanner` (which drops a server-owned
/// seal so exactly one notification fires): the strip shows **all** upcoming
/// resurfaces, so the anticipation is honest whether the local backstop or the
/// cloud push will ultimately fire.
enum UpcomingResurfaces {
    static func nearest(_ capsules: [Capsule], now: Date = .now, limit: Int = 3) -> [PlannedNotification] {
        let candidates = capsules.compactMap { capsule -> PlannedNotification? in
            if capsule.state == .sealed, let due = capsule.sealUntil, due > now {
                return PlannedNotification(
                    capsuleID: capsule.id, fireDate: due, timeZoneID: capsule.sealTimeZoneID, kind: .seal)
            }
            if capsule.state == .captured, let echo = capsule.echoAt, echo > now {
                return PlannedNotification(
                    capsuleID: capsule.id, fireDate: echo, timeZoneID: nil, kind: .echo)
            }
            return nil
        }
        return Array(candidates.sorted { $0.fireDate < $1.fireDate }.prefix(max(0, limit)))
    }

    /// A value that changes exactly when a capsule's **scheduling-relevant** state
    /// does, so `.onChange` can re-sync notifications without re-syncing on every
    /// unrelated edit.
    ///
    /// It lived in `ContentView` as a private computed property. It is here because a
    /// private computed property is not something a test can measure, and this one is
    /// evaluated on **every body pass** — every keystroke in the search field, every
    /// sheet presentation, every `scenePhase` change — over the whole library. That is
    /// the same shape as the per-card resolution M19 §4B-ii found, and it was equally
    /// invisible for the same reason: it reads like a stored value at its use site.
    ///
    /// Measured before deciding anything (§4B-iii). It is a hash rather than the
    /// joined string it used to be: the old version allocated one interpolated string
    /// per capsule and joined them, so the *comparison* SwiftUI does on every pass ran
    /// over a string proportional to the library. A hash is fixed-width, and the
    /// question `.onChange` asks — "is this different from last time?" — is exactly
    /// what a hash answers. Collisions would mean a missed notification re-sync, which
    /// is why the four fields are fed in separately rather than concatenated.
    static func sealSignature(_ capsules: [Capsule]) -> Int {
        var hasher = Hasher()
        for capsule in capsules {
            hasher.combine(capsule.id)
            hasher.combine(capsule.state.rawValue)
            hasher.combine(capsule.sealUntil)
            hasher.combine(capsule.echoAt)
        }
        return hasher.finalize()
    }
}
