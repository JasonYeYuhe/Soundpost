import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the scheduler needs, abstracted so it
/// can be unit-tested without touching the real system center.
protocol UserNotificationScheduling {
    func pendingRequestIdentifiers() async -> [String]
    func removePendingRequests(withIdentifiers ids: [String])
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationScheduling {
    func pendingRequestIdentifiers() async -> [String] {
        await pendingNotificationRequests().map(\.identifier)
    }

    func removePendingRequests(withIdentifiers ids: [String]) {
        removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Reconciles the set of pending local notifications with a desired plan.
///
/// The interesting policy (which 64 to keep) lives in `NotificationPlanner`;
/// this type just diffs the plan against what's already scheduled and applies
/// the difference, only ever touching notifications it owns (prefix-tagged).
struct NotificationScheduler {
    let center: UserNotificationScheduling

    /// Prefix marking our requests, so we never disturb unrelated notifications.
    static let identifierPrefix = "capsule."

    init(center: UserNotificationScheduling) {
        self.center = center
    }

    static func identifier(for capsuleID: UUID) -> String {
        identifierPrefix + capsuleID.uuidString
    }

    /// Register exactly the planned notifications, removing any of ours that are
    /// no longer in the plan and adding any that are missing.
    func reconcile(plan: [PlannedNotification], title: String, body: String) async {
        let existing = await center.pendingRequestIdentifiers()
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        let existingSet = Set(existing)
        let desiredSet = Set(plan.map { Self.identifier(for: $0.capsuleID) })

        let stale = existing.filter { !desiredSet.contains($0) }
        if !stale.isEmpty {
            center.removePendingRequests(withIdentifiers: stale)
        }

        for item in plan {
            let id = Self.identifier(for: item.capsuleID)
            guard !existingSet.contains(id) else { continue } // already scheduled
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: id,
                content: content,
                trigger: Self.trigger(for: item)
            )
            try? await center.add(request)
        }
    }

    /// Build a calendar trigger pinned to the capsule's stored time zone, so the
    /// fire instant is deterministic across travel/DST (docs/PROJECT.md §1e.5).
    static func trigger(for item: PlannedNotification) -> UNCalendarNotificationTrigger {
        let timeZone = item.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: item.fireDate
        )
        components.timeZone = timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
}
