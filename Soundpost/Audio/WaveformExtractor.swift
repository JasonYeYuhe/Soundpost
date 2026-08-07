import Foundation
import AVFoundation

/// Reduces an audio file to a small array of normalized (0...1) amplitude
/// samples used to draw the waveform card. Pure and file-driven, so it can be
/// unit-tested against a generated clip without a microphone.
///
/// **Bounded memory (M11 §2B(b)):** the file is read in a fixed-size streaming
/// buffer rather than decoded whole into one PCM buffer. A 5-minute Pro clip is
/// ~50 MB of float PCM; loading that on the main actor (the capture VM calls this
/// at record-finish) would spike memory. Peak memory here is one
/// `chunkFrames`-sized buffer (~64 KB mono) regardless of clip length.
enum WaveformExtractor {
    enum ExtractError: Error { case couldNotAllocateBuffer }

    /// Frames read per streaming chunk — the upper bound on the working buffer.
    private static let chunkFrames: AVAudioFrameCount = 16_384

    /// A waveform plus the one fact normalisation destroys: how loud the clip
    /// actually was.
    ///
    /// `samples` are normalized to 0…1, so their peak is *always* 1.0 and they can
    /// never tell you whether a recording was a thunderstorm or silence. M15 needs
    /// exactly that to gate classification (silence classifies as `music 0.25`), and
    /// reading the file a second time just to learn it would double the post-capture
    /// cost (M15 §4C/§4K).
    struct Extraction: Equatable, Sendable {
        /// Normalized 0…1 magnitudes, one per bucket — what the waveform draws.
        let samples: [Float]
        /// The loudest **bucket average**, i.e. the divisor the samples were
        /// normalized by. Depends on `buckets`: more buckets means a shorter
        /// averaging window and a higher value for the same audio. Use it to undo
        /// the normalisation, not to judge how loud a clip was.
        let peak: Float
        /// The loudest single **frame** — a true absolute peak, independent of
        /// `buckets`.
        ///
        /// M15's amplitude gate needs this one. It used to be handed `peak`, which
        /// is a mean over a fraction of a second and therefore several times lower
        /// than a real peak — and, worse, varies with a waveform-*drawing*
        /// parameter that differs between call sites (capture asks for 56 buckets,
        /// the backfill for 32). The same quiet-but-audible recording could clear
        /// the gate at capture and fail it during backfill, which then wrote the
        /// terminal "analysed, nothing to say" marker and put that capsule beyond
        /// reach of both search and any later retry.
        let absolutePeak: Float
    }

    /// Read `url` once, returning both the normalized waveform and the absolute peak.
    static func extract(from url: URL, buckets: Int = 64) throws -> Extraction {
        try extraction(from: url, buckets: buckets)
    }

    /// Read `url` and bucket its samples into `buckets` normalized magnitudes.
    /// Returns exactly `buckets` values (zero-padded if the clip is very short),
    /// or `[]` for an empty/zero-length file.
    ///
    /// Bucketing matches the previous whole-file implementation exactly: frame
    /// `i` belongs to bucket `i / bucketSize` with `bucketSize = max(1, length /
    /// buckets)`; trailing frames beyond the requested bucket count are dropped
    /// (as the old code trimmed), and the tallest kept bar normalizes to 1.0.
    static func samples(from url: URL, buckets: Int = 64) throws -> [Float] {
        try extraction(from: url, buckets: buckets).samples
    }

    private static func extraction(from url: URL, buckets: Int) throws -> Extraction {
        guard buckets > 0 else { return Extraction(samples: [], peak: 0, absolutePeak: 0) }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let length = Int(file.length)
        guard length > 0 else { return Extraction(samples: [], peak: 0, absolutePeak: 0) }

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return Extraction(samples: [], peak: 0, absolutePeak: 0) }

        let bucketSize = max(1, length / buckets)
        // Only the first `buckets * bucketSize` frames feed the kept buckets; the
        // remainder would have been trimmed, so we never read past it.
        let framesToScan = min(length, buckets * bucketSize)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ExtractError.couldNotAllocateBuffer
        }

        var bucketSums = [Float](repeating: 0, count: buckets)
        var bucketCounts = [Int](repeating: 0, count: buckets)
        // Tracked in the same pass, so the true peak costs nothing extra.
        var absolutePeak: Float = 0

        var framesProcessed = 0
        while framesProcessed < framesToScan {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let read = Int(buffer.frameLength)
            if read == 0 { break } // EOF safety
            guard let channelData = buffer.floatChannelData else { break }

            let usable = min(read, framesToScan - framesProcessed)
            for local in 0..<usable {
                let globalFrame = framesProcessed + local
                let bucket = globalFrame / bucketSize
                if bucket >= buckets { break }
                var magnitude: Float = 0
                for channel in 0..<channelCount {
                    magnitude += abs(channelData[channel][local])
                }
                let frameMagnitude = magnitude / Float(channelCount)
                bucketSums[bucket] += frameMagnitude
                bucketCounts[bucket] += 1
                absolutePeak = max(absolutePeak, frameMagnitude)
            }
            framesProcessed += read
        }

        // Contiguous filled prefix → average each bucket; the rest is padding.
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(buckets)
        for bucket in 0..<buckets {
            guard bucketCounts[bucket] > 0 else { break }
            magnitudes.append(bucketSums[bucket] / Float(bucketCounts[bucket]))
        }

        let peak = magnitudes.max() ?? 0
        if peak > 0 {
            for index in magnitudes.indices { magnitudes[index] /= peak }
        }
        if magnitudes.count < buckets {
            magnitudes.append(contentsOf: Array(repeating: 0, count: buckets - magnitudes.count))
        }
        // Both are captured BEFORE normalisation — they are the only surviving
        // record of absolute loudness. `peak` undoes the normalisation; the silence
        // gate uses `absolutePeak`, which does not move with `buckets`.
        return Extraction(samples: magnitudes, peak: peak, absolutePeak: absolutePeak)
    }
}
