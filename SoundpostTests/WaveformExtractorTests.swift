import Testing
import Foundation
import AVFoundation
@testable import Soundpost

struct WaveformExtractorTests {
    /// Write a 1-second mono sine wave to a real AAC/m4a file and return its URL.
    /// Exercises the same decode path the app uses, without a microphone.
    private func makeSineClip(seconds: Double = 1.0, amplitude: Float = 0.5) throws -> URL {
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
            channel[i] = sin(Float(i) * 0.05) * amplitude
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

    /// A multi-second clip spans many streaming chunks (chunkFrames = 16,384);
    /// the bounded-buffer reader must still return a full, normalized waveform —
    /// the §S3 "5-min extract doesn't spike memory, waveform still reads" path.
    @Test func longClipStreamsToFullNormalizedWaveform() throws {
        let url = try makeSineClip(seconds: 6) // ~264,600 frames → ~17 chunks
        let samples = try WaveformExtractor.samples(from: url, buckets: 56)
        #expect(samples.count == 56)
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
        #expect((samples.max() ?? 0) > 0.9)     // peak still normalizes
        #expect(samples.contains { $0 > 0.05 })  // not all-zero across chunks
    }

    @Test func longClipHonorsArbitraryBucketCount() throws {
        let url = try makeSineClip(seconds: 3)
        #expect(try WaveformExtractor.samples(from: url, buckets: 37).count == 37)
    }

    // MARK: The amplitude gate's input (M15 §4C)

    /// The gate must not move with a waveform-*drawing* parameter. Capture asks for
    /// 56 buckets and the backfill for 32; when the gate read `peak` — a bucket
    /// *average* — the same clip measured differently in the two places, so a quiet
    /// recording could pass at capture and then be written off as silent during
    /// backfill, permanently.
    @Test func absolutePeakDoesNotMoveWithBucketCount() throws {
        let url = try makeSineClip(seconds: 3)
        let at32 = try WaveformExtractor.extract(from: url, buckets: 32)
        let at56 = try WaveformExtractor.extract(from: url, buckets: 56)
        #expect(abs(at32.absolutePeak - at56.absolutePeak) < 0.001)
    }

    /// And it really is a peak: never below the loudest bucket average, because a
    /// mean can never exceed the maximum it averages over.
    @Test func absolutePeakIsAtLeastTheLoudestBucketAverage() throws {
        let url = try makeSineClip(seconds: 3)
        for buckets in [8, 32, 56, 128] {
            let e = try WaveformExtractor.extract(from: url, buckets: buckets)
            #expect(e.absolutePeak >= e.peak - 0.001,
                    "buckets=\(buckets): absolutePeak \(e.absolutePeak) < bucket peak \(e.peak)")
        }
    }

    /// Silence must land well under `SoundprintService.minimumPeak` — that gate is
    /// the whole reason silence does not get classified as "music".
    @Test func silenceStaysBelowTheGate() throws {
        let url = try makeSineClip(seconds: 1, amplitude: 0)
        let peak = try WaveformExtractor.extract(from: url).absolutePeak
        #expect(peak < SoundprintService.minimumPeak)
    }
}
