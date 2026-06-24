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

    /// Read `url` and bucket its samples into `buckets` normalized magnitudes.
    /// Returns exactly `buckets` values (zero-padded if the clip is very short),
    /// or `[]` for an empty/zero-length file.
    ///
    /// Bucketing matches the previous whole-file implementation exactly: frame
    /// `i` belongs to bucket `i / bucketSize` with `bucketSize = max(1, length /
    /// buckets)`; trailing frames beyond the requested bucket count are dropped
    /// (as the old code trimmed), and the tallest kept bar normalizes to 1.0.
    static func samples(from url: URL, buckets: Int = 64) throws -> [Float] {
        guard buckets > 0 else { return [] }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let length = Int(file.length)
        guard length > 0 else { return [] }

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        let bucketSize = max(1, length / buckets)
        // Only the first `buckets * bucketSize` frames feed the kept buckets; the
        // remainder would have been trimmed, so we never read past it.
        let framesToScan = min(length, buckets * bucketSize)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ExtractError.couldNotAllocateBuffer
        }

        var bucketSums = [Float](repeating: 0, count: buckets)
        var bucketCounts = [Int](repeating: 0, count: buckets)

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
                bucketSums[bucket] += magnitude / Float(channelCount)
                bucketCounts[bucket] += 1
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
        return magnitudes
    }
}
