import Testing
import Foundation
import UserNotifications
@testable import Soundpost

/// In-memory stand-in for `UNUserNotificationCenter`.
private final class MockCenter: UserNotificationScheduling, @unchecked Sendable {
    var pending: [String] = []
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removed: [String] = []

    func pendingRequestIdentifiers() async -> [String] { pending }

    func removePendingRequests(withIdentifiers ids: [String]) {
        removed.append(contentsOf: ids)
        pending.removeAll { ids.contains($0) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
        pending.append(request.identifier)
    }
}

struct NotificationSchedulerTests {
    private func planned(_ id: UUID, _ offset: TimeInterval, tz: String? = nil) -> PlannedNotification {
        PlannedNotification(capsuleID: id, fireDate: Date(timeIntervalSinceNow: offset), timeZoneID: tz)
    }

    @Test func reconcileAddsPlannedAndRemovesOnlyOurStaleOnes() async {
        let mock = MockCenter()
        mock.pending = ["capsule.STALE", "other.keep"] // one of ours (stale), one not ours
        let scheduler = NotificationScheduler(center: mock)
        let id = UUID()

        await scheduler.reconcile(plan: [planned(id, 1_000)], title: "t", body: "b")

        #expect(mock.removed.contains("capsule.STALE"))
        #expect(!mock.removed.contains("other.keep")) // never touches foreign notifications
        #expect(mock.added.contains { $0.identifier == NotificationScheduler.identifier(for: id) })
    }

    @Test func reconcileSkipsAlreadyScheduled() async {
        let id = UUID()
        let mock = MockCenter()
        mock.pending = [NotificationScheduler.identifier(for: id)]
        let scheduler = NotificationScheduler(center: mock)

        await scheduler.reconcile(plan: [planned(id, 999)], title: "t", body: "b")

        #expect(mock.added.isEmpty) // no duplicate
    }

    @Test func reconcileToEmptyPlanClearsOurNotifications() async {
        let mock = MockCenter()
        mock.pending = ["capsule.A", "capsule.B"]
        let scheduler = NotificationScheduler(center: mock)

        await scheduler.reconcile(plan: [], title: "t", body: "b")

        #expect(Set(mock.removed) == ["capsule.A", "capsule.B"])
    }

    @Test func triggerPinsToStoredTimeZoneAndDoesNotRepeat() {
        let item = planned(UUID(), 5_000, tz: "Asia/Tokyo")
        let trigger = NotificationScheduler.trigger(for: item)
        #expect(trigger.dateComponents.timeZone == TimeZone(identifier: "Asia/Tokyo"))
        #expect(trigger.repeats == false)
    }

    @Test func identifierRoundTrips() {
        let id = UUID()
        let identifier = NotificationScheduler.identifier(for: id)
        #expect(identifier.hasPrefix(NotificationScheduler.identifierPrefix))
        #expect(identifier.dropFirst(NotificationScheduler.identifierPrefix.count) == id.uuidString)
    }
}
