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

    /// Called when playback ended **on its own** — the clip ran out, or the decoder
    /// gave up part-way through. Deliberately NOT called by `stop()` or `pause()`,
    /// which the caller already knows about.
    ///
    /// It exists because `AVAudioPlayer`'s delegate is the only signal that a sound
    /// has finished: without it, whoever is tracking *which* capsule is playing keeps
    /// saying so after the audio stopped, and a card is left showing a pause button
    /// for silence (M16 §4A).
    @ObservationIgnored var onPlaybackEnded: (() -> Void)?

    private let store: AudioStore
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(store: AudioStore = AudioStore()) {
        self.store = store
        super.init()
    }

    // No deinit cleanup needed (§S8): the progress timer captures `[weak self]`, so
    // it never retains a freed player, and every screen that can play a capsule stops
    // it in `.onDisappear` — since M16 through the one shared `PlaybackController`,
    // which invalidates the timer and deactivates the audio session on the main
    // actor, the correct thread for both, which a nonisolated `deinit` could not
    // guarantee. (`CaptureViewModel` still owns a second player, for a recording that
    // is not a capsule yet.)

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

    /// Tear down, then tell whoever is tracking the playing capsule that it ended
    /// without them asking. Order matters: the notification fires against a player
    /// that is already idle, so a listener that reads `state` sees the truth.
    private func endPlayback() {
        stop()
        onPlaybackEnded?()
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.endPlayback() }
    }

    /// A clip that decodes far enough to start and then fails part-way through: the
    /// audio stops, and without this callback nothing else ever says so. `flag ==
    /// false` above covers the same class of failure at the end of the clip; this
    /// covers it in the middle.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.endPlayback() }
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
