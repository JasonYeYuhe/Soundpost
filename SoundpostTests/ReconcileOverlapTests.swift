import Foundation
import Testing
import UserNotifications
@testable import Soundpost

/// Overlapping reconciles converge on the newest plan (M20 §4D).
///
/// Eleven call sites can start a notification sync, and nothing used to serialise the
/// reconcile underneath them: it reads the pending set, removes what is stale, then
/// awaits one `add` per missing request. An older reconcile suspended in an `add` could
/// resume after a newer one had finished and put back a request the newer plan had
/// dropped — a reminder for a capsule that had just been unsealed, firing on its old
/// date; or one request too many, and iOS silently drops another from its 64.
///
/// These tests must fail against the code before M20 **and against an actor-only
/// version**: an actor is reentrant across `await`, so wrapping the same body in one
/// interleaves at the same suspension and only looks serialised. Both are recorded as
/// controls in the plan.
@MainActor
@Suite("Overlapping notification reconciles")
struct ReconcileOverlapTests {
    private func planned(_ offsetDays: Double) -> PlannedNotification {
        PlannedNotification(capsuleID: UUID(), fireDate: Date(timeIntervalSinceNow: offsetDays * 86_400),
                            timeZoneID: "UTC")
    }

    private func scheduled(_ item: PlannedNotification) -> String {
        NotificationScheduler.identifier(
            for: item, contentFingerprint: NotificationScheduler.contentFingerprint(title: "t", body: "b"))
    }

    /// Poll until `condition` holds, or give up after `limit` — never a fixed sleep.
    private func wait(upTo limit: Duration = .seconds(2), until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func anOlderReconcileCannotPutBackWhatANewerOneRemoved() async throws {
        let center = HoldingCenter()
        let scheduler = NotificationScheduler(center: center)
        let unsealed = planned(1)   // the older plan's; the newer plan dropped it
        let kept = planned(2)

        center.holdNextAdd()
        let older = Task { await scheduler.reconcile(plan: [unsealed, kept], title: "t", body: "b") }
        try await wait { center.isHoldingAnAdd }
        #expect(center.isHoldingAnAdd, "the older reconcile never reached its first add")

        let newer = Task { await scheduler.reconcile(plan: [kept], title: "t", body: "b") }
        // Unserialised, the newer one runs to completion here. Serialised, it is waiting
        // for its turn and this simply times out.
        try await wait(upTo: .milliseconds(500)) { center.pending.contains(scheduled(kept)) }

        center.releaseHeldAdd()
        await older.value
        await newer.value

        #expect(Set(center.pending) == [scheduled(kept)],
                "the newest plan holds only `kept`; the older reconcile put back what it dropped")
        #expect(center.pending.count == 1, "a request was scheduled twice")
    }

    /// "Newest" is the order calls were *made*, not the order they reach the turnstile:
    /// `reconcile` hops off the main actor first, and a stalled hop can arrive after a
    /// newer call (M20 §4D review). The coordinator numbers each sync before it can
    /// suspend; an older number arriving last changes nothing.
    @Test func anOlderGenerationArrivingLastChangesNothing() async {
        let center = HoldingCenter()
        let scheduler = NotificationScheduler(center: center)
        let unsealed = planned(1)
        let kept = planned(2)

        await scheduler.reconcile(plan: [kept], generation: 2) { _ in ("t", "b") }
        await scheduler.reconcile(plan: [unsealed, kept], generation: 1) { _ in ("t", "b") }

        #expect(Set(center.pending) == [scheduled(kept)])
        #expect(!center.everAdded.contains(scheduled(unsealed)))
    }

    /// The coordinator's half: the number is taken first, before anything in `sync` can
    /// suspend, and handed to the scheduler. Read from source — the coordinator drives
    /// the real notification centre, which a test cannot stand in for.
    @Test func eachSyncIsNumberedBeforeItCanSuspend() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/Services/NotificationCoordinator.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let start = try #require(code.range(of: "func sync(capsules: [Capsule], in context: ModelContext"))
        let body = code[start.upperBound...]
        let numbered = try #require(body.range(of: "syncGeneration += 1"), "sync is not numbered")
        let firstAwait = try #require(body.range(of: "await "))
        #expect(numbered.lowerBound < firstAwait.lowerBound, "sync can suspend before it is numbered")
        #expect(body.contains("generation: generation"), "the number never reaches the scheduler")
    }

    /// Coalescing: a reconcile overtaken while it waited does nothing at all, so a burst
    /// of syncs costs one pass over the centre, not one per call.
    @Test func aReconcileOvertakenWhileWaitingIsSkipped() async throws {
        let center = HoldingCenter()
        let scheduler = NotificationScheduler(center: center)
        let first = planned(1)
        let onlyInTheMiddle = planned(2)
        let last = planned(3)

        center.holdNextAdd()
        let a = Task { await scheduler.reconcile(plan: [first], title: "t", body: "b") }
        try await wait { center.isHoldingAnAdd }
        let b = Task { await scheduler.reconcile(plan: [onlyInTheMiddle], title: "t", body: "b") }
        try await wait(upTo: .milliseconds(200)) { false }   // let `b` take its ticket
        let c = Task { await scheduler.reconcile(plan: [last], title: "t", body: "b") }
        try await wait(upTo: .milliseconds(200)) { false }   // and `c`

        center.releaseHeldAdd()
        await a.value
        await b.value
        await c.value

        #expect(Set(center.pending) == [scheduled(last)])
        #expect(!center.everAdded.contains(scheduled(onlyInTheMiddle)),
                "a plan already overtaken was still applied")
    }
}
