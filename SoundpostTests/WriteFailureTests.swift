import Foundation
import SwiftData
import Testing
@testable import Soundpost

private struct SaveFailed: Error {}

/// Every user write lands, or changes nothing (M20 §4C).
///
/// Until M20 no test made a save fail, and the four writes that matter most — capture,
/// seal, unseal, delete — each reported success whatever the save did: a failed capture
/// left its row pending for the retry to commit beside a second one, a failed seal said
/// "sealed", and a failed delete removed the audio file and cancelled the push first.
///
/// Each test fails the save through the `commit` seam and then asserts **both** the
/// object in memory and what the store holds after a later, unrelated save — because
/// `rollback()` does not restore a materialised object, and the bug it hides is exactly
/// that later save committing a change the user was told had failed.
@MainActor
@Suite("A failed save changes nothing")
struct WriteFailureTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let failingCommit: () throws -> Void = { throw SaveFailed() }

    /// A captured capsule, saved, with an echo.
    private func savedCaptured(in store: CapsuleStore, echo: Date?,
                               audioFile: String = "a.m4a") throws -> Capsule {
        let capsule = store.create(createdAt: now.addingTimeInterval(-day))
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: audioFile, durationSeconds: 3,
                               waveformSamples: [0.3])
        capsule.echoAt = echo
        try store.save()
        return capsule
    }

    /// What the store holds, through a context that has never seen this capsule.
    private func held(_ id: UUID, in store: CapsuleStore) throws -> Capsule? {
        try ModelContext(store.context.container)
            .fetch(FetchDescriptor<Capsule>(predicate: #Predicate { $0.id == id })).first
    }

    private func rejectionCount(in store: CapsuleStore) throws -> Int {
        try ModelContext(store.context.container).fetchCount(FetchDescriptor<SoundRejection>())
    }

    // MARK: Capture

    @Test func aFailedCaptureSaveLeavesNoRowNoStandingAndATakeToRetry() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            let viewModel = CaptureViewModel()
            viewModel.setReviewStateForTesting(fileName: "take.m4a", duration: 4, waveform: [0.4])

            #expect(throws: SaveFailed.self) {
                try viewModel.save(using: store, commit: failingCommit)
            }

            // Nothing was recorded, so nothing may claim this install has recorded.
            #expect(!SoundAnalysisPreferences.hasRecordedHere)
            #expect(!SoundAnalysisPreferences.hasStanding)
            // The take is still on screen to try again.
            #expect(viewModel.phase == .review)
            // A later save — any save — must not commit the failed attempt's row.
            try store.save()
            #expect(try store.all().isEmpty)

            // The retry lands exactly once.
            let saved = try #require(try viewModel.save(using: store))
            #expect(try store.all().map(\.id) == [saved.id])
            #expect(SoundAnalysisPreferences.hasRecordedHere)
            #expect(SoundAnalysisPreferences.hasStanding)
        }
    }

    // MARK: Seal

    @Test func aFailedSealLeavesTheCapsuleCapturedInMemoryAndInTheStore() throws {
        let store = try TestSupport.isolatedStore()
        let echo = now.addingTimeInterval(20 * day)
        let capsule = try savedCaptured(in: store, echo: echo)

        #expect(throws: SaveFailed.self) {
            try store.commitSeal(capsule, until: now.addingTimeInterval(300 * day),
                                 timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: now,
                                 commit: failingCommit)
        }

        #expect(capsule.state == .captured)
        #expect(capsule.sealUntil == nil)
        #expect(capsule.sealTimeZoneID == nil)
        #expect(capsule.echoAt == echo, "sealing clears the echo; a failed seal must give it back")

        try store.save()
        let stored = try #require(try held(capsule.id, in: store))
        #expect(stored.state == .captured)
        #expect(stored.sealUntil == nil)
        #expect(stored.echoAt == echo)
    }

    @Test func aSuccessfulSealIsSaved() throws {
        let store = try TestSupport.isolatedStore()
        let capsule = try savedCaptured(in: store, echo: now.addingTimeInterval(20 * day))

        try store.commitSeal(capsule, until: now.addingTimeInterval(300 * day), now: now)

        let stored = try #require(try held(capsule.id, in: store))
        #expect(stored.state == .sealed)
        #expect(stored.echoAt == nil)
    }

    // MARK: Unseal

    @Test func aFailedUnsealLeavesTheCapsuleSealedInMemoryAndInTheStore() throws {
        let store = try TestSupport.isolatedStore()
        let capsule = try savedCaptured(in: store, echo: nil)
        try store.commitSeal(capsule, until: now.addingTimeInterval(300 * day),
                             timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: now)
        let synced = now
        capsule.serverJobSyncedAt = synced
        try store.save()
        let sealedUntil = capsule.sealUntil

        #expect(throws: SaveFailed.self) {
            try store.commitUnseal(capsule, commit: failingCommit)
        }

        #expect(capsule.state == .sealed)
        #expect(capsule.sealUntil == sealedUntil)
        #expect(capsule.sealTimeZoneID == "Asia/Tokyo")
        #expect(capsule.serverJobSyncedAt == synced)

        try store.save()
        let stored = try #require(try held(capsule.id, in: store))
        #expect(stored.state == .sealed)
        #expect(stored.sealUntil == sealedUntil)
        #expect(stored.sealTimeZoneID == "Asia/Tokyo")
    }

    // MARK: Delete

    /// A temporary audio directory of this test's own, never a shared parent.
    private func audioStoreWithClip() throws -> (AudioStore, String, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WriteFailureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let audio = AudioStore(directory: dir)
        try audio.ensureDirectory()
        let name = audio.newFileName()
        try Data([1, 2, 3]).write(to: audio.url(for: name))
        return (audio, name, dir)
    }

    @Test func aFailedDeleteKeepsTheCapsuleItsCorrectionsItsAudioAndItsPush() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let (audio, clip, dir) = try audioStoreWithClip()
            defer { try? FileManager.default.removeItem(at: dir) }
            let capsule = try savedCaptured(in: store, echo: nil, audioFile: clip)
            try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                        in: store.context)
            try store.save()
            var cancelled: [UUID] = []

            let deleted = CapsuleActions.delete(capsule, in: store, audioStore: audio,
                                                cancelServerJob: { cancelled.append($0) },
                                                commit: failingCommit)

            #expect(!deleted)
            #expect(audio.fileExists(clip), "the sound went before the save was known to land")
            #expect(cancelled.isEmpty, "a surviving capsule's push was cancelled")
            #expect(!DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id))
            // The pending deletes are undone: a later, unrelated save keeps both.
            try store.save()
            #expect(try held(capsule.id, in: store) != nil)
            #expect(try rejectionCount(in: store) == 1)
        }
    }

    @Test func aDeleteThatLandsRemovesTheFileAndAsksTheServerAfterwards() async throws {
        try await TestSupport.withIsolatedDeliveryPreferences {
            let store = try TestSupport.isolatedStore()
            let (audio, clip, dir) = try audioStoreWithClip()
            defer { try? FileManager.default.removeItem(at: dir) }
            let capsule = try savedCaptured(in: store, echo: nil, audioFile: clip)
            let id = capsule.id
            var cancelled: [UUID] = []
            var queuedWhenSaving = false

            // The cancel is queued *before* the save commits (§S4): a kill between the
            // save and the network call must still cancel the push on the next launch.
            let deleted = CapsuleActions.delete(
                capsule, in: store, audioStore: audio,
                cancelServerJob: { cancelled.append($0) },
                commit: {
                    queuedWhenSaving = DeliveryPreferences.pendingCancelCapsuleIDs.contains(id)
                    try store.save()
                })

            #expect(deleted)
            #expect(queuedWhenSaving, "the cancel was queued after the save — a kill in between loses it")
            #expect(try held(id, in: store) == nil)
            #expect(!audio.fileExists(clip))
            #expect(cancelled == [id])
            // Queued until the server confirms — `cancelJob` resolves it, not this.
            #expect(DeliveryPreferences.pendingCancelCapsuleIDs.contains(id))
        }
    }
}
