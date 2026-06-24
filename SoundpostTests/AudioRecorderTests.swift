import Testing
import Foundation
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
