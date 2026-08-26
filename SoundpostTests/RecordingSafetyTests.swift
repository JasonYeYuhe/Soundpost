import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M17 §S0 — a recording in progress must survive the ways it used to be destroyed.
///
/// **No test here starts a real recording.** Doing so would measure the simulator's
/// audio stack rather than this code (two suites are already documented as failing
/// locally and green on CI for exactly that reason, M16 §13B). The properties that
/// matter — that the discard path *reaches* `AudioRecorder.cancel()`, that `cancel()`
/// closes the session down, and that "is there something to lose" is answered for
/// review as well as for recording — all belong to the state machine.
///
/// **What is NOT covered here, stated rather than implied:** the sheet's
/// `interactiveDismissDisabled`. This project has no UI-test target, so that line is
/// verified by hand in the simulator and nowhere else.
@MainActor
struct RecordingSafetyTests {

    /// Each test gets its own directory: `FileManager.temporaryDirectory` is shared
    /// with every other suite and Swift Testing runs them concurrently.
    private func makeStore() throws -> (AudioStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "SoundpostRecordingSafety-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = AudioStore(directory: dir)
        try store.ensureDirectory()
        return (store, dir)
    }

    private func plantClip(in store: AudioStore) throws -> String {
        let name = store.newFileName()
        try Data([0, 1, 2]).write(to: store.url(for: name))
        return name
    }

    // MARK: cancel() — the method that existed with no callers

    @Test func cancelStopsTheTakeReleasesItsClipAndClosesTheSession() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = try plantClip(in: audioStore)

        let recorder = AudioRecorder(store: audioStore)
        recorder.beginRecordingForTesting(fileName: name)
        #expect(recorder.state == .recording)
        #expect(recorder.isMeteringForTesting)

        recorder.cancel()

        #expect(recorder.state == .idle)
        #expect(recorder.currentFileName == nil)
        // The meter timer is invalidated only by `finishSession()`, which is also
        // the only place the audio session is deactivated. Its death is how a test
        // sees that the take was really closed down rather than merely re-flagged.
        #expect(!recorder.isMeteringForTesting)
        #expect(!audioStore.fileExists(name))
    }

    // MARK: the discard path

    @Test func discardingMidTakeStopsTheRecorderAndRemovesTheClip() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = try plantClip(in: audioStore)

        let viewModel = CaptureViewModel(audioStore: audioStore)
        viewModel.beginRecordingForTesting(fileName: name)

        viewModel.discard()

        // The view model's own `fileName` is nil during `.recording` — it is assigned
        // in `handleFinishedRecording` — so nothing here can delete the clip except
        // the recorder. That is precisely why the leak existed.
        #expect(viewModel.recorder.state == .idle)
        #expect(!viewModel.recorder.isMeteringForTesting)
        #expect(!audioStore.fileExists(name))
        #expect(viewModel.phase == .idle)
    }

    @Test func discardingAReviewedTakeStillRemovesItsClip() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = try plantClip(in: audioStore)

        let viewModel = CaptureViewModel(audioStore: audioStore)
        viewModel.setReviewStateForTesting(fileName: name, duration: 4, waveform: [0.3])

        viewModel.discard()

        #expect(!audioStore.fileExists(name))
        #expect(viewModel.phase == .idle)
    }

    // MARK: what counts as something to lose

    @Test func anIdleSheetHasNothingToLose() {
        #expect(!CaptureViewModel().hasUnsavedTake)
    }

    @Test func aTakeInFlightIsSomethingToLose() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let viewModel = CaptureViewModel(audioStore: audioStore)
        viewModel.beginRecordingForTesting(fileName: try plantClip(in: audioStore))
        #expect(viewModel.hasUnsavedTake)
    }

    /// The case a `phase == .recording` rule would get wrong: the clip is on disk and
    /// no `Capsule` row exists yet, so a sheet dismissed in review loses just as much.
    @Test func aReviewedButUnsavedTakeIsStillSomethingToLose() {
        let viewModel = CaptureViewModel()
        viewModel.finishRecordingForTesting(fileName: "keep.m4a", duration: 5)
        #expect(viewModel.phase == .review)
        #expect(viewModel.hasUnsavedTake)
    }

    @Test func savingLeavesNothingToLose() throws {
        let store = try TestSupport.freshStore()
        let viewModel = CaptureViewModel()
        viewModel.setReviewStateForTesting(fileName: "saved.m4a", duration: 3, waveform: [0.4])
        _ = try viewModel.save(using: store)
        #expect(!viewModel.hasUnsavedTake)
    }
}

/// M17 §4E — the leak is *counted*, never swept.
///
/// The audit deliberately starts from the directory and asks the capsule rows about
/// it. Every pre-existing check runs the other way (`AudioMigrator` fetches rows and
/// filters `audioFileName != nil`; the storage footer sums `durationSeconds`), which
/// is why none of them could ever fail for a file no row names — the M15 §11P shape.
@MainActor
struct AudioOrphanAuditTests {

    private func makeStore() throws -> (AudioStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "SoundpostOrphanAudit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = AudioStore(directory: dir)
        try store.ensureDirectory()
        return (store, dir)
    }

    @Test func anUnreferencedFileIsAnOrphan() {
        #expect(AudioOrphanAudit.orphans(files: ["a.m4a", "b.m4a"], referenced: ["b.m4a"]) == ["a.m4a"])
    }

    @Test func aReferencedFileIsNotAnOrphan() {
        #expect(AudioOrphanAudit.orphans(files: ["b.m4a"], referenced: ["b.m4a"]).isEmpty)
    }

    @Test func aClipNoCapsuleReferencesIsCounted() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capsuleStore = try TestSupport.freshStore()

        let kept = audioStore.newFileName()
        try Data([0, 1, 2]).write(to: audioStore.url(for: kept))
        let capsule = capsuleStore.create()
        try capsuleStore.markRecording(capsule)
        try capsuleStore.markCaptured(capsule, audioFileName: kept, audioData: nil,
                                      durationSeconds: 3, waveformSamples: [0.2])
        try capsuleStore.save()

        // The debris a mid-take dismissal used to leave: a clip whose capsule row was
        // never inserted, because the row is only created at save.
        let stranded = audioStore.newFileName()
        try Data([3, 4, 5]).write(to: audioStore.url(for: stranded))

        let count = AudioOrphanAudit.count(in: capsuleStore.context, audioStore: audioStore)

        #expect(count.files == 2)
        #expect(count.orphans == 1)
    }

    @Test func aLibraryWhoseClipsAreAllReferencedReportsNothing() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capsuleStore = try TestSupport.freshStore()

        let kept = audioStore.newFileName()
        try Data([0, 1, 2]).write(to: audioStore.url(for: kept))
        let capsule = capsuleStore.create()
        try capsuleStore.markRecording(capsule)
        try capsuleStore.markCaptured(capsule, audioFileName: kept, audioData: nil,
                                      durationSeconds: 3, waveformSamples: [0.2])
        try capsuleStore.save()

        let count = AudioOrphanAudit.count(in: capsuleStore.context, audioStore: audioStore)

        #expect(count.files == 1)
        #expect(count.orphans == 0)
    }

    /// **The §4E guard.** The audit must never remove a file, because the set it
    /// computes contains the take being recorded right now — the clip exists from
    /// record *start*, the `Capsule` row only from *save*. A sweep on this rule
    /// deletes a live recording out from under `AVAudioRecorder`, and this assertion
    /// is what a future implementer has to consciously delete to do it.
    @Test func theAuditDeletesNothing() throws {
        let (audioStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capsuleStore = try TestSupport.freshStore()

        let inFlight = audioStore.newFileName()   // stands in for a take in progress
        try Data([0, 1, 2]).write(to: audioStore.url(for: inFlight))

        _ = AudioOrphanAudit.count(in: capsuleStore.context, audioStore: audioStore)
        AudioOrphanAudit.report(in: capsuleStore.context, audioStore: audioStore)

        #expect(audioStore.fileExists(inFlight))
    }
}
