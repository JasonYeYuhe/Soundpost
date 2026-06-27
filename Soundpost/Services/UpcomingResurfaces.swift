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
}
