import Foundation
import AVFoundation

/// Reduces an audio file to a small array of normalized (0...1) amplitude
/// samples used to draw the waveform card. Pure and file-driven, so it can be
/// unit-tested against a generated clip without a microphone.
enum WaveformExtractor {
    enum ExtractError: Error { case couldNotAllocateBuffer }

    /// Read `url` and bucket its samples into `buckets` normalized magnitudes.
    /// Returns exactly `buckets` values (zero-padded if the clip is very short),
    /// or `[]` for an empty/zero-length file.
    static func samples(from url: URL, buckets: Int = 64) throws -> [Float] {
        guard buckets > 0 else { return [] }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ExtractError.couldNotAllocateBuffer
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { return [] }
        let channelCount = Int(format.channelCount)
        let length = Int(buffer.frameLength)
        guard length > 0, channelCount > 0 else { return [] }

        let bucketSize = max(1, length / buckets)
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(buckets)

        var start = 0
        while start < length {
            let end = min(start + bucketSize, length)
            var sum: Float = 0
            for frame in start..<end {
                var frameMagnitude: Float = 0
                for channel in 0..<channelCount {
                    frameMagnitude += abs(channelData[channel][frame])
                }
                sum += frameMagnitude / Float(channelCount)
            }
            magnitudes.append(sum / Float(end - start))
            start = end
        }

        // Trim to the final count BEFORE normalizing, so the tallest *kept* bar
        // maps to 1.0 (normalizing first could trim away the peak bucket).
        if magnitudes.count > buckets {
            magnitudes = Array(magnitudes.prefix(buckets))
        }
        let peak = magnitudes.max() ?? 0
        if peak > 0 {
            for index in magnitudes.indices { magnitudes[index] /= peak }
        }
        // Zero-pad very short clips up to the requested count.
        if magnitudes.count < buckets {
            magnitudes.append(contentsOf: Array(repeating: 0, count: buckets - magnitudes.count))
        }
        return magnitudes
    }
}
