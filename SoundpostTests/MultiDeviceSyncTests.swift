import Testing
import Foundation
import CoreData
import UserNotifications
@testable import Soundpost

/// M9 §S4: multi-device notification rescheduling. A capsule sealed/echoed on
/// another device arrives via CloudKit with no local notification here, so a
/// remote-store merge must trigger a reschedule — and the identifier scheme must
/// dedupe a seal that exists on both devices.
@MainActor
struct MultiDeviceSyncTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func importedSeal(offset: TimeInterval, tz: String? = "Asia/Tokyo") throws -> Capsule {
        // A capsule "synced from another device": sealed, with a future date, but
        // no local notification scheduled on this device yet.
        let capsule = Capsule(createdAt: now.addingTimeInterval(-86_400))
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.sealUntil = now.addingTimeInterval(offset)
        capsule.sealTimeZoneID = tz
        try capsule.transition(to: .sealed)
        return capsule
    }

    // MARK: Planner over imported capsules

    @Test func plannerSchedulesAnImportedSealedCapsule() throws {
        let imported = try importedSeal(offset: 5_000)
        let plan = NotificationPlanner.plan(capsules: [imported], now: now)
        #expect(plan.count == 1)
        #expect(plan.first?.kind == .seal)
        #expect(plan.first?.capsuleID == imported.id)
        #expect(plan.first?.fireDate == now.addingTimeInterval(5_000))
        #expect(plan.first?.timeZoneID == "Asia/Tokyo")
    }

    // MARK: Cross-device identifier dedup

    /// The same seal present on both devices (same uuid + kind + fire instant)
    /// maps to one identifier, so reconciling never schedules it twice.
    @Test func sameSealOnBothDevicesYieldsOneIdentifier() throws {
        let id = UUID()
        let fire = now.addingTimeInterval(9_000)
        let a = PlannedNotification(capsuleID: id, fireDate: fire, timeZoneID: "Asia/Tokyo", kind: .seal)
        let b = PlannedNotification(capsuleID: id, fireDate: fire, timeZoneID: "UTC", kind: .seal)
        // Identifier keys on uuid|kind|epoch (not time zone), so the two coincide.
        #expect(NotificationScheduler.identifier(for: a) == NotificationScheduler.identifier(for: b))
    }

    @Test func reconcileDoesNotDoubleScheduleADeviceSharedSeal() async {
        let id = UUID()
        let item = PlannedNotification(capsuleID: id, fireDate: now.addingTimeInterval(9_000),
                                       timeZoneID: nil, kind: .seal)
        let mock = MockNotificationCenter()
        mock.pending = [NotificationScheduler.identifier(for: item)] // already scheduled (from device A)
        let scheduler = NotificationScheduler(center: mock)

        await scheduler.reconcile(plan: [item], title: "t", body: "b")

        #expect(mock.added.isEmpty) // the imported seal is recognised, not re-added
    }

    // MARK: Remote-change handler

    @Test func handleRemoteChangeInvokesReschedule() async {
        let reconciler = RemoteChangeReconciler()
        var calls = 0
        reconciler.observe(reschedule: { calls += 1 }, center: NotificationCenter())
        await reconciler.handleRemoteChange()?.value
        #expect(calls == 1)
        reconciler.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func postingRemoteChangeNotificationTriggersReschedule() async {
        let center = NotificationCenter()
        let reconciler = RemoteChangeReconciler()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            reconciler.observe(reschedule: { cont.resume() }, center: center)
            center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        }
        reconciler.stop() // reaching here means the observer fired the reschedule
    }
}

/// In-memory stand-in for `UNUserNotificationCenter` (mirrors the one in
/// NotificationSchedulerTests; duplicated to keep suites independent).
private final class MockNotificationCenter: UserNotificationScheduling, @unchecked Sendable {
    var pending: [String] = []
    private(set) var added: [UNNotificationRequest] = []

    func pendingRequestIdentifiers() async -> [String] { pending }
    func removePendingRequests(withIdentifiers ids: [String]) { pending.removeAll { ids.contains($0) } }
    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
        pending.append(request.identifier)
    }
}
