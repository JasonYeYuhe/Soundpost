import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// Tests for `CapsuleStore` against an in-memory SwiftData container.
///
/// `.serialized` + the single shared container in `TestSupport`: creating
/// multiple `ModelContainer`s for one model in a single process crashes the
/// runner, so all SwiftData suites share one container and reset per test.
@Suite(.serialized)
@MainActor
struct CapsuleStoreTests {
    private func makeStore() throws -> CapsuleStore {
        try TestSupport.freshStore()
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

    @Test func sealSetsStateDateAndZoneNormalizedTo9am() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let date = Date(timeIntervalSince1970: 2_000_000_000) // 12:33 JST that day
        try store.seal(capsule, until: date, timeZone: tokyo)
        #expect(capsule.state == .sealed)
        #expect(capsule.sealTimeZoneID == "Asia/Tokyo")
        // The chosen day is preserved but pinned to a humane 09:00 local (§S2).
        #expect(capsule.sealUntil == SealClock.normalize(date, in: tokyo))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tokyo
        let comps = cal.dateComponents([.hour, .minute, .second], from: capsule.sealUntil!)
        #expect(comps.hour == 9 && comps.minute == 0 && comps.second == 0)
    }

    @Test func sealNormalizesTo9amAcrossATimeZoneBoundary() throws {
        let store = try makeStore()
        // A day picked at 23:30 UTC: in Honolulu it's still the previous calendar
        // day, so the 09:00 instant must land on Honolulu's day, not UTC's.
        let picked = Date(timeIntervalSince1970: 2_000_000_000 + 41_400) // ~23:33 UTC
        for id in ["Asia/Tokyo", "Pacific/Honolulu", "Europe/London"] {
            let tz = TimeZone(identifier: id)!
            let capsule = try capture(store, name: "c-\(id)")
            try store.seal(capsule, until: picked, timeZone: tz)
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let comps = cal.dateComponents([.hour, .minute], from: capsule.sealUntil!)
            #expect(comps.hour == 9 && comps.minute == 0)
            // Same calendar day (in tz) as the picked day — only the hour moved.
            #expect(cal.isDate(capsule.sealUntil!, inSameDayAs: picked))
        }
    }

    @Test func sealClearsServerJobSyncedAtToReArm() throws {
        // Re-sealing a capsule the server already owns must clear serverJobSyncedAt
        // so the M10 reconcile re-upserts the new wall clock (§S2 P0).
        let store = try makeStore()
        let capsule = try capture(store)
        try store.seal(capsule, until: Date(timeIntervalSince1970: 5_000_000_000))
        capsule.serverJobSyncedAt = Date(timeIntervalSince1970: 1_000) // server owns it
        try store.unseal(capsule)                                       // (cancel path keeps the stamp)
        try store.seal(capsule, until: Date(timeIntervalSince1970: 5_000_000_001))
        #expect(capsule.serverJobSyncedAt == nil)
    }

    @Test func setEchoNormalizesTo9am() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let raw = Date(timeIntervalSince1970: 2_000_000_000)
        store.setEcho(capsule, at: raw)
        #expect(capsule.echoAt == SealClock.normalize(raw))
        store.setEcho(capsule, at: nil)
        #expect(capsule.echoAt == nil)
    }

    @Test func normalizeSealHoursReArmsServerOwnedSealAndIsIdempotent() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // Simulate a pre-§S2 seal: an antisocial 02:47 wall clock, server-owned.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tokyo
        let antisocial = cal.date(from: DateComponents(year: 2031, month: 6, day: 20, hour: 2, minute: 47))!
        let capsule = try capture(store)
        capsule.sealUntil = antisocial
        capsule.sealTimeZoneID = "Asia/Tokyo"
        try capsule.transition(to: .sealed)
        capsule.serverJobSyncedAt = now

        let changed = try store.normalizeSealHours(now: now)
        #expect(changed.map(\.id) == [capsule.id])
        #expect(capsule.serverJobSyncedAt == nil)           // re-arm
        let comps = cal.dateComponents([.hour, .minute, .day], from: capsule.sealUntil!)
        #expect(comps.hour == 9 && comps.minute == 0 && comps.day == 20)

        // Second pass: already at 09:00 → no change, no spurious re-arm.
        capsule.serverJobSyncedAt = now
        let again = try store.normalizeSealHours(now: now)
        #expect(again.isEmpty)
        #expect(capsule.serverJobSyncedAt == now)
    }

    @Test func normalizeSealHoursNeverMovesAFireInstantIntoThePast() throws {
        let store = try makeStore()
        let cal = Calendar.current
        // `now` is 14:00 local today; a seal due 16:00 local today is still future,
        // but normalizing to 09:00 today would land *before* now — so the guard must
        // leave it untouched (it resurfaces in-app on its date regardless). Defining
        // both times relative to the same local day makes this tz-independent.
        let now = cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
        let dueAt16 = cal.date(bySettingHour: 16, minute: 0, second: 0, of: now)!
        let capsule = try capture(store)
        capsule.sealUntil = dueAt16
        capsule.sealTimeZoneID = TimeZone.current.identifier
        try capsule.transition(to: .sealed)

        let changed = try store.normalizeSealHours(now: now)
        #expect(changed.isEmpty)
        #expect(capsule.sealUntil == dueAt16) // left untouched (09:00 today < now)
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
