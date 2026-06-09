import Testing
import Foundation
import AVFoundation
@testable import Soundpost

struct WaveformExtractorTests {
    /// Write a 1-second mono sine wave to a real AAC/m4a file and return its URL.
    /// Exercises the same decode path the app uses, without a microphone.
    private func makeSineClip(seconds: Double = 1.0) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "wf-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(44_100.0 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = sin(Float(i) * 0.05) * 0.5
        }
        try file.write(from: buffer)
        // `file` flushes/closes on dealloc at function return.
        return url
    }

    @Test func extractsRequestedBucketCount() throws {
        let url = try makeSineClip()
        let samples = try WaveformExtractor.samples(from: url, buckets: 64)
        #expect(samples.count == 64)
    }

    @Test func samplesAreNormalizedZeroToOne() throws {
        let url = try makeSineClip()
        let samples = try WaveformExtractor.samples(from: url, buckets: 48)
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
        // A sine wave is non-silent, so the peak must normalize to ~1.
        #expect((samples.max() ?? 0) > 0.9)
        #expect((samples.max() ?? 0) <= 1.0001)
    }

    @Test func honorsCustomBucketCount() throws {
        let url = try makeSineClip()
        #expect(try WaveformExtractor.samples(from: url, buckets: 16).count == 16)
    }

    @Test func zeroBucketsYieldsEmpty() throws {
        let url = try makeSineClip()
        #expect(try WaveformExtractor.samples(from: url, buckets: 0).isEmpty)
    }
}
