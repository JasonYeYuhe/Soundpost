import Foundation

/// A single planned local notification for a capsule: either a sealed capsule
/// resurfacing on its date, or a gentle "echo" reminding the user of a past
/// recording. Both kinds share one notification slot per capsule (a capsule is
/// sealed XOR echoing, never both).
struct PlannedNotification: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case seal, echo }

    let capsuleID: UUID
    let fireDate: Date
    let timeZoneID: String?
    var kind: Kind = .seal
}

/// Pure scheduling policy (no system dependencies, fully unit-tested).
///
/// iOS allows at most **64** pending local-notification requests per app and
/// silently drops the rest (docs/PROJECT.md §1e.1). So we never blindly register
/// every sealed capsule; we register only the nearest-due window and re-plan on
/// each launch as earlier ones fire.
enum NotificationPlanner {
    /// The system-enforced ceiling on pending local-notification requests.
    static let systemPendingLimit = 64

    /// Choose which notifications to register: future-dated only, nearest-due
    /// first, capped at `limit`. Past-due items are excluded (they should
    /// resurface in-app, not fire a notification).
    static func plan(
        sealed: [PlannedNotification],
        now: Date,
        limit: Int = systemPendingLimit
    ) -> [PlannedNotification] {
        Array(
            sealed
                .filter { $0.fireDate > now }
                .sorted { $0.fireDate < $1.fireDate }
                .prefix(max(0, limit))
        )
    }

    /// Convenience: derive the plan straight from capsules. Candidates are
    /// sealed capsules (their resurface date) and captured capsules with a
    /// pending echo. Both compete for the same nearest-64 window.
    static func plan(
        capsules: [Capsule],
        now: Date,
        limit: Int = systemPendingLimit
    ) -> [PlannedNotification] {
        let candidates = capsules.compactMap { capsule -> PlannedNotification? in
            if capsule.state == .sealed, let due = capsule.sealUntil {
                return PlannedNotification(
                    capsuleID: capsule.id,
                    fireDate: due,
                    timeZoneID: capsule.sealTimeZoneID,
                    kind: .seal
                )
            }
            if capsule.state == .captured, let echo = capsule.echoAt {
                return PlannedNotification(
                    capsuleID: capsule.id,
                    fireDate: echo,
                    timeZoneID: nil, // echoes are near-term; device-local wall clock is right
                    kind: .echo
                )
            }
            return nil
        }
        return plan(sealed: candidates, now: now, limit: limit)
    }
}
