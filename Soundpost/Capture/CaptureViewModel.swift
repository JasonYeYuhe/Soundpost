import Foundation
import Observation

/// Drives the capture flow: record → review (mood / note / place) → save.
/// Owns the audio services; persistence is handed in at save time so this stays
/// testable with an in-memory `CapsuleStore`.
@MainActor
@Observable
final class CaptureViewModel {
    enum Phase: Equatable { case idle, recording, review }

    private(set) var phase: Phase = .idle
    var permissionDenied = false

    // Produced by recording.
    private(set) var fileName: String?
    private(set) var duration: TimeInterval = 0
    private(set) var waveform: [Float] = []

    // Review fields, edited by the user.
    var mood: Mood?
    var note: String = ""
    private(set) var place: Place?
    var includePlace = false
    private(set) var isFetchingPlace = false

    let recorder: AudioRecorder
    let player: AudioPlayer
    private let audioStore: AudioStore
    private let location: LocationProvider
    private let waveformBuckets: Int

    init(audioStore: AudioStore = AudioStore(),
         maxDuration: TimeInterval = 60,
         waveformBuckets: Int = 56) {
        self.audioStore = audioStore
        self.recorder = AudioRecorder(store: audioStore, maxDuration: maxDuration)
        self.player = AudioPlayer(store: audioStore)
        self.location = LocationProvider()
        self.waveformBuckets = waveformBuckets
    }

    // MARK: Recording

    func startRecording() async {
        guard await AudioRecorder.requestPermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        do {
            try recorder.start()
            phase = .recording
        } catch {
            phase = .idle
        }
    }

    func stopRecording() {
        guard let result = recorder.stop() else {
            phase = .idle
            return
        }
        fileName = result.fileName
        duration = result.duration
        waveform = (try? WaveformExtractor.samples(
            from: audioStore.url(for: result.fileName),
            buckets: waveformBuckets
        )) ?? []
        phase = .review
    }

    func discard() {
        player.stop()
        if let fileName { try? audioStore.delete(fileName) }
        reset()
    }

    // MARK: Review

    func togglePlayback() {
        guard let fileName else { return }
        switch player.state {
        case .idle: try? player.play(fileName: fileName)
        case .playing: player.pause()
        case .paused: player.resume()
        }
    }

    func fetchPlace() async {
        isFetchingPlace = true
        let resolved = await location.requestPlace()
        isFetchingPlace = false
        place = resolved
        includePlace = (resolved != nil)
    }

    func clearPlace() {
        place = nil
        includePlace = false
    }

    /// Persist the reviewed recording as a `Capsule`. Returns it, or nil if
    /// there's nothing recorded. Leaves the file in place (now owned by the capsule).
    @discardableResult
    func save(using store: CapsuleStore) throws -> Capsule? {
        guard let fileName else { return nil }
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(
            capsule,
            audioFileName: fileName,
            durationSeconds: duration,
            waveformSamples: waveform
        )
        capsule.mood = mood
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        capsule.note = trimmed.isEmpty ? nil : trimmed
        capsule.place = includePlace ? place : nil
        try store.save()
        reset(deleteFile: false)
        return capsule
    }

    private func reset(deleteFile: Bool = true) {
        player.stop()
        if deleteFile, let fileName { try? audioStore.delete(fileName) }
        fileName = nil
        duration = 0
        waveform = []
        mood = nil
        note = ""
        place = nil
        includePlace = false
        phase = .idle
    }
}

#if DEBUG
extension CaptureViewModel {
    /// Test seam: inject a "recorded" clip so `save()` can be exercised without
    /// touching the microphone. Same-file extension so it can set private state.
    func setReviewStateForTesting(fileName: String, duration: TimeInterval, waveform: [Float]) {
        self.fileName = fileName
        self.duration = duration
        self.waveform = waveform
        self.phase = .review
    }
}
#endif
