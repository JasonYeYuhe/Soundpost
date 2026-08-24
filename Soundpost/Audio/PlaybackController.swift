import Foundation
import Observation

/// The slice of `AudioPlayer` that `PlaybackController` drives.
///
/// It exists so the one-owner *policy* — which capsule is playing, what a card
/// should draw, what happens when a clip ends or fails — is unit-testable without
/// starting real audio. Playback itself is not testable here: `AVAudioSession` on
/// the simulator is unreliable enough that two existing suites are documented as
/// failing locally and green on CI, so a test that actually made a sound would be
/// measuring the simulator, not this type.
@MainActor
protocol CapsuleAudioPlaying: AnyObject {
    var state: AudioPlayer.State { get }
    var progress: Double { get }
    var onPlaybackEnded: (() -> Void)? { get set }
    func play(_ capsule: Capsule) throws
    func pause()
    func resume()
    func stop()
}

extension AudioPlayer: CapsuleAudioPlaying {}

/// The app's single playback owner (M16 §4A).
///
/// Before this, every screen that could play a capsule built its own `AudioPlayer`
/// — the detail view, the resurface reveal, the capture review — and adding a play
/// control to the gallery card would have added one per row. Three of those pairs
/// can overlap on screen at once, and nothing coordinated them, so two capsules
/// could sound at the same time.
///
/// One owner, held above the gallery and injected into the environment, removes
/// that by construction: there is exactly one `AudioPlayer` in the app, and
/// `playingCapsuleID` is the single answer to "what is playing". Every transition
/// that leaves the gallery — opening a capsule, the reveal, capture, the scene
/// going inactive — calls `stop()`.
///
/// **`playingCapsuleID` must clear on natural completion and on failure**, or the
/// UI keeps offering a pause button for audio that already stopped. Completion and
/// mid-clip decode failure arrive through `AudioPlayer.onPlaybackEnded`; a failure
/// to *start* is handled inline in `startPlayback`.
@MainActor
@Observable
final class PlaybackController {
    /// What a play control should draw for one capsule.
    enum ControlState: Equatable { case idle, playing, paused }

    /// The capsule whose audio this owner currently holds — playing or paused.
    /// `nil` whenever nothing is loaded, including after a clip finishes, after a
    /// decode failure, and after a failed start.
    private(set) var playingCapsuleID: UUID?

    let player: any CapsuleAudioPlaying

    /// The default is nil rather than `AudioPlayer()` because a default-argument
    /// expression is evaluated outside this type's actor, and building the real
    /// player is `@MainActor` work.
    init(player: (any CapsuleAudioPlaying)? = nil) {
        self.player = player ?? AudioPlayer()
        self.player.onPlaybackEnded = { [weak self] in self?.playingCapsuleID = nil }
    }

    /// What `capsule`'s control should show.
    ///
    /// The `guard` is load-bearing beyond correctness: a card that is not the
    /// playing one returns before reading `player.state`, so Observation never
    /// records a dependency on it and that card is not invalidated when playback
    /// starts or stops elsewhere in the list. Nothing here reads `progress`, which
    /// ticks at 20 Hz (`AudioPlayer.swift`) — a card that read it would re-render
    /// twenty times a second, and a whole gallery of them would re-render with it
    /// (M16 §7).
    func controlState(for capsule: Capsule) -> ControlState {
        guard playingCapsuleID == capsule.id else { return .idle }
        switch player.state {
        case .playing: return .playing
        case .paused: return .paused
        case .idle: return .idle
        }
    }

    /// Start, pause or resume — the single entry point every play control uses.
    func toggle(_ capsule: Capsule, now: Date = .now) {
        guard capsule.offersPlayback(now: now) else { return }
        guard playingCapsuleID == capsule.id else { return startPlayback(capsule) }
        switch player.state {
        case .playing: player.pause()
        case .paused: player.resume()
        case .idle: startPlayback(capsule)
        }
    }

    /// Start from the beginning regardless of what is playing — the reveal's
    /// auto-play, where "toggle" would pause a capsule that had just started.
    func play(_ capsule: Capsule, now: Date = .now) {
        guard capsule.offersPlayback(now: now) else { return }
        startPlayback(capsule)
    }

    /// Stop and forget. Idempotent, and safe to call from a view's `onDisappear`
    /// when nothing was playing.
    func stop() {
        playingCapsuleID = nil
        player.stop()
    }

    private func startPlayback(_ capsule: Capsule) {
        // Cleared *before* the attempt: if `play` throws, the id must not still be
        // whatever was playing a moment ago, and the assignment below is the only
        // thing that sets it.
        playingCapsuleID = nil
        do {
            try player.play(capsule)
            playingCapsuleID = capsule.id
        } catch {
            // Leave the session and the player in the idle state a fresh attempt
            // expects. Silent to the user by design — the same choice the detail
            // view's `try?` has always made — but recorded, because a clip that
            // will not open is a durability signal, not a UI event.
            player.stop()
            Diagnostics.notice("Playback could not start")
        }
    }
}
