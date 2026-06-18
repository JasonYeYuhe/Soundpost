import Testing
import Foundation
import SwiftData
import AVFoundation
@testable import Soundpost

/// M9 §S2: the file→`audioData` backfill — the riskiest migration step.
///
/// We drive the migration **core** (`AudioMigrator.backfill(in:)`) synchronously
/// on the shared in-memory container's context. The production path runs the
/// same core inside the `@ModelActor`'s isolated background context; testing it
/// synchronously keeps these bodies non-suspending, so they never interleave
/// with another suite's `freshStore()` on the single shared container.
@Suite(.serialized)
@MainActor
struct AudioMigratorTests {
    private func tempStore() -> AudioStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "SoundpostMig-\(UUID().uuidString)", directoryHint: .isDirectory)
        return AudioStore(directory: dir)
    }

    private func captured(_ store: CapsuleStore, fileName: String, data: Data? = nil) throws -> Capsule {
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: fileName, audioData: data,
                               durationSeconds: 1, waveformSamples: [0.5])
        return capsule
    }

    /// A pre-M9, file-only capsule is copied into `audioData`, the blob round-
    /// trips through the player, the stale ref is cleared, and the source file
    /// is deleted (no storage doubling).
    @Test func backfillsFileOnlyCapsuleAndReclaimsSource() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        defer { try? FileManager.default.removeItem(at: audioStore.directory) }
        let fileName = try TestSupport.writeSineClip(into: audioStore)
        let capsule = try captured(store, fileName: fileName)
        try store.save()
        #expect(capsule.audioData == nil)
        #expect(audioStore.fileExists(fileName))

        AudioMigrator.backfill(in: store.context, audioStore: audioStore)

        #expect(capsule.audioData != nil)
        #expect(!(capsule.audioData?.isEmpty ?? true))
        #expect(capsule.audioFileName == nil)                       // stale ref cleared
        #expect(!audioStore.fileExists(fileName))                   // source reclaimed
        #expect((try? AVAudioPlayer(data: capsule.audioData!)) != nil) // lossless round-trip
    }

    /// Running it again does nothing further — idempotent and resumable.
    @Test func isIdempotentOnSecondRun() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        defer { try? FileManager.default.removeItem(at: audioStore.directory) }
        let fileName = try TestSupport.writeSineClip(into: audioStore)
        let capsule = try captured(store, fileName: fileName)
        try store.save()

        AudioMigrator.backfill(in: store.context, audioStore: audioStore)
        let firstData = capsule.audioData
        AudioMigrator.backfill(in: store.context, audioStore: audioStore)

        #expect(capsule.audioData == firstData)
        #expect(capsule.audioFileName == nil)
        #expect(!audioStore.fileExists(fileName))
    }

    /// A missing/unreadable source clip is logged and skipped — never fatal — and
    /// its `audioFileName` is retained so a later run can retry.
    @Test func missingSourceFileIsSkippedNotFatal() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        let capsule = try captured(store, fileName: "ghost.m4a") // no file on disk
        try store.save()

        AudioMigrator.backfill(in: store.context, audioStore: audioStore) // must not crash

        #expect(capsule.audioData == nil)                 // nothing recoverable
        #expect(capsule.audioFileName == "ghost.m4a")     // ref kept for a retry
    }

    /// A zero-byte source is treated as unrecoverable (decode fails) and skipped.
    @Test func zeroByteSourceIsSkipped() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        defer { try? FileManager.default.removeItem(at: audioStore.directory) }
        try audioStore.ensureDirectory()
        let fileName = audioStore.newFileName()
        try Data().write(to: audioStore.url(for: fileName))
        let capsule = try captured(store, fileName: fileName)
        try store.save()

        AudioMigrator.backfill(in: store.context, audioStore: audioStore)

        #expect(capsule.audioData == nil)
        #expect(capsule.audioFileName == fileName) // retained
    }

    /// A capsule captured by the M9 build already has `audioData`; its on-disk
    /// file is redundant doubling and must be reclaimed without touching the blob.
    @Test func reclaimsRedundantFileWhenDataAlreadyPresent() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        defer { try? FileManager.default.removeItem(at: audioStore.directory) }
        let fileName = try TestSupport.writeSineClip(into: audioStore)
        let data = try Data(contentsOf: audioStore.url(for: fileName))
        let capsule = try captured(store, fileName: fileName, data: data)
        try store.save()
        #expect(audioStore.fileExists(fileName))

        AudioMigrator.backfill(in: store.context, audioStore: audioStore)

        #expect(capsule.audioData == data)            // canonical blob untouched
        #expect(capsule.audioFileName == nil)          // stale ref cleared
        #expect(!audioStore.fileExists(fileName))      // doubling reclaimed
    }

    /// Multiple capsules migrate correctly across more than one batch.
    @Test func migratesMultipleAcrossBatches() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        defer { try? FileManager.default.removeItem(at: audioStore.directory) }
        var ids: [UUID] = []
        for _ in 0..<3 {
            let fileName = try TestSupport.writeSineClip(into: audioStore)
            ids.append(try captured(store, fileName: fileName).id)
        }
        try store.save()

        AudioMigrator.backfill(in: store.context, batchSize: 2, audioStore: audioStore)

        let all = try store.all()
        for id in ids {
            let c = all.first { $0.id == id }
            #expect(c?.audioData != nil)
            #expect(c?.audioFileName == nil)
        }
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: audioStore.directory.path)) ?? []
        #expect(!leftover.contains { $0.hasSuffix(".m4a") })
    }

    /// An empty store is a clean no-op.
    @Test func emptyStoreIsNoOp() throws {
        let store = try TestSupport.freshStore()
        AudioMigrator.backfill(in: store.context, audioStore: tempStore())
        #expect(try store.all().isEmpty)
    }

    /// A failed batch save must ROLL BACK its in-memory mutations and KEEP the
    /// source file — otherwise a later save could commit audioData + clear the
    /// stale ref while the .m4a survives, permanently doubling storage for a
    /// capsule that would never re-qualify as a candidate. After the failure the
    /// capsule must cleanly re-migrate on a subsequent (working) run.
    @Test func failedSaveRollsBackAndRetainsSourceForCleanRetry() throws {
        let store = try TestSupport.freshStore()
        let audioStore = tempStore()
        defer { try? FileManager.default.removeItem(at: audioStore.directory) }
        let fileName = try TestSupport.writeSineClip(into: audioStore)
        let capsule = try captured(store, fileName: fileName)
        try store.save()

        // First run: the save throws -> the batch is rolled back, source kept.
        AudioMigrator.backfill(in: store.context, audioStore: audioStore,
                               save: { _ in throw NSError(domain: "test", code: 1) })
        #expect(capsule.audioData == nil)            // mutation rolled back
        #expect(capsule.audioFileName == fileName)    // still a candidate
        #expect(audioStore.fileExists(fileName))      // source NOT deleted -> no doubling

        // Second run with the real save migrates cleanly (idempotent / resumable).
        AudioMigrator.backfill(in: store.context, audioStore: audioStore)
        #expect(capsule.audioData != nil)
        #expect(capsule.audioFileName == nil)
        #expect(!audioStore.fileExists(fileName))
    }
}
