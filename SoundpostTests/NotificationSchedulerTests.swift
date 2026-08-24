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

    /// The identifier `reconcile` will build for `item` given the copy it renders.
    /// A request's identity now depends on its words (M16 §4C), so a test that wants
    /// to talk about "the request for this item" has to say which words.
    private func scheduled(
        _ item: PlannedNotification,
        version: String = "",
        title: String = "t",
        body: String = "b"
    ) -> String {
        NotificationScheduler.identifier(
            for: item,
            contentVersion: version,
            contentFingerprint: NotificationScheduler.contentFingerprint(title: title, body: body)
        )
    }

    @Test func reconcileAddsPlannedAndRemovesOnlyOurStaleOnes() async {
        let mock = MockCenter()
        mock.pending = ["capsule.STALE", "other.keep"] // one of ours (stale), one not ours
        let scheduler = NotificationScheduler(center: mock)
        let item = planned(UUID(), 1_000)

        await scheduler.reconcile(plan: [item], title: "t", body: "b")

        #expect(mock.removed.contains("capsule.STALE"))
        #expect(!mock.removed.contains("other.keep")) // never touches foreign notifications
        #expect(mock.added.contains { $0.identifier == scheduled(item) })
    }

    @Test func reconcileSkipsAlreadyScheduled() async {
        let item = planned(UUID(), 999)
        let mock = MockCenter()
        mock.pending = [scheduled(item)]
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
        let echoIdentifier = scheduled(echo)
        #expect(mock.pending == [echoIdentifier])

        var seal = planned(id, 9_999)
        seal.kind = .seal
        await scheduler.reconcile(plan: [seal], title: "t", body: "b")

        #expect(mock.removed.contains(echoIdentifier)) // stale echo replaced
        #expect(mock.pending == [scheduled(seal)])
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
        let pID = scheduled(item, version: "p1", body: "personal words")
        #expect(mock.pending == [pID])

        // Opt out: the personalized request is removed and a generic one re-added.
        await scheduler.reconcile(plan: [item], contentVersion: "g1") { _ in ("t", "generic") }
        let gID = scheduled(item, version: "g1", body: "generic")
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

    // MARK: Content-dependent invalidation (M16 §4C)

    /// **The trap this milestone exists to close.** A notification's body is baked at
    /// schedule time, and `reconcile` skips any identifier it has already scheduled.
    /// So before M16, correcting a typo in a capsule's one line left the pending
    /// request untouched and the old sentence on the lock screen — for as long as the
    /// seal, which can be years.
    ///
    /// Written so it FAILS against the pre-M16 scheduler: nothing here asks whether
    /// *a* request exists (which passed all along and proved nothing), it asks what
    /// the pending request will actually say.
    @Test func editingTheWordsRebuildsAnAlreadyScheduledBody() async {
        let mock = MockCenter()
        let scheduler = NotificationScheduler(center: mock)
        let item = planned(UUID(), 10_000)
        let title = "A capsule has resurfaced"
        let before = "“Rain on the window” — tap to listen."
        let after = "“Rain on the kitchen window” — tap to listen."

        await scheduler.reconcile(plan: [item], contentVersion: "p1") { _ in (title, before) }
        #expect(mock.pending.count == 1)

        // Only the note changed. Same capsule, same fire date, same preference — so
        // `contentVersion` is identical and cannot help.
        await scheduler.reconcile(plan: [item], contentVersion: "p1") { _ in (title, after) }

        #expect(mock.pending.count == 1)                 // still exactly one reminder
        let pendingBodies = mock.pending.compactMap { id in
            mock.added.last { $0.identifier == id }?.content.body
        }
        #expect(pendingBodies == [after])                // and it says the new sentence
        #expect(mock.removed.contains(scheduled(item, version: "p1", title: title, body: before)))
    }

    /// The other half of the same promise: copy that has NOT changed must not churn.
    /// A user who never opted into lock-screen previews reads generic copy, which
    /// does not vary with their note — so editing it should tear down nothing.
    @Test func unchangedCopyReissuesNothing() async {
        let mock = MockCenter()
        let scheduler = NotificationScheduler(center: mock)
        let item = planned(UUID(), 10_000)

        await scheduler.reconcile(plan: [item], contentVersion: "g1") { _ in ("t", "generic") }
        #expect(mock.added.count == 1)

        await scheduler.reconcile(plan: [item], contentVersion: "g1") { _ in ("t", "generic") }

        #expect(mock.added.count == 1)   // nothing re-added
        #expect(mock.removed.isEmpty)    // and nothing torn down
    }

    /// The fingerprint has to survive a relaunch: Swift's `hashValue` is seeded per
    /// process, so an identifier built from it would differ on every launch and every
    /// sync would replace all 64 requests. A test that only checked "the identifier
    /// changed when the words changed" would not have noticed.
    @Test func theFingerprintIsStableAndDistinguishesTheFields() {
        #expect(NotificationScheduler.contentFingerprint(title: "t", body: "b")
                == NotificationScheduler.contentFingerprint(title: "t", body: "b"))
        #expect(NotificationScheduler.contentFingerprint(title: "t", body: "b")
                != NotificationScheduler.contentFingerprint(title: "t", body: "b "))
        // Length-prefixed, so a run of characters cannot slide across the boundary.
        #expect(NotificationScheduler.contentFingerprint(title: "ab", body: "c")
                != NotificationScheduler.contentFingerprint(title: "a", body: "bc"))
        // A hard-coded value pins the encoding: change the algorithm and every
        // shipped install re-issues its pending set, which is a decision to take on
        // purpose rather than by accident.
        #expect(NotificationScheduler.contentFingerprint(title: "t", body: "b") == "1pgw3afqzkm3l")
    }

    /// A fingerprinted identifier still round-trips to its capsule and still carries
    /// the prefix the M10 server-push dedup matches on.
    @Test func fingerprintedIdentifiersKeepTheirCapsulePrefix() {
        let id = UUID()
        let item = planned(id, 5_000)
        let identifier = scheduled(item, version: "p1")
        #expect(identifier.hasPrefix("capsule.\(id.uuidString)|seal|"))
        #expect(NotificationScheduler.capsuleID(fromIdentifier: identifier) == id)
        #expect(NotificationCoordinator.localSealIdentifiers(for: id, among: [identifier]) == [identifier])
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
