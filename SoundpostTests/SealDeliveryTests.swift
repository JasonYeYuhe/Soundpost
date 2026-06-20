import Testing
import Foundation
import SwiftData
@testable import Soundpost

@Suite(.serialized)
@MainActor
struct SealDeliveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    /// An unattached sealed capsule (not inserted into any context).
    private func sealed(offset: TimeInterval, tz: String? = "Asia/Tokyo", synced: Date? = nil) throws -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try c.transition(to: .recording)
        try c.transition(to: .captured)
        c.sealUntil = now.addingTimeInterval(offset)
        c.sealTimeZoneID = tz
        try c.transition(to: .sealed)
        c.serverJobSyncedAt = synced
        return c
    }

    private func capturedWithEcho(offset: TimeInterval) -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try? c.transition(to: .recording)
        try? c.transition(to: .captured)
        c.echoAt = now.addingTimeInterval(offset)
        return c
    }

    // MARK: Router

    @Test func routerEnqueuesOnlyFarSeals() throws {
        let far = try sealed(offset: 100 * day)
        let job = SealDeliveryRouter.desiredJobs(capsules: [far], now: now)
        #expect(job.count == 1)
        #expect(job[0].capsuleID == far.id)
        #expect(job[0].kind == "seal")
        #expect(job[0].fireDate == far.sealUntil)
        #expect(job[0].timeZoneID == "Asia/Tokyo")
    }

    @Test func routerExcludesNearSealsEchoesAndUntimezoned() throws {
        let near = try sealed(offset: 60)                  // within the 24h horizon
        let echo = capturedWithEcho(offset: 100 * day)     // echoes are local-only
        let noTZ = try sealed(offset: 100 * day, tz: nil)  // missing tz → can't be DST-correct
        let jobs = SealDeliveryRouter.desiredJobs(capsules: [near, echo, noTZ], now: now)
        #expect(jobs.isEmpty)
    }

    @Test func routerHorizonBoundaryIsExclusive() throws {
        let atHorizon = try sealed(offset: SealDeliveryRouter.localHorizon)       // == H → local
        let justBeyond = try sealed(offset: SealDeliveryRouter.localHorizon + 1)  // > H → server
        #expect(SealDeliveryRouter.desiredJobs(capsules: [atHorizon], now: now).isEmpty)
        #expect(SealDeliveryRouter.desiredJobs(capsules: [justBeyond], now: now).count == 1)
    }

    // MARK: Planner drops the local backstop once the server owns it

    @Test func plannerDropsServerOwnedSeal() throws {
        let owned = try sealed(offset: 100 * day, synced: now)   // server confirmed
        let unowned = try sealed(offset: 100 * day, synced: nil) // not yet
        #expect(NotificationPlanner.plan(capsules: [owned], now: now).isEmpty)
        #expect(NotificationPlanner.plan(capsules: [unowned], now: now).count == 1)
    }

    @Test func plannerKeepsEchoEvenWhenAnotherSealIsServerOwned() throws {
        let owned = try sealed(offset: 100 * day, synced: now)
        let echo = capturedWithEcho(offset: 3 * day)
        let plan = NotificationPlanner.plan(capsules: [owned, echo], now: now)
        #expect(plan.count == 1)
        #expect(plan.first?.kind == .echo)
    }

    // MARK: Service reconcile

    @Test func reconcileUpsertsFarSignedInSealOnceThenIsIdempotent() async throws {
        let store = try TestSupport.freshStore()
        let c = try sealed(offset: 100 * day)
        store.context.insert(c)
        try store.save()
        let backend = SpyDeliveryBackend(configured: true)
        let service = SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"))

        await service.reconcile(capsules: try store.all(), now: now)
        #expect(backend.upsertedJobs.count == 1)
        #expect(backend.upsertedJobs[0].userKey == "K")
        #expect(c.serverJobSyncedAt != nil)

        // Debounced: a second reconcile with unchanged state makes no calls.
        await service.reconcile(capsules: try store.all(), now: now)
        #expect(backend.upsertedJobs.count == 1)
    }

    @Test func reconcileSkipsNearSealAndEcho() async throws {
        let store = try TestSupport.freshStore()
        let near = try sealed(offset: 60)
        let echo = capturedWithEcho(offset: 100 * day)
        store.context.insert(near)
        store.context.insert(echo)
        try store.save()
        let backend = SpyDeliveryBackend(configured: true)
        let service = SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"))

        await service.reconcile(capsules: try store.all(), now: now)
        #expect(backend.upsertedJobs.isEmpty)
        #expect(near.serverJobSyncedAt == nil)
    }

    @Test func reconcileNoServerWhenSignedOutOrUnconfigured() async throws {
        let store = try TestSupport.freshStore()
        let c = try sealed(offset: 100 * day)
        store.context.insert(c)
        try store.save()

        // Signed out (no key).
        let backend = SpyDeliveryBackend(configured: true)
        await SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: nil))
            .reconcile(capsules: try store.all(), now: now)
        #expect(backend.upsertedJobs.isEmpty)
        #expect(c.serverJobSyncedAt == nil)

        // Backend not configured.
        let stub = SpyDeliveryBackend(configured: false)
        await SealDeliveryService(backend: stub, identity: StubDeliveryIdentity(key: "K"))
            .reconcile(capsules: try store.all(), now: now)
        #expect(stub.upsertedJobs.isEmpty)
    }

    @Test func reconcileCancelsJobWhenUnsealedOrResurfaced() async throws {
        let store = try TestSupport.freshStore()
        // Was server-owned, then unsealed back to captured (no longer desired).
        let unsealed = try sealed(offset: 100 * day, synced: now)
        try unsealed.transition(to: .captured)
        unsealed.sealUntil = nil
        // Was server-owned, then resurfaced.
        let resurfaced = try sealed(offset: 100 * day, synced: now)
        try resurfaced.transition(to: .resurfaced)
        store.context.insert(unsealed)
        store.context.insert(resurfaced)
        try store.save()
        let backend = SpyDeliveryBackend(configured: true)
        let service = SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"))

        await service.reconcile(capsules: try store.all(), now: now)
        #expect(backend.cancelledJobs.count == 2)
        #expect(Set(backend.cancelledJobs.map(\.capsuleID)) == [unsealed.id, resurfaced.id])
        #expect(unsealed.serverJobSyncedAt == nil)
        #expect(resurfaced.serverJobSyncedAt == nil)
    }

    @Test func cancelJobAndDeleteAllHitBackend() async throws {
        let backend = SpyDeliveryBackend(configured: true)
        let service = SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"))
        let id = UUID()
        await service.cancelJob(capsuleID: id)
        #expect(backend.cancelledJobs.map(\.capsuleID) == [id])
        let ok = await service.deleteAllCloudData()
        #expect(ok)
        #expect(backend.deleteAllCalls == ["K"])
    }

    // MARK: Delivery-time dedup (pure helpers)

    @Test func parsesCapsuleIDFromPushUserInfo() {
        let id = UUID()
        #expect(NotificationCoordinator.capsuleID(fromPushUserInfo: ["capsule_id": id.uuidString]) == id)
        #expect(NotificationCoordinator.capsuleID(fromPushUserInfo: [:]) == nil)
        #expect(NotificationCoordinator.capsuleID(fromPushUserInfo: ["capsule_id": "nope"]) == nil)
    }

    @Test func localSealIdentifiersMatchOnlyThisCapsulesSeal() {
        let id = UUID()
        let other = UUID()
        let sealID = "capsule.\(id.uuidString)|seal|123"
        let echoID = "capsule.\(id.uuidString)|echo|123"
        let otherID = "capsule.\(other.uuidString)|seal|123"
        let foreign = "other.\(id.uuidString)|seal|1"
        let matches = NotificationCoordinator.localSealIdentifiers(
            for: id, among: [sealID, echoID, otherID, foreign])
        #expect(matches == [sealID])
    }

    // MARK: Wall-clock contract sent to the server

    @Test func wallClockStringIsTimezoneLocalAndNaive() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let comps = DateComponents(year: 2031, month: 6, day: 20, hour: 9, minute: 0, second: 0)
        let date = cal.date(from: comps)!
        #expect(SupabaseDeliveryBackend.wallClockString(date, timeZoneID: "Asia/Tokyo") == "2031-06-20T09:00:00")
        // Same instant, a different zone yields that zone's local wall clock.
        #expect(SupabaseDeliveryBackend.wallClockString(date, timeZoneID: "UTC") == "2031-06-20T00:00:00")
    }
}
