import Testing
import Foundation
@testable import Soundpost

/// A stand-in for `AudioPlayer` that makes no sound.
///
/// Playing for real is deliberately out of reach here: `AVAudioSession` on the
/// simulator is unreliable enough that two existing suites are documented as
/// failing locally and green on CI, so a test that started audio would be measuring
/// the simulator. What M16 §S0 actually promises is a *policy* — one capsule at a
/// time, the control clears when the sound ends or fails, a sealed capsule is never
/// played — and all of that lives in `PlaybackController`.
@MainActor
private final class FakePlayer: CapsuleAudioPlaying {
    var state: AudioPlayer.State = .idle
    var progress: Double = 0
    var onPlaybackEnded: (() -> Void)?

    private(set) var played: [UUID] = []
    private(set) var stopCount = 0
    /// Make the next `play` throw, standing in for a clip that will not open.
    var failsToStart = false

    func play(_ capsule: Capsule) throws {
        if failsToStart { throw AudioPlayer.PlayerError.couldNotStart }
        played.append(capsule.id)
        state = .playing
    }

    func pause() { if state == .playing { state = .paused } }
    func resume() { if state == .paused { state = .playing } }
    func stop() { stopCount += 1; state = .idle; progress = 0 }

    /// What `AVAudioPlayer`'s delegate does when the clip runs out — or when the
    /// decoder gives up part-way through, which reaches the same callback.
    func endedOnItsOwn() {
        state = .idle
        onPlaybackEnded?()
    }
}

@MainActor
struct PlaybackControllerTests {
    private func captured(duration: Double = 8) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.durationSeconds = duration
        return capsule
    }

    private func sealed(until: Date) throws -> Capsule {
        let capsule = try captured()
        capsule.sealUntil = until
        try capsule.transition(to: .sealed)
        return capsule
    }

    // MARK: One owner

    /// The whole point of the milestone's S0: a second capsule replaces the first
    /// rather than joining it, and the first capsule's card stops offering a pause.
    @Test func startingASecondCapsuleReplacesTheFirst() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let first = try captured()
        let second = try captured()

        controller.toggle(first)
        #expect(controller.playingCapsuleID == first.id)
        #expect(controller.controlState(for: first) == .playing)

        controller.toggle(second)
        #expect(controller.playingCapsuleID == second.id)
        #expect(controller.controlState(for: second) == .playing)
        #expect(controller.controlState(for: first) == .idle)
        #expect(player.played == [first.id, second.id])
    }

    @Test func togglePausesAndResumesTheSameCapsule() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try captured()

        controller.toggle(capsule)
        controller.toggle(capsule)
        #expect(controller.controlState(for: capsule) == .paused)
        #expect(controller.playingCapsuleID == capsule.id)   // still ours, just held

        controller.toggle(capsule)
        #expect(controller.controlState(for: capsule) == .playing)
        #expect(player.played == [capsule.id])               // resumed, not restarted
    }

    @Test func stopClearsTheOwner() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try captured()

        controller.toggle(capsule)
        controller.stop()

        #expect(controller.playingCapsuleID == nil)
        #expect(controller.controlState(for: capsule) == .idle)
        #expect(player.stopCount >= 1)
    }

    // MARK: The control must not outlive the sound (§4A)

    @Test func naturalCompletionClearsTheControl() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try captured()

        controller.toggle(capsule)
        player.endedOnItsOwn()

        #expect(controller.playingCapsuleID == nil)
        #expect(controller.controlState(for: capsule) == .idle)
    }

    /// A clip that will not open leaves nothing behind — no id, and a player that
    /// has been told to tear down, so the next attempt starts from idle.
    @Test func aFailedStartLeavesNothingPlaying() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try captured()

        player.failsToStart = true
        controller.toggle(capsule)

        #expect(controller.playingCapsuleID == nil)
        #expect(controller.controlState(for: capsule) == .idle)
        #expect(player.played.isEmpty)
        #expect(player.stopCount >= 1)
    }

    /// The nastier version: something *was* playing, and the new clip fails. The
    /// old capsule's control must not be left showing a pause for audio the failed
    /// start already replaced.
    @Test func aFailedStartDoesNotLeaveThePreviousCapsuleLookingPlayed() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let playing = try captured()
        let broken = try captured()

        controller.toggle(playing)
        player.failsToStart = true
        controller.toggle(broken)

        #expect(controller.playingCapsuleID == nil)
        #expect(controller.controlState(for: playing) == .idle)
        #expect(controller.controlState(for: broken) == .idle)
    }

    // MARK: A seal hides the sound too (§4B / §10)

    @Test func aSealedNotDueCapsuleIsNeverPlayed() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try sealed(until: Date(timeIntervalSinceNow: 86_400))

        controller.toggle(capsule)
        controller.play(capsule)

        #expect(player.played.isEmpty)
        #expect(controller.playingCapsuleID == nil)
    }

    @Test func aSealPastItsDatePlaysAgain() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try sealed(until: Date(timeIntervalSinceNow: -60))

        controller.toggle(capsule)

        #expect(controller.playingCapsuleID == capsule.id)
    }

    /// The reveal auto-starts; toggling there would pause a postcard that had just
    /// begun to play itself.
    @Test func playAlwaysStartsRatherThanToggling() throws {
        let player = FakePlayer()
        let controller = PlaybackController(player: player)
        let capsule = try captured()

        controller.play(capsule)
        controller.play(capsule)

        #expect(controller.controlState(for: capsule) == .playing)
        #expect(player.played == [capsule.id, capsule.id])
    }

    // MARK: Which capsules offer a control at all

    @Test func offersPlaybackFollowsContentVisibilityAndHavingAClip() throws {
        #expect(try captured().offersPlayback())

        // Nothing recorded yet: a control would throw the moment it was tapped.
        #expect(try !captured(duration: 0).offersPlayback())

        // A draft has no clip and no visible content.
        #expect(!Capsule().offersPlayback())

        // A sealed capsule's sound is as hidden as its words, until its date.
        let future = try sealed(until: Date(timeIntervalSinceNow: 3_600))
        #expect(!future.offersPlayback())
        #expect(future.offersPlayback(now: Date(timeIntervalSinceNow: 7_200)))
    }

    @Test func aResurfacedCapsuleOffersPlayback() throws {
        let capsule = try sealed(until: Date(timeIntervalSinceNow: -60))
        try capsule.transition(to: .resurfaced)
        #expect(capsule.offersPlayback())
        try capsule.transition(to: .opened)
        #expect(capsule.offersPlayback())
    }
}
