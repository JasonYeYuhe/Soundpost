import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// Tests for `CapsuleStore` against an in-memory SwiftData container.
///
/// `.serialized`: each test spins up its own `ModelContainer`, and creating
/// several SwiftData containers concurrently (Swift Testing's default parallel
/// execution) crashes the test process — so run this suite one test at a time.
@Suite(.serialized)
@MainActor
struct CapsuleStoreTests {
    /// One in-memory container for the whole test process. Creating multiple
    /// SwiftData containers for the same model in a single process is unstable
    /// (it crashes the runner), so the serialized suite shares this one and each
    /// test starts from a clean slate via `makeStore()`.
    static let sharedContainer: ModelContainer = {
        try! ModelContainer(
            for: Capsule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private func makeStore() throws -> CapsuleStore {
        let context = ModelContext(Self.sharedContainer)
        try context.delete(model: Capsule.self) // isolate from prior tests
        try context.save()
        return CapsuleStore(context: context)
    }

    /// Drive a capsule from draft to captured (the common test setup).
    private func capture(_ store: CapsuleStore, name: String = "clip.m4a") throws -> Capsule {
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: name, durationSeconds: 5, waveformSamples: [0.1, 0.8, 0.3])
        return capsule
    }

    @Test func createInsertsAndPersists() throws {
        let store = try makeStore()
        _ = store.create()
        try store.save()
        #expect(try store.all().count == 1)
    }

    @Test func markCapturedStoresAudioMetadata() throws {
        let store = try makeStore()
        let capsule = try capture(store, name: "memo.m4a")
        #expect(capsule.state == .captured)
        #expect(capsule.audioFileName == "memo.m4a")
        #expect(capsule.durationSeconds == 5)
        #expect(capsule.waveformSamples == [0.1, 0.8, 0.3])
    }

    @Test func sealSetsStateDateAndZone() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        try store.seal(capsule, until: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(capsule.state == .sealed)
        #expect(capsule.sealUntil == date)
        #expect(capsule.sealTimeZoneID == "Asia/Tokyo")
    }

    @Test func unsealClearsSealMetadata() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        try store.seal(capsule, until: Date(timeIntervalSince1970: 5_000_000_000))
        try store.unseal(capsule)
        #expect(capsule.state == .captured)
        #expect(capsule.sealUntil == nil)
        #expect(capsule.sealTimeZoneID == nil)
    }

    @Test func refreshDueSealsFlipsOnlyDueOnes() throws {
        let store = try makeStore()
        let due = try capture(store, name: "due")
        try store.seal(due, until: Date(timeIntervalSince1970: 1_000))
        let notDue = try capture(store, name: "notDue")
        try store.seal(notDue, until: Date(timeIntervalSince1970: 5_000_000_000))

        let changed = try store.refreshDueSeals(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(changed.count == 1)
        #expect(due.state == .resurfaced)
        #expect(notDue.state == .sealed)
    }

    @Test func sealedCapsulesReturnsOnlySealed() throws {
        let store = try makeStore()
        let sealed = try capture(store)
        try store.seal(sealed, until: Date(timeIntervalSince1970: 5_000_000_000))
        _ = try capture(store) // captured, not sealed
        #expect(try store.sealedCapsules().count == 1)
    }

    @Test func deleteRemoves() throws {
        let store = try makeStore()
        let capsule = store.create()
        try store.save()
        store.delete(capsule)
        try store.save()
        #expect(try store.all().isEmpty)
    }

    @Test func planFromStoreSelectsSealedFuture() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        try store.seal(capsule, until: Date(timeIntervalSince1970: 5_000_000_000))
        let plan = NotificationPlanner.plan(
            capsules: try store.all(),
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(plan.count == 1)
        #expect(plan.first?.capsuleID == capsule.id)
    }
}
