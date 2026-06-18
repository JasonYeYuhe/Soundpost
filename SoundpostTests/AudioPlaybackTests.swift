import Testing
import Foundation
@testable import Soundpost

/// M9 §S1: dual-read playback. A capsule's audio is read from the canonical
/// `audioData` blob when present, and from the legacy on-disk file otherwise, so
/// playback works for both new (durable) and pre-backfill capsules. We test the
/// pure `audioSource` precedence — actually starting `AVAudioPlayer` needs real
/// encoded audio and a device, which unit tests can't provide headlessly.
@MainActor
struct AudioPlaybackTests {
    private func captured() throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        return capsule
    }

    @Test func prefersAudioDataWhenPresent() throws {
        let capsule = try captured()
        capsule.audioData = Data([1, 2, 3])
        #expect(capsule.audioSource == .data)
    }

    @Test func fallsBackToFileWhenOnlyFileNamePresent() throws {
        let capsule = try captured()
        capsule.audioFileName = "legacy.m4a"
        #expect(capsule.audioSource == .file("legacy.m4a"))
    }

    @Test func dataWinsWhenBothPresent() throws {
        // A new capsule keeps its file as a fallback until the backfill reclaims
        // it; playback must still take the durable data path, never the file.
        let capsule = try captured()
        capsule.audioFileName = "redundant.m4a"
        capsule.audioData = Data([9, 9, 9])
        #expect(capsule.audioSource == .data)
    }

    @Test func noneWhenNeitherPresent() throws {
        let capsule = try captured()
        #expect(capsule.audioSource == .none)
    }

    /// New capsules saved through the capture flow populate `audioData` from the
    /// recorded file, so they are durable (and CloudKit-mirrorable) immediately.
    @Test func savedCapsulePopulatesAudioDataFromRecordedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "SoundpostTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let audioStore = AudioStore(directory: dir)
        try audioStore.ensureDirectory()
        let fileName = audioStore.newFileName()
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try bytes.write(to: audioStore.url(for: fileName))

        let viewModel = CaptureViewModel(audioStore: audioStore)
        viewModel.setReviewStateForTesting(fileName: fileName, duration: 5, waveform: [0.4])
        let store = try TestSupport.freshStore()
        let capsule = try viewModel.save(using: store)

        #expect(capsule?.audioData == bytes)        // canonical blob populated
        #expect(capsule?.audioFileName == fileName) // file kept as fallback for now
        #expect(capsule?.audioSource == .data)

        try? FileManager.default.removeItem(at: dir)
    }
}
