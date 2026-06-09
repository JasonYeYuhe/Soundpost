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

    func play(fileName: String) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        let player = try AVAudioPlayer(contentsOf: store.url(for: fileName))
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
