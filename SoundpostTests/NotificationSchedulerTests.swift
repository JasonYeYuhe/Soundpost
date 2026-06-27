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
        let item = planned(UUID(), 1_000)

        await scheduler.reconcile(plan: [item], title: "t", body: "b")

        #expect(mock.removed.contains("capsule.STALE"))
        #expect(!mock.removed.contains("other.keep")) // never touches foreign notifications
        #expect(mock.added.contains { $0.identifier == NotificationScheduler.identifier(for: item) })
    }

    @Test func reconcileSkipsAlreadyScheduled() async {
        let item = planned(UUID(), 999)
        let mock = MockCenter()
        mock.pending = [NotificationScheduler.identifier(for: item)]
        let scheduler = NotificationScheduler(center: mock)

        await scheduler.reconcile(plan: [item], title: "t", body: "b")

        #expect(mock.added.isEmpty) // no duplicate
    }

    /// Regression: when a capsule's scheduling changes shape — its echo is
    /// superseded by a seal on a different date — the old request must be
    /// replaced, not silently kept because the capsule UUID matches.
    @Test func reconcileReplacesWhenEchoBecomesSeal() async {
        let id = UUID()
        var echo = planned(id, 100)
        echo.kind = .echo
        let mock = MockCenter()
        let scheduler = NotificationScheduler(center: mock)
        await scheduler.reconcile(plan: [echo], title: "t", body: "b")
        let echoIdentifier = NotificationScheduler.identifier(for: echo)
        #expect(mock.pending == [echoIdentifier])

        var seal = planned(id, 9_999)
        seal.kind = .seal
        await scheduler.reconcile(plan: [seal], title: "t", body: "b")

        #expect(mock.removed.contains(echoIdentifier)) // stale echo replaced
        #expect(mock.pending == [NotificationScheduler.identifier(for: seal)])
    }

    @Test func reconcileToEmptyPlanClearsOurNotifications() async {
        let mock = MockCenter()
        mock.pending = ["capsule.A", "capsule.B"]
        let scheduler = NotificationScheduler(center: mock)

        await scheduler.reconcile(plan: [], title: "t", body: "b")

        #expect(Set(mock.removed) == ["capsule.A", "capsule.B"])
    }

    /// §S3 P0: a notification's body is baked at schedule time, so flipping the
    /// personalized preference must re-issue every owned request — otherwise stale
    /// personalized text would linger on the lock screen after opt-out. Folding the
    /// content version into the identity makes the old request read as stale.
    @Test func flippingContentVersionReissuesOwnedRequestsWithFreshCopy() async {
        let mock = MockCenter()
        let scheduler = NotificationScheduler(center: mock)
        let item = planned(UUID(), 5_000)

        // Opted in: personalized body.
        await scheduler.reconcile(plan: [item], contentVersion: "p1") { _ in ("t", "personal words") }
        let pID = NotificationScheduler.identifier(for: item, contentVersion: "p1")
        #expect(mock.pending == [pID])

        // Opt out: the personalized request is removed and a generic one re-added.
        await scheduler.reconcile(plan: [item], contentVersion: "g1") { _ in ("t", "generic") }
        let gID = NotificationScheduler.identifier(for: item, contentVersion: "g1")
        #expect(mock.removed.contains(pID))         // stale personalized body gone
        #expect(mock.pending == [gID])
        #expect(mock.added.last?.content.body == "generic")
        // The capsule-prefix dedup still matches both forms (M10 server push).
        #expect(pID.hasPrefix("capsule.\(item.capsuleID.uuidString)|seal|"))
        #expect(gID.hasPrefix("capsule.\(item.capsuleID.uuidString)|seal|"))
    }

    @Test func emptyContentVersionKeepsTheLegacyIdentifierForm() {
        // Backward compatibility: the default "" tag yields the v1.0 identifier, so
        // the convenience reconcile + existing tests are unaffected.
        let item = planned(UUID(), 1_000)
        #expect(NotificationScheduler.identifier(for: item)
                == NotificationScheduler.identifier(for: item, contentVersion: ""))
        #expect(!NotificationScheduler.identifier(for: item).hasSuffix("|"))
    }

    @Test func triggerPinsToStoredTimeZoneAndDoesNotRepeat() {
        let item = planned(UUID(), 5_000, tz: "Asia/Tokyo")
        let trigger = NotificationScheduler.trigger(for: item)
        #expect(trigger.dateComponents.timeZone == TimeZone(identifier: "Asia/Tokyo"))
        #expect(trigger.repeats == false)
    }

    @Test func identifierRoundTrips() {
        let id = UUID()
        var item = planned(id, 5_000, tz: nil)
        item.kind = .echo
        let identifier = NotificationScheduler.identifier(for: item)
        #expect(identifier.hasPrefix(NotificationScheduler.identifierPrefix))
        #expect(NotificationScheduler.capsuleID(fromIdentifier: identifier) == id)
    }

    @Test func capsuleIDParsesLegacyAndForeignIdentifiers() {
        let id = UUID()
        // Legacy form (v1.0 builds): bare "capsule.<uuid>" with no suffix.
        #expect(NotificationScheduler.capsuleID(fromIdentifier: "capsule.\(id.uuidString)") == id)
        #expect(NotificationScheduler.capsuleID(fromIdentifier: "other.\(id.uuidString)") == nil)
        #expect(NotificationScheduler.capsuleID(fromIdentifier: "capsule.not-a-uuid|echo|1") == nil)
    }
}
