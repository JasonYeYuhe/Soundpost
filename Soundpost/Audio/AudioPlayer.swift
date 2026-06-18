import Foundation
import AVFoundation
import Observation

/// Plays back a capsule's audio clip, exposing progress for the card UI.
@MainActor
@Observable
final class AudioPlayer: NSObject {
    enum State: Equatable { case idle, playing, paused }

    enum PlayerError: Error { case couldNotStart }

    private(set) var state: State = .idle
    /// Playback progress, 0...1.
    private(set) var progress: Double = 0

    private let store: AudioStore
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(store: AudioStore = AudioStore()) {
        self.store = store
        super.init()
    }

    /// Play a capsule, preferring its durable `audioData` blob and falling back
    /// to the legacy on-disk file for capsules captured before the M9 backfill.
    /// Dual-read so playback works mid-migration; see `Capsule.audioSource`.
    func play(_ capsule: Capsule) throws {
        switch capsule.audioSource {
        case .data:
            guard let data = capsule.audioData else { throw PlayerError.couldNotStart }
            try play(data: data)
        case .file(let fileName):
            try play(fileName: fileName)
        case .none:
            throw PlayerError.couldNotStart
        }
    }

    func play(fileName: String) throws {
        try start { try AVAudioPlayer(contentsOf: store.url(for: fileName)) }
    }

    /// Play directly from an in-memory clip (the M9 canonical `audioData` path).
    func play(data: Data) throws {
        try start { try AVAudioPlayer(data: data) }
    }

    /// Shared session setup + playback start for both audio sources.
    private func start(makePlayer: () throws -> AVAudioPlayer) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        let player = try makePlayer()
        player.delegate = self
        guard player.play() else { throw PlayerError.couldNotStart }
        self.player = player
        state = .playing
        startTimer()
    }

    func pause() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, let player else { return }
        player.play()
        state = .playing
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        progress = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player, player.duration > 0 else { return }
        progress = max(0, min(1, player.currentTime / player.duration))
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

extension Capsule {
    /// Where a capsule's clip should be read from at play time. Prefers the
    /// durable in-store `audioData` blob; falls back to the legacy on-disk file
    /// for capsules not yet reached by the M9 backfill (docs/M9-DEVPLAN.md §S1).
    /// Pure + synchronous so the dual-read precedence is unit-testable without
    /// touching AVFoundation; `.data` deliberately carries no payload so reading
    /// it never faults the (potentially large) blob.
    enum AudioSource: Equatable { case data, file(String), none }

    var audioSource: AudioSource {
        if audioData != nil { return .data }
        if let audioFileName { return .file(audioFileName) }
        return .none
    }
}
