import Foundation
import SwiftData
import Testing
@testable import Soundpost

/// A far seal's server job does not outlive the seal (M23 §4F.1).
///
/// `unseal` keeps `serverJobSyncedAt` so the reconcile can cancel the job; offline that
/// cancel fails and the stamp stays, and a later `seal` (or the launch normalize) clears
/// it. Re-sealed near, nothing cancelled the old job, so the server pushed "A capsule has
/// resurfaced" on the old date. `CapsuleActions.seal` and `normalizeAndRefresh` now queue
/// a durable cancel for a capsule that owned a job, and the drain resolves a far seal's
/// entry without cancelling only once the server holds that seal (it is stamped).
@Suite(.serialized)
@MainActor
struct ResealOrphanTests {
    /// 2027-01-15 08:00 UTC = 17:00 in Tokyo.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func farSeal(offset: TimeInterval, synced: Date?, in store: CapsuleStore) throws -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try c.transition(to: .recording)
        try c.transition(to: .captured)
        c.sealUntil = now.addingTimeInterval(offset)
        c.sealTimeZoneID = tokyo.identifier
        try c.transition(to: .sealed)
        c.serverJobSyncedAt = synced
        store.context.insert(c)
        try store.save()
        return c
    }

    private func captured(in store: CapsuleStore) throws -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try c.transition(to: .recording)
        try c.transition(to: .captured)
        store.context.insert(c)
        try store.save()
        return c
    }

    private func service(_ backend: SpyDeliveryBackend) -> SealDeliveryService {
        SealDeliveryService(backend: backend, identity: StubDeliveryIdentity(key: "K"))
    }

    private func cancels(of id: UUID, _ backend: SpyDeliveryBackend) -> Int {
        backend.cancelledJobs.filter { $0.capsuleID == id }.count
    }

    /// A far seal the server owns, unsealed while offline: captured again, stamp kept.
    private func offlineUnsealed(in store: CapsuleStore) throws -> Capsule {
        let c = try farSeal(offset: 100 * day, synced: now.addingTimeInterval(-day), in: store)
        try store.commitUnseal(c)
        #expect(c.state == .captured && c.serverJobSyncedAt != nil, "the offline unseal premise does not hold")
        return c
    }

    // (1)
    @Test func aNearResealAfterAnOfflineUnsealCancelsTheOldJob() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = try offlineUnsealed(in: store)
            try CapsuleActions.seal(capsule, until: now.addingTimeInterval(12 * 3600), in: store,
                                    timeZone: tokyo, now: now)
            #expect(capsule.serverJobSyncedAt == nil)
            #expect(try #require(capsule.sealUntil).timeIntervalSince(now) <= SealDeliveryRouter.localHorizon)

            let backend = SpyDeliveryBackend(configured: true)
            await service(backend).reconcile(capsules: try store.all(), in: store.context, now: now)

            #expect(cancels(of: capsule.id, backend) == 1, "the old far job was left on the server")
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id))
        }
    }

    // (2)
    @Test func aFarResealWaitsUntilTheServerHoldsItThenCancelsIfItTurnsNear() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = try offlineUnsealed(in: store)
            try CapsuleActions.seal(capsule, until: now.addingTimeInterval(200 * day), in: store,
                                    timeZone: tokyo, now: now)
            let backend = SpyDeliveryBackend(configured: true)
            backend.shouldThrow = true                       // still offline

            await service(backend).reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id),
                    "a far seal's entry was resolved before the server held the new seal")
            #expect(cancels(of: capsule.id, backend) == 0)
            #expect(capsule.serverJobSyncedAt == nil)

            // The seal is now inside the horizon and the server answers: the old job goes.
            backend.shouldThrow = false
            let later = try #require(capsule.sealUntil).addingTimeInterval(-12 * 3600)
            await service(backend).reconcile(capsules: try store.all(), in: store.context, now: later)
            #expect(cancels(of: capsule.id, backend) == 1)
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id))
        }
    }

    /// The far re-seal's other ending: the upsert lands (replacing the old job, same
    /// capsule id) and stamps it, and only then is the queued entry resolved — with no
    /// cancel, which would take the new seal's job.
    @Test func aFarResealIsResolvedWithoutACancelOnceStamped() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = try offlineUnsealed(in: store)
            try CapsuleActions.seal(capsule, until: now.addingTimeInterval(200 * day), in: store,
                                    timeZone: tokyo, now: now)
            let backend = SpyDeliveryBackend(configured: true)
            let delivery = service(backend)

            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(capsule.serverJobSyncedAt != nil, "the new far seal was not upserted")
            await delivery.reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id))
            #expect(cancels(of: capsule.id, backend) == 0, "the new seal's job was cancelled")
        }
    }

    // (3)
    @Test(arguments: [false, true])
    func sealingACapsuleWithNoJobQueuesNothing(far: Bool) async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = try captured(in: store)
            let until = now.addingTimeInterval(far ? 200 * day : 12 * 3600)
            try CapsuleActions.seal(capsule, until: until, in: store, timeZone: tokyo, now: now)
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.isEmpty)
            let backend = SpyDeliveryBackend(configured: true)
            await service(backend).reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(backend.cancelledJobs.isEmpty, "a cancel for a capsule that never had a job")
        }
    }

    // (4a)
    @Test func aFailedSealRemovesTheEntryItAdded() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = try offlineUnsealed(in: store)
            let stamp = capsule.serverJobSyncedAt
            #expect(throws: (any Error).self) {
                try CapsuleActions.seal(capsule, until: now.addingTimeInterval(12 * 3600), in: store,
                                        timeZone: tokyo, now: now, commit: { throw CocoaError(.fileWriteUnknown) })
            }
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id))
            #expect(capsule.state == .captured && capsule.serverJobSyncedAt == stamp, "the capsule was not put back")
        }
    }

    // (4b)
    @Test func aFailedSealLeavesAnEntryQueuedBeforeIt() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let capsule = try offlineUnsealed(in: store)
            DeliveryPreferences.enqueuePendingCancel(capsule.id)     // someone else's
            #expect(throws: (any Error).self) {
                try CapsuleActions.seal(capsule, until: now.addingTimeInterval(12 * 3600), in: store,
                                        timeZone: tokyo, now: now, commit: { throw CocoaError(.fileWriteUnknown) })
            }
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id),
                    "a failed seal resolved an entry it did not add")
        }
    }

    // (5)
    @Test func aNormalizeThatMovesAStampedSealIntoTheHorizonQueuesOneCancel() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            // 23:00 in Tokyo on Jan 16, 30 h ahead (far); 09:00 that day is 16 h ahead (near).
            let stamped = try farSeal(offset: 30 * 3600, synced: now.addingTimeInterval(-day), in: store)
            let unstamped = try farSeal(offset: 30 * 3600, synced: nil, in: store)

            CapsuleActions.normalizeAndRefresh(in: store, now: now)
            #expect(try #require(stamped.sealUntil).timeIntervalSince(now) == 16 * 3600,
                    "the normalize premise does not hold")
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs == [stamped.id],
                    "\(DeliveryPreferences.pendingCancelCapsuleIDs)")

            let backend = SpyDeliveryBackend(configured: true)
            await service(backend).reconcile(capsules: try store.all(), in: store.context, now: now)
            #expect(cancels(of: stamped.id, backend) == 1)
            #expect(cancels(of: unstamped.id, backend) == 0)
        }
    }

    @Test func aFailedNormalizeSaveResolvesOnlyItsOwnEntries() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let mine = try farSeal(offset: 30 * 3600, synced: now.addingTimeInterval(-day), in: store)
            let theirs = UUID()
            DeliveryPreferences.enqueuePendingCancel(theirs)
            CapsuleActions.normalizeAndRefresh(in: store, now: now, commit: { throw CocoaError(.fileWriteUnknown) })
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(mine.id))
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(theirs))
        }
    }

    // MARK: The production paths go through these (read from source)

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func code(_ path: String) throws -> String {
        let url = repo.appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(path) is missing")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// `commitSeal(` is written to from one place only: `CapsuleActions.seal`.
    @Test func theSealWriteHasOneCallSiteInsideCapsuleActions() throws {
        var sites: [String] = []
        for folder in ["Soundpost", "SoundpostWidget"] {
            let base = Self.repo.appending(path: folder)
            let walker = try #require(FileManager.default.enumerator(atPath: base.path))
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                let code = try Self.code("\(folder)/\(relative)")
                for (n, line) in code.split(separator: "\n").enumerated()
                where line.contains("commitSeal(") && !line.contains("func commitSeal(") {
                    sites.append("\(folder)/\(relative):\(n + 1)")
                }
            }
        }
        #expect(sites.count == 1, "\(sites)")
        #expect(sites.first?.hasPrefix("Soundpost/Services/CapsuleActions.swift:") == true, "\(sites)")
    }

    /// The foreground refresh normalizes through `CapsuleActions`, and still drains a
    /// capture request before its first `await`.
    @Test func theForegroundRefreshNormalizesThroughCapsuleActions() throws {
        let content = try Self.code("Soundpost/ContentView.swift")
        let start = try #require(content.range(of: "private func refreshAndSync() async {"))
        let body = content[start.upperBound...]
        let normalize = try #require(body.range(of: "CapsuleActions.normalizeAndRefresh("),
                                     "refreshAndSync no longer normalizes through CapsuleActions")
        let drain = try #require(body.range(of: "drainCaptureRequest()"))
        let firstAwait = try #require(body.range(of: "await "))
        #expect(normalize.lowerBound < drain.lowerBound && drain.lowerBound < firstAwait.lowerBound)
        #expect(!body[..<firstAwait.lowerBound].contains("normalizeSealHours("), "the old direct call is back")
    }
}
