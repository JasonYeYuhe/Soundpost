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
    /// plus an optional `|<contentVersion>` tag and an optional `|c<fingerprint>`.
    ///
    /// The `contentVersion` folds the *body's* identity (personalized vs generic —
    /// §S3) into the request id: a notification's body is baked at schedule time,
    /// so flipping the lock-screen-preview preference must change the identifier or
    /// the stale body lingers. Empty (the default, and the legacy v1.0 form) adds
    /// no tag. The capsule prefix (`capsule.<uuid>|seal|`) is unaffected, so the
    /// M10 server-push dedup and the UUID round-trip still hold.
    ///
    /// `contentFingerprint` is the per-capsule half of the same idea, added in M16
    /// §4C because the global token could not do this job: it moves only when a
    /// *preference* flips, so editing one capsule's note left its identifier
    /// unchanged, `reconcile` skipped the request it had already scheduled, and the
    /// sentence the user had just corrected stayed on the lock screen — for as long
    /// as the seal, which can be years. Empty (the default) adds no tag, so the
    /// pure-identifier form and the legacy v1.0 form are both unchanged.
    static func identifier(
        for item: PlannedNotification,
        contentVersion: String = "",
        contentFingerprint: String = ""
    ) -> String {
        let kind = item.kind == .seal ? "seal" : "echo"
        var identifier = "\(identifierPrefix)\(item.capsuleID.uuidString)|\(kind)|\(Int(item.fireDate.timeIntervalSince1970))"
        if !contentVersion.isEmpty { identifier += "|\(contentVersion)" }
        if !contentFingerprint.isEmpty { identifier += "|c\(contentFingerprint)" }
        return identifier
    }

    /// A short, **deterministic** token for one notification's rendered copy.
    ///
    /// Deliberately not Swift's `Hashable`: `hashValue` is seeded per process, so an
    /// identifier built from it would differ on every launch and every sync would
    /// tear down and re-add all 64 requests — while still passing any test that only
    /// asked whether the identifier had changed. FNV-1a is stable across launches and
    /// devices, and each field is length-prefixed so ("ab", "c") and ("a", "bc")
    /// cannot collide.
    static func contentFingerprint(title: String, body: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for field in [title, body] {
            for byte in "\(field.utf8.count):\(field)".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 36)
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
        // Render every planned body FIRST and fold it into that request's identity.
        //
        // A body is baked at schedule time and the loop below skips any identifier it
        // has already scheduled, so without this an edited capsule kept its old
        // sentence on the lock screen (M16 §4C). The fingerprint is taken from the
        // **rendered copy**, not from a list of the fields the copy happens to read,
        // and that choice is the M15 §11P lesson applied here: a check derived from a
        // list cannot fail for what is missing from the list, and this list would have
        // needed revising every time the copy changed. Hashing what will actually be
        // shown cannot drift out of step with it. It also invalidates *nothing* when
        // the words are unchanged — a generic body does not vary with a note, so a
        // user who never opted into lock-screen previews sees no churn at all — and it
        // catches two cases a field list would have missed: the device language
        // changing, and a soundprint erased out from under a body that quoted it.
        //
        // `content` is pure (`NotificationCopy.make`), so calling it for the whole
        // plan rather than only for additions costs at most 64 string lookups.
        let desired = plan.map { item -> (item: PlannedNotification, copy: (title: String, body: String), id: String) in
            let copy = content(item)
            return (
                item,
                copy,
                Self.identifier(
                    for: item,
                    contentVersion: contentVersion,
                    contentFingerprint: Self.contentFingerprint(title: copy.title, body: copy.body)
                )
            )
        }

        let existing = await center.pendingRequestIdentifiers()
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        let existingSet = Set(existing)
        let desiredSet = Set(desired.map(\.id))

        let stale = existing.filter { !desiredSet.contains($0) }
        if !stale.isEmpty {
            center.removePendingRequests(withIdentifiers: stale)
        }

        for entry in desired {
            guard !existingSet.contains(entry.id) else { continue } // already scheduled
            let notification = UNMutableNotificationContent()
            notification.title = entry.copy.title
            notification.body = entry.copy.body
            notification.sound = .default
            let request = UNNotificationRequest(
                identifier: entry.id,
                content: notification,
                trigger: Self.trigger(for: entry.item)
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
