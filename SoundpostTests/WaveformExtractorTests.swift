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

    /// A mostly-quiet clip with one short loud burst — the shape that separates a
    /// per-frame peak from a bucket average.
    private func makeBurstClip(seconds: Double, burstSeconds: Double,
                               quiet: Float, burst: Float) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "wf-burst-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(44_100.0 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        // Put the burst a third of the way in, so it lands mid-clip for any bucketing.
        let burstStart = Int(Double(frames) / 3)
        let burstEnd = burstStart + Int(44_100.0 * burstSeconds)
        for i in 0..<Int(frames) {
            let amplitude = (i >= burstStart && i < burstEnd) ? burst : quiet
            channel[i] = sin(Float(i) * 0.05) * amplitude
        }
        try file.write(from: buffer)
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

    /// A peak, not a mean — and *strictly* above it. The earlier version of this
    /// test asserted `absolutePeak >= peak`, which is trivially true when the two
    /// are the same value: it passed just as happily against the bug it was written
    /// to guard. A sine's mean magnitude is 2/π of its peak, so a real peak must
    /// clear the bucket average by a wide, checkable margin.
    @Test func absolutePeakIsStrictlyAboveTheLoudestBucketAverage() throws {
        let url = try makeSineClip(seconds: 3)
        for buckets in [8, 32, 56, 128] {
            let e = try WaveformExtractor.extract(from: url, buckets: buckets)
            #expect(e.absolutePeak > e.peak * 1.3,
                    "buckets=\(buckets): absolutePeak \(e.absolutePeak) is not meaningfully above bucket peak \(e.peak)")
        }
    }

    /// The shipped defect itself: the gate's input must not change with a
    /// waveform-*drawing* parameter. Capture asks for 56 buckets and the backfill
    /// for 32, so a measure that moves between them let the same recording pass at
    /// capture and be written off as silent at backfill — permanently.
    ///
    /// A sparse clip (mostly quiet, one short burst) is the case that separates the
    /// two measures: averaging the burst over a longer window drags a bucket mean
    /// down, while a per-frame maximum does not move at all. The assertion on `peak`
    /// is deliberate — it pins *why* the old input was unusable, so this test still
    /// means something if someone tries to switch back.
    @Test func theGateInputIsStableAcrossTheTwoCallSitesBucketCounts() throws {
        let url = try makeBurstClip(seconds: 3, burstSeconds: 0.05, quiet: 0.002, burst: 0.6)
        let backfill = try WaveformExtractor.extract(from: url, buckets: 32)
        let capture = try WaveformExtractor.extract(from: url, buckets: 56)

        #expect(abs(backfill.absolutePeak - capture.absolutePeak) < 0.001,
                "the gate input moved between the backfill's 32 buckets and capture's 56")
        #expect(backfill.peak != capture.peak,
                "bucket averages are expected to differ — that is why they cannot gate")
    }

    /// Near-silence, not digital zero. A pure zero clip is not a meaningful test of
    /// this gate: a real room recording is never zero, and both the old and new
    /// measures read 0 for it, so the assertion held no matter which was wired in.
    @Test func nearSilenceStaysBelowTheGate() throws {
        let url = try makeSineClip(seconds: 1, amplitude: 0.001)
        let peak = try WaveformExtractor.extract(from: url).absolutePeak
        #expect(peak < SoundprintService.minimumPeak,
                "room-tone-level audio (\(peak)) must not reach the classifier")
    }
}
