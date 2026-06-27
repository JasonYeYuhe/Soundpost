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

    /// Identifier encodes capsule + kind + fire instant, so when a capsule's
    /// scheduling *changes* (echo edited, or superseded by a seal) the old
    /// request reads as stale and is replaced — a same-UUID identifier would
    /// silently keep the outdated one. Format: `capsule.<uuid>|<kind>|<epoch>`,
    /// plus an optional `|<contentVersion>` tag.
    ///
    /// The `contentVersion` folds the *body's* identity (personalized vs generic —
    /// §S3) into the request id: a notification's body is baked at schedule time,
    /// so flipping the lock-screen-preview preference must change the identifier or
    /// the stale body lingers. Empty (the default, and the legacy v1.0 form) adds
    /// no tag. The capsule prefix (`capsule.<uuid>|seal|`) is unaffected, so the
    /// M10 server-push dedup and the UUID round-trip still hold.
    static func identifier(for item: PlannedNotification, contentVersion: String = "") -> String {
        let kind = item.kind == .seal ? "seal" : "echo"
        let base = "\(identifierPrefix)\(item.capsuleID.uuidString)|\(kind)|\(Int(item.fireDate.timeIntervalSince1970))"
        return contentVersion.isEmpty ? base : "\(base)|\(contentVersion)"
    }

    /// Recover the capsule UUID from one of our request identifiers (used by
    /// notification-tap deep linking). Tolerates the legacy `capsule.<uuid>`
    /// form with no suffix.
    static func capsuleID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let payload = identifier.dropFirst(identifierPrefix.count)
        let uuidPart = payload.split(separator: "|", maxSplits: 1).first.map(String.init) ?? String(payload)
        return UUID(uuidString: uuidPart)
    }

    /// Register exactly the planned notifications, removing any of ours that are
    /// no longer in the plan and adding any that are missing. `content` supplies
    /// the title/body per item, so seals and echoes can read differently.
    func reconcile(
        plan: [PlannedNotification],
        contentVersion: String = "",
        content: (PlannedNotification) -> (title: String, body: String)
    ) async {
        let existing = await center.pendingRequestIdentifiers()
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        let existingSet = Set(existing)
        let desiredSet = Set(plan.map { Self.identifier(for: $0, contentVersion: contentVersion) })

        let stale = existing.filter { !desiredSet.contains($0) }
        if !stale.isEmpty {
            center.removePendingRequests(withIdentifiers: stale)
        }

        for item in plan {
            let id = Self.identifier(for: item, contentVersion: contentVersion)
            guard !existingSet.contains(id) else { continue } // already scheduled
            let (title, body) = content(item)
            let notification = UNMutableNotificationContent()
            notification.title = title
            notification.body = body
            notification.sound = .default
            let request = UNNotificationRequest(
                identifier: id,
                content: notification,
                trigger: Self.trigger(for: item)
            )
            try? await center.add(request)
        }
    }

    /// Convenience: one title/body for every item (used by tests and callers
    /// that don't need per-kind copy).
    func reconcile(plan: [PlannedNotification], title: String, body: String) async {
        await reconcile(plan: plan) { _ in (title, body) }
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
