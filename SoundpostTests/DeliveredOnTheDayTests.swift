import Foundation
import SwiftData
import Testing
@testable import Soundpost

/// The far seal delivers on its day (M21 §4B).
///
/// Until M21 a sync planned the local notifications first and reconciled the server's
/// jobs second, and nothing re-planned after the second half. A far seal entering its
/// last 24 hours was left out of the plan (the server owned it), then the reconcile
/// cancelled its server job and handed it back to the device — so if the app was
/// opened once in that last day and not again before it was due, **neither the push
/// nor the local reminder fired**. No test ran a sync inside the horizon; every one
/// asserted after `reconcile` alone.
///
/// The "synced" stamp had the opposite problem: it was written before the server
/// answered, so any save during the request mirrored "the server owns this seal" to
/// every device, and a request that never answered left it there.
///
/// These tests drive the real `NotificationCoordinator.sync` against a stand-in
/// notification centre and a spy backend that can hold a request mid-flight.
@MainActor
@Suite("Delivered on the day")
struct DeliveredOnTheDayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func sealed(dueIn offset: TimeInterval, from origin: Date? = nil,
                        synced: Date? = nil) throws -> Capsule {
        let origin = origin ?? now
        let c = Capsule(createdAt: origin.addingTimeInterval(-day))
        try c.transition(to: .recording)
        try c.transition(to: .captured)
        c.sealUntil = origin.addingTimeInterval(offset)
        c.sealTimeZoneID = "Asia/Tokyo"
        try c.transition(to: .sealed)
        c.serverJobSyncedAt = synced
        return c
    }

    private func echoing(in offset: TimeInterval) throws -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try c.transition(to: .recording)
        try c.transition(to: .captured)
        c.echoAt = now.addingTimeInterval(offset)
        return c
    }

    private func hasRequest(for id: UUID, in center: HoldingCenter) -> Bool {
        center.pending.contains { NotificationScheduler.capsuleID(fromIdentifier: $0) == id }
    }

    /// Poll until `condition` holds, or give up after `limit` — never a fixed sleep.
    ///
    /// The ceiling is generous on purpose: every `@MainActor` suite shares the main
    /// actor, so in a full run a sync can take seconds to reach the server call — 2 s was
    /// too short once, and 30 s once on a machine whose other work held its load average
    /// at 46 on 10 cores (M21 §13 S6). It costs nothing when the condition holds sooner.
    private func wait(upTo limit: Duration = .seconds(120), until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func service(_ backend: SpyDeliveryBackend) -> SealDeliveryService {
        SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"), isOptedOut: { false })
    }

    // MARK: The headline: the last day

    /// The exact sequence: a far seal the server owns, the app opened once 23 hours
    /// before it is due, and never again. After that ONE sync a local request for it
    /// must be pending — the server job is gone, so nothing else will fire.
    @Test func aSealOpenedOnItsLastDayStillHasAReminderAfterThatOneSync() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 23 * hour, synced: now.addingTimeInterval(-30 * day))
            store.context.insert(seal)
            try store.save()
            let center = HoldingCenter()
            let backend = SpyDeliveryBackend()
            let coordinator = NotificationCoordinator(center: center, delivery: service(backend))

            await coordinator.sync(capsules: try store.all(), in: store.context, now: now)

            #expect(backend.cancelledJobs.map(\.capsuleID) == [seal.id], "the server job was not handed back")
            #expect(seal.serverJobSyncedAt == nil)
            #expect(hasRequest(for: seal.id, in: center),
                    "after the one sync in its last day, nothing will remind anyone of this seal")
        }
    }

    /// The other direction, same cause: the sync that hands a far seal to the server
    /// must also take its local request away, or both fire on the day.
    @Test func aSealTheServerTookIsNotAlsoScheduledHere() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let center = HoldingCenter()
            let backend = SpyDeliveryBackend()
            let coordinator = NotificationCoordinator(center: center, delivery: service(backend))

            await coordinator.sync(capsules: try store.all(), in: store.context, now: now)

            #expect(backend.upsertedJobs.map(\.job.capsuleID) == [seal.id])
            #expect(seal.serverJobSyncedAt == now)
            #expect(!hasRequest(for: seal.id, in: center),
                    "the push and the local reminder would both fire on the day")
        }
    }

    // MARK: The stamp is the server's answer, not the question

    /// A request that never answers — the app killed mid-flight, a dead network. A save
    /// during it (autosave, any user write) must not publish a claim: CloudKit would
    /// mirror it, and every device would drop its local reminder for a job the server
    /// may never have created. After a relaunch the job is asked for again.
    @Test func aRequestThatNeverAnswersClaimsNothing() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let id = seal.id
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let first = service(backend)
            let capsules = try store.all()
            let killed = Task { await first.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")

            try store.save()   // a user write or autosave, mid-request

            // What the store now holds is what CloudKit would mirror to every device.
            let relaunch = ModelContext(store.context.container)
            let mirrored = try #require(
                try relaunch.fetch(FetchDescriptor<Capsule>(predicate: #Predicate { $0.id == id })).first)
            #expect(mirrored.serverJobSyncedAt == nil, "a claim was saved before the server answered")
            #expect(NotificationPlanner.plan(capsules: [mirrored], now: now).map(\.capsuleID) == [id],
                    "every device would have dropped its local reminder")

            // The relaunched app knows nothing of the lost request, and asks again.
            await service(backend).reconcile(capsules: try relaunch.fetch(FetchDescriptor<Capsule>()),
                                             in: relaunch, now: now)
            #expect(backend.upsertedJobs.count == 2, "the job is never asked for again")

            backend.releaseHeld(throwing: DeliveryTestError.boom)
            _ = await killed.value
        }
    }

    enum Change: String, CaseIterable, Sendable {
        case nothing, resealedToAnotherDay, unsealed, broughtInsideTheHorizon, deleted
    }

    /// Whatever happened while the server was answering, a fresh look at the store
    /// decides — one case per row of the plan's table (§4B).
    @Test(arguments: Change.allCases)
    func whatTheStoreHoldsWhenTheServerAnswersDecides(_ change: Change) async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let id = seal.id
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let delivery = service(backend)
            let capsules = try store.all()
            let reconcile = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")

            switch change {
            case .nothing: break
            case .resealedToAnotherDay: seal.sealUntil = now.addingTimeInterval(200 * day)
            case .unsealed: try store.unseal(seal)
            case .broughtInsideTheHorizon: seal.sealUntil = now.addingTimeInterval(12 * hour)
            case .deleted: store.context.delete(seal)
            }
            try store.save()
            // The sync that change starts runs now, while the request is still out — and
            // must leave the in-flight capsule alone.
            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(backend.upsertedJobs.count == 1, "a second request went out for a capsule in flight")
            backend.releaseHeld()
            _ = await reconcile.value

            switch change {
            case .nothing:
                #expect(seal.serverJobSyncedAt == now)
                #expect(backend.cancelledJobs.isEmpty)
            case .resealedToAnotherDay:
                // Sent again at once: the re-seal's own sync skipped it (in flight), so
                // "the next reconcile" might be days away, and the server would push on
                // the old day meanwhile (review, S1).
                #expect(backend.upsertedJobs.map(\.job.fireDate)
                        == [now.addingTimeInterval(100 * day), now.addingTimeInterval(200 * day)],
                        "the server was left holding the old day")
                #expect(backend.cancelledJobs.isEmpty, "the same row is re-armed by the upsert")
                #expect(seal.serverJobSyncedAt == now)
            case .unsealed, .broughtInsideTheHorizon:
                #expect(seal.serverJobSyncedAt == nil)
                #expect(backend.cancelledJobs.map(\.capsuleID) == [id],
                        "a job nothing will ever cancel stays on the server")
                #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(id))
            case .deleted:
                #expect(backend.cancelledJobs.map(\.capsuleID) == [id],
                        "the server would push for a capsule the user deleted")
                #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(id))
            }
        }
    }

    /// "Delete my cloud data" landing while an upsert is out: Settings purges the server,
    /// turns delivery off and clears every stamp. The late answer must not write one
    /// back — no device would then schedule a local reminder, and an opted-out device
    /// never reconciles that seal again (review, S1).
    @Test func aCloudDeleteDuringAnUpsertLeavesNoStampBehind() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            // The production opt-out read, on this test's own preferences.
            let delivery = SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"))
            let capsules = try store.all()
            let reconcile = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")

            DeliveryPreferences.cloudOptedOut = true        // what Settings does once the purge lands
            seal.serverJobSyncedAt = nil
            try store.save()
            backend.releaseHeld()
            _ = await reconcile.value

            #expect(seal.serverJobSyncedAt == nil, "a stamp came back after the cloud data was deleted")
            #expect(NotificationPlanner.plan(capsules: [seal], now: now).map(\.capsuleID) == [seal.id])
        }
    }

    /// The job sent is the one the store holds when it is sent, not the snapshot's: the
    /// loop awaits the network once per capsule, and a later capsule can be re-sealed
    /// while an earlier one's request is out.
    @Test func everyUpsertCarriesWhatTheStoreHoldsWhenItIsSent() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let first = try sealed(dueIn: 100 * day)
            let second = try sealed(dueIn: 150 * day)
            store.context.insert(first)
            store.context.insert(second)
            try store.save()
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let delivery = service(backend)
            let capsules = try store.all()
            let reconcile = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")

            let held = try #require(backend.upsertedJobs.first?.job.capsuleID)
            let later = held == first.id ? second : first
            later.sealUntil = now.addingTimeInterval(300 * day)
            try store.save()
            backend.releaseHeld()
            _ = await reconcile.value

            #expect(backend.upsertedJobs.filter { $0.job.capsuleID == later.id }.map(\.job.fireDate)
                    == [now.addingTimeInterval(300 * day)],
                    "the later capsule was first sent with the day the snapshot held")
            #expect(later.serverJobSyncedAt == now)
        }
    }

    /// The server accepted the job, but the store cannot be read to confirm it: nothing
    /// records that the server holds it, so its cancel is queued. The drain lets it be
    /// if the capsule is still the same far seal, and cancels it if not.
    @Test func aJobTheStoreCannotConfirmIsQueuedForItsCancel() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let delivery = service(backend)
            let capsules = try store.all()
            let reconcile = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")
            delivery.unreadableForTesting = [seal.id]
            backend.releaseHeld()
            _ = await reconcile.value
            #expect(seal.serverJobSyncedAt == nil)
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(seal.id),
                    "the server holds a job nothing records")

            // The store answers again; the capsule was unsealed meanwhile.
            delivery.unreadableForTesting = []
            try store.unseal(seal)
            try store.save()
            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(backend.cancelledJobs.map(\.capsuleID) == [seal.id])
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(seal.id))
        }
    }

    /// A queued cancel already on its way is not sent again by an overlapping reconcile.
    @Test func aQueuedCancelInFlightIsNotSentTwice() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let gone = UUID()
            DeliveryPreferences.enqueuePendingCancel(gone)
            let backend = SpyDeliveryBackend()
            backend.holdNextCancel()
            let delivery = service(backend)
            let first = Task { await delivery.reconcile(capsules: [], in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the cancel was never reached")

            await delivery.reconcile(capsules: [], in: store.context, now: now)
            #expect(backend.cancelledJobs.count == 1, "a queued cancel went out twice")

            backend.releaseHeld()
            _ = await first.value
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(gone))
        }
    }

    /// A failed delete takes back only the queue entry it added. One queued before it —
    /// a take-back whose own cancel failed — must survive, or that job stays on the
    /// server for good.
    @Test func aFailedDeleteLeavesACancelSomeoneElseQueued() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = store.create(createdAt: now)
            try store.save()
            DeliveryPreferences.enqueuePendingCancel(capsule.id)

            let deleted = CapsuleActions.delete(capsule, in: store, cancelServerJob: { _ in },
                                                commit: { throw DeliveryTestError.boom })

            #expect(!deleted)
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id),
                    "the failed delete resolved a cancel it did not queue")
        }
    }

    /// The cancel taken back after an upsert is queued before it is sent, so a failed
    /// request is retried by the next reconcile's drain — which must now cancel a
    /// capsule that is still stored but no longer a far seal (it was not stamped, so
    /// the diff cannot see it).
    @Test func aFailedTakeBackIsRetriedByTheNextReconcile() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let delivery = service(backend)
            let capsules = try store.all()
            let reconcile = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")
            try store.unseal(seal)
            try store.save()
            backend.shouldThrow = true          // the take-back fails…
            backend.releaseHeld()
            _ = await reconcile.value
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(seal.id), "the take-back was not queued")

            backend.shouldThrow = false         // …and the next reconcile sends it
            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(backend.cancelledJobs.map(\.capsuleID) == [seal.id])
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(seal.id))
        }
    }

    /// "Still a far seal" is judged at the reconcile's `now`, not the wall clock's: a
    /// reconcile planned for a moment a year from today, holding a seal due 12 hours
    /// after it, must take that seal's job back.
    @Test func theDrainJudgesAtTheReconcilesOwnMoment() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let later = Date.now.addingTimeInterval(365 * day)
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 12 * hour, from: later)
            store.context.insert(seal)
            try store.save()
            DeliveryPreferences.enqueuePendingCancel(seal.id)
            let backend = SpyDeliveryBackend()

            await service(backend).reconcile(capsules: try store.all(), in: store.context, now: later)

            #expect(backend.cancelledJobs.map(\.capsuleID) == [seal.id],
                    "judged against the wall clock, the seal still looked far and its job was kept")
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(seal.id))
        }
    }

    // MARK: One request per capsule at a time, in either direction

    @Test func aSecondReconcileDuringACancelSendsNoSecondCancel() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 23 * hour, synced: now.addingTimeInterval(-day))
            store.context.insert(seal)
            try store.save()
            let backend = SpyDeliveryBackend()
            backend.holdNextCancel()
            let delivery = service(backend)
            let capsules = try store.all()
            let first = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the cancel was never reached")

            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(backend.cancelledJobs.count == 1, "a second cancel went out while the first was in flight")

            backend.releaseHeld()
            _ = await first.value
            #expect(backend.cancelledJobs.count == 1)
            #expect(seal.serverJobSyncedAt == nil)
        }
    }

    @Test func aSecondReconcileDuringAnUpsertSendsNoSecondUpsert() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let delivery = service(backend)
            let capsules = try store.all()
            let first = Task { await delivery.reconcile(capsules: capsules, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "the upsert was never reached")

            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(backend.upsertedJobs.count == 1, "a second upsert went out while the first was in flight")

            backend.releaseHeld()
            _ = await first.value
            #expect(seal.serverJobSyncedAt == now)
        }
    }

    // MARK: The re-plan reads the store, under a new number

    /// Sync A waits on the server; meanwhile a capture is saved and its own sync runs.
    /// A's re-plan must start from what the store holds *now* — the capture included —
    /// and must win over B's plan, which still held A's seal locally.
    @Test func theReplanAfterTheServerAnswersSeesWhatChangedMeanwhile() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            store.context.insert(seal)
            try store.save()
            let center = HoldingCenter()
            let backend = SpyDeliveryBackend()
            backend.holdNextUpsert()
            let coordinator = NotificationCoordinator(center: center, delivery: service(backend))
            let before = try store.all()
            let a = Task { await coordinator.sync(capsules: before, in: store.context, now: now) }
            try await wait { backend.isHolding }
            try #require(backend.isHolding, "sync A never reached the server")

            let capture = try echoing(in: 3 * day)   // saved while A waits
            store.context.insert(capture)
            try store.save()
            await coordinator.sync(capsules: try store.all(), in: store.context, now: now)
            #expect(hasRequest(for: capture.id, in: center))

            backend.releaseHeld()
            await a.value

            #expect(hasRequest(for: capture.id, in: center),
                    "A re-planned from the array it took before the wait and dropped the capture's echo")
            #expect(!hasRequest(for: seal.id, in: center),
                    "the server owns the seal, but B's local request for it survived A's re-plan")
            #expect(seal.serverJobSyncedAt == now)
        }
    }

    /// If the store cannot be re-read, the re-plan is abandoned: planning from nothing
    /// would remove every pending request.
    @Test func aReplanThatCannotReadTheStoreChangesNothing() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let seal = try sealed(dueIn: 100 * day)
            let echo = try echoing(in: 3 * day)
            store.context.insert(seal)
            store.context.insert(echo)
            try store.save()
            let center = HoldingCenter()
            let backend = SpyDeliveryBackend()
            let coordinator = NotificationCoordinator(center: center, delivery: service(backend))
            coordinator.fetchCapsulesForReplan = { _ in throw DeliveryTestError.boom }

            await coordinator.sync(capsules: try store.all(), in: store.context, now: now)

            #expect(seal.serverJobSyncedAt == now, "the delivery change this test needs did not happen")
            #expect(hasRequest(for: echo.id, in: center),
                    "a failed re-read planned nothing and removed every pending request")
        }
    }

    // MARK: Token handoff

    /// The APNs token callbacks find the registrar through a static the app sets. Set in
    /// a view's `.task`, a token arriving before that task ran was dropped for the
    /// launch; set in `SoundpostApp.init`, it is there before any scene connects.
    @Test func theTokenHandoffIsSetBeforeAnySceneConnects() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/SoundpostApp.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let initStart = try #require(code.range(of: "init() {"))
        let bodyStart = try #require(code.range(of: "var body: some Scene"))
        let initBody = code[initStart.upperBound..<bodyStart.lowerBound]
        #expect(initBody.contains("SoundpostAppDelegate.registrar = "), "the registrar is not handed over in init")
        #expect(code.components(separatedBy: "SoundpostAppDelegate.registrar = ").count == 2,
                "the registrar is handed over somewhere besides init")
    }
}
