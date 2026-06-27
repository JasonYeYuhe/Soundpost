import Testing
import Foundation
import AVFoundation
@testable import Soundpost

/// The recording cap is settable so the capture VM can raise it to the Pro cap
/// at record-start (M11 §4D). The cap only ever bounds a *new* recording — it is
/// never re-applied to an already-recorded clip.
@MainActor
struct AudioRecorderTests {
    @Test func defaultMaxDurationIsSixtySeconds() {
        #expect(AudioRecorder().maxDuration == 60)
    }

    @Test func maxDurationIsSettable() {
        let recorder = AudioRecorder()
        recorder.maxDuration = 300
        #expect(recorder.maxDuration == 300)
    }

    @Test func initialMaxDurationCanBeRaisedToProCap() {
        #expect(AudioRecorder(maxDuration: 300).maxDuration == 300)
    }

    @Test func captureViewModelBuildsRecorderWithGivenCap() {
        #expect(CaptureViewModel(maxDuration: 300).recorder.maxDuration == 300)
    }
}

/// The "never lose a clip" finalize triggers (§S8). The decision is extracted as a
/// pure function so the interruption/route-loss conditions are testable without a
/// live microphone recording.
struct AudioRecorderFinalizeDecisionTests {
    private func interruption(_ type: AVAudioSession.InterruptionType) -> Notification {
        Notification(name: AVAudioSession.interruptionNotification, object: nil,
                     userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
    }
    private func routeChange(_ reason: AVAudioSession.RouteChangeReason) -> Notification {
        Notification(name: AVAudioSession.routeChangeNotification, object: nil,
                     userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    @Test func interruptionBeganFinalizes() {
        #expect(AudioRecorder.shouldFinalizeForInterruption(interruption(.began)))
    }

    @Test func interruptionEndedDoesNotFinalize() {
        #expect(!AudioRecorder.shouldFinalizeForInterruption(interruption(.ended)))
    }

    @Test func routeOldDeviceUnavailableFinalizes() {
        #expect(AudioRecorder.shouldFinalizeForRouteChange(routeChange(.oldDeviceUnavailable)))
    }

    @Test func otherRouteReasonsDoNotFinalize() {
        #expect(!AudioRecorder.shouldFinalizeForRouteChange(routeChange(.newDeviceAvailable)))
        #expect(!AudioRecorder.shouldFinalizeForRouteChange(routeChange(.categoryChange)))
    }

    @Test func malformedNotificationsNeverFinalize() {
        let empty = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: nil)
        #expect(!AudioRecorder.shouldFinalizeForInterruption(empty))
        #expect(!AudioRecorder.shouldFinalizeForRouteChange(empty))
    }
}
