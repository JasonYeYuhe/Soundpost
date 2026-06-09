import Testing
import Foundation
@testable import Soundpost

/// Tests the capture → save wiring without a microphone, via the model's test seam.
@Suite(.serialized)
@MainActor
struct CaptureViewModelTests {

    @Test func saveCreatesCapturedCapsule() throws {
        let store = try TestSupport.freshStore()
        let viewModel = CaptureViewModel()
        viewModel.setReviewStateForTesting(fileName: "abc.m4a", duration: 7, waveform: [0.2, 0.9, 0.5])
        viewModel.mood = .joyful
        viewModel.note = "  morning rain  "

        let capsule = try viewModel.save(using: store)

        #expect(capsule != nil)
        #expect(capsule?.state == .captured)
        #expect(capsule?.audioFileName == "abc.m4a")
        #expect(capsule?.durationSeconds == 7)
        #expect(capsule?.waveformSamples == [0.2, 0.9, 0.5])
        #expect(capsule?.mood == .joyful)
        #expect(capsule?.note == "morning rain") // trimmed
        #expect(capsule?.place == nil)            // includePlace not set
        #expect(try store.all().count == 1)
    }

    @Test func saveWithNothingRecordedReturnsNil() throws {
        let store = try TestSupport.freshStore()
        let viewModel = CaptureViewModel()
        #expect(try viewModel.save(using: store) == nil)
        #expect(try store.all().isEmpty)
    }

    @Test func blankNoteBecomesNil() throws {
        let store = try TestSupport.freshStore()
        let viewModel = CaptureViewModel()
        viewModel.setReviewStateForTesting(fileName: "x.m4a", duration: 1, waveform: [])
        viewModel.note = "   \n  "
        let capsule = try viewModel.save(using: store)
        #expect(capsule?.note == nil)
    }

    @Test func saveResetsToIdle() throws {
        let store = try TestSupport.freshStore()
        let viewModel = CaptureViewModel()
        viewModel.setReviewStateForTesting(fileName: "y.m4a", duration: 2, waveform: [0.5])
        _ = try viewModel.save(using: store)
        #expect(viewModel.phase == .idle)
    }
}
