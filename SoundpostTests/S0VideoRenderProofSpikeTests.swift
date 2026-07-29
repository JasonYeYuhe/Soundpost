import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import UIKit
@testable import Soundpost

// MARK: - M13 S0 — render-proof spike (THROWAWAY: deleted at S1)
//
// docs/M13-DEVPLAN.md §5 S0. The whole M13 milestone is built on one unproven
// assumption: that we can encode a real, non-black, audio-synced `.mp4` on the CI
// **simulator** with `AVAssetWriter`. This file proves (or disproves) exactly
// that, before any geometry, UI, gate, or test is built on top of it. It is
// deliberately self-contained in the test target — nothing throwaway lands in the
// app — and is deleted once the working core graduates into `VideoExporter` (S1).
//
// It exercises every P0/P1 the review surfaced, so a failure here is cheap:
//  • §4A  `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` + `AVAssetReader`
//         — NOT `AVVideoCompositionCoreAnimationTool` (no video track to composite
//         over → black/audio-only) and no API deprecated on the iOS 26 SDK.
//  • §4B  duration / frame count keyed to the **loaded audio-track duration**,
//         never a stored `Capsule.durationSeconds`.
//  • §4A  an explicit **top-left** `CGContext` (no CALayer y-flip).
//  • §7   H.264 actually encodes on the sim, and the first frame is **non-black**
//         (a purely structural test passes on a broken all-black export).

/// The throwaway render core. Vertical 1080×1920 / 30 fps / H.264 + AAC (§4D,
/// confirmed with Jason 2026-07-29).
private enum RenderProofSpike {
    static let width = 1080
    static let height = 1920
    static let fps: Int32 = 30
    /// Target average bitrate. S0 measures what the encoder actually produces for
    /// our near-static content so S4's arithmetic preflight constant is grounded
    /// in measurement rather than guessed (§4G).
    static let averageBitRate = 4_000_000

    enum SpikeError: Error, CustomStringConvertible {
        case msg(String)
        var description: String { if case .msg(let m) = self { return m }; return "spike error" }
    }

    struct Measurement {
        let output: URL
        let frameCount: Int
        /// The authoritative duration: loaded from the source audio *track*.
        let audioDuration: CMTime
        let renderSeconds: Double
        let byteCount: Int64

        var frameDuration: CMTime { CMTime(value: 1, timescale: RenderProofSpike.fps) }
        /// Measured bytes per second of output — the honest input to §4G's preflight.
        var bytesPerSecond: Double {
            audioDuration.seconds > 0 ? Double(byteCount) / audioDuration.seconds : 0
        }
        /// Render seconds per second of audio — the input to the §8 duration-cap call.
        var realtimeFactor: Double {
            audioDuration.seconds > 0 ? renderSeconds / audioDuration.seconds : 0
        }
    }

    /// Label a throwing AVFoundation call so a failure names its own stage.
    private static func stage<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            throw SpikeError.msg("[\(label)] \(error)")
        }
    }

    private static func stage<T>(_ label: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            throw SpikeError.msg("[\(label)] \(error)")
        }
    }

    /// Render `cardImage` + a growing reveal bar over the audio at `audioURL`,
    /// muxed into an `.mp4` at `output`. Runs entirely off the main actor.
    static func render(audioURL: URL, cardImage: CGImage, to output: URL) async throws -> Measurement {
        let startedAt = Date()

        // ---- Source audio: the LOADED track duration is authoritative (§4B/P0).
        let source = AVURLAsset(url: audioURL)
        guard let audioTrack = try await stage("loadTracks(audio)", { try await source.loadTracks(withMediaType: .audio) }).first else {
            throw SpikeError.msg("source .m4a has no audio track")
        }
        let audioDuration = try await stage("load(.timeRange)", { try await audioTrack.load(.timeRange) }).duration
        let sourceFormat = try await stage("load(.formatDescriptions)", { try await audioTrack.load(.formatDescriptions) }).first
        let frameCount = max(1, Int((audioDuration.seconds * Double(fps)).rounded()))

        // ---- Writer: H.264 video + AAC passthrough audio into an .mp4.
        try? FileManager.default.removeItem(at: output)
        let writer = try stage("AVAssetWriter(init)", { try AVAssetWriter(outputURL: output, fileType: .mp4) })
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        guard writer.canAdd(videoInput) else { throw SpikeError.msg("writer rejected the H.264 video input") }
        writer.add(videoInput)

        let reader = try stage("AVAssetReader(init)", { try AVAssetReader(asset: source) })
        // `outputSettings: nil` → the stored AAC packets, copied through untouched
        // (lossless, and no encoder priming added on top of the source's).
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        guard reader.canAdd(readerOutput) else { throw SpikeError.msg("reader rejected the audio track output") }
        reader.add(readerOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormat)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw SpikeError.msg("writer rejected the AAC passthrough input") }
        writer.add(audioInput)

        guard reader.startReading() else {
            throw SpikeError.msg("reader.startReading() failed: \(String(describing: reader.error))")
        }
        guard writer.startWriting() else {
            throw SpikeError.msg("writer.startWriting() failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw SpikeError.msg("adaptor vended no pixel-buffer pool") }

        // ---- One single-threaded interleaving pump. Feeding one input to
        // exhaustion before the other deadlocks: `isReadyForMoreMediaData` goes
        // false on whichever input runs ahead, and only the *other* input's data
        // clears it. So always service whichever input is ready, and only sleep
        // when neither is.
        var frame = 0
        var videoDone = false
        var audioDone = false
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            var progressed = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                if frame < frameCount {
                    let index = frame
                    try autoreleasepool {
                        let buffer = try makeFrame(
                            pool: pool,
                            cardImage: cardImage,
                            revealFraction: Double(index) / Double(frameCount)
                        )
                        let time = CMTime(value: CMTimeValue(index), timescale: fps)
                        guard adaptor.append(buffer, withPresentationTime: time) else {
                            throw SpikeError.msg("adaptor.append(frame \(index)) failed: \(String(describing: writer.error))")
                        }
                    }
                    frame += 1
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                progressed = true
            }

            if !audioDone, audioInput.isReadyForMoreMediaData {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else {
                        throw SpikeError.msg("audioInput.append() failed: \(String(describing: writer.error))")
                    }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }

            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw SpikeError.msg("finishWriting() left status \(writer.status.rawValue): \(String(describing: writer.error))")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        return Measurement(
            output: output,
            frameCount: frameCount,
            audioDuration: audioDuration,
            renderSeconds: Date().timeIntervalSince(startedAt),
            byteCount: (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        )
    }

    /// One frame: the still card blitted in, plus the reveal drawn for this
    /// frame's playback position.
    private static func makeFrame(pool: CVPixelBufferPool, cardImage: CGImage, revealFraction: Double) throws -> CVPixelBuffer {
        var vended: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &vended) == kCVReturnSuccess,
              let buffer = vended else {
            throw SpikeError.msg("the pixel-buffer pool could not vend a buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw SpikeError.msg("could not wrap the pixel buffer in a CGContext")
        }

        // P1 (§4A): make the drawing space EXPLICITLY top-left origin / y-down
        // (UIKit-like), so nothing renders upside down. Images go through
        // `drawTopLeft`, which locally undoes the flip the way `UIImage.draw` does.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high

        context.setFillColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))

        let cardWidth = size.width * 0.86
        let cardHeight = cardWidth * CGFloat(cardImage.height) / CGFloat(cardImage.width)
        let cardRect = CGRect(
            x: (size.width - cardWidth) / 2,
            y: (size.height - cardHeight) / 2 - size.height * 0.05,
            width: cardWidth,
            height: cardHeight
        )
        drawTopLeft(cardImage, in: cardRect, into: context)

        // A reveal bar: proves per-frame drawing lands where the geometry says,
        // and (S2's real assertion) that coverage grows left→right over time.
        let track = CGRect(x: cardRect.minX, y: cardRect.maxY + 72, width: cardWidth, height: 18)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.22)
        context.fill(track)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        context.fill(CGRect(x: track.minX, y: track.minY,
                            width: track.width * CGFloat(revealFraction), height: track.height))

        return buffer
    }

    /// Draw `image` upright into a top-left-origin, y-down context.
    private static func drawTopLeft(_ image: CGImage, in rect: CGRect, into context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

// MARK: - Frame inspection helpers

private enum FrameProbe {
    /// Decode one frame from an *exported* `.mp4` with **zero** time tolerance, so
    /// the frame we inspect is the frame at `time` and not a neighbour (§5 S2).
    static func image(from url: URL, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? RenderProofSpike.SpikeError.msg("no frame at \(time.seconds)s"))
                }
            }
        }
    }

    /// Mean relative luminance (0…1) over a downsampled grid — the "is this frame
    /// actually black?" probe a purely structural test can't make.
    static func meanBrightness(of image: CGImage, grid: Int = 48) -> Double {
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        return pixels.withUnsafeMutableBytes { raw -> Double in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: grid, height: grid,
                bitsPerComponent: 8, bytesPerRow: grid * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            let bytes = raw.bindMemory(to: UInt8.self)
            var total = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                total += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
            }
            return total / (255.0 * Double(grid * grid))
        }
    }
}

// MARK: - The proof

@Suite("M13 S0 — render proof (throwaway spike)")
struct S0VideoRenderProofSpikeTests {

    /// One capsule + its real, decodable AAC clip, built on the main actor —
    /// exercising §4F's boundary: `ImageRenderer` is `@MainActor`, so the card is
    /// frozen to a `CGImage` there and only value types cross to the renderer.
    @MainActor
    private static func fixture(in directory: URL, seconds: Double) throws -> (audio: URL, card: CGImage) {
        let audioStore = AudioStore(directory: directory)
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: seconds)

        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.audioData = try Data(contentsOf: audioStore.url(for: fileName))
        capsule.durationSeconds = seconds
        capsule.waveformSamples = (0..<48).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 0.4))) }
        capsule.note = "the sound of the spike"
        capsule.mood = .calm

        guard let card = CapsuleExporter.cardImage(for: capsule, scale: 3)?.cgImage else {
            throw RenderProofSpike.SpikeError.msg("ShareCardView produced no CGImage")
        }
        return (audioStore.url(for: fileName), card)
    }

    @Test("AVAssetWriter exports a real H.264 1080×1920 .mp4 with synced audio and a non-black first frame")
    func renderProof() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "S0-RenderProof-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixture = try await MainActor.run { try Self.fixture(in: directory, seconds: 1.0) }
        let output = directory.appending(path: "spike.mp4", directoryHint: .notDirectory)

        // ---- 1. It renders at all, off the main actor, without throwing.
        let measurement = try await RenderProofSpike.render(
            audioURL: fixture.audio,
            cardImage: fixture.card,
            to: output
        )
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(measurement.byteCount > 0)

        // ---- 2. Structure: exactly one video + one audio track, H.264, 1080×1920.
        let exported = AVURLAsset(url: output)
        let videoTracks = try await exported.loadTracks(withMediaType: .video)
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1, "expected exactly one video track, got \(videoTracks.count)")
        #expect(audioTracks.count == 1, "expected exactly one audio track, got \(audioTracks.count)")

        let videoTrack = try #require(videoTracks.first)
        let codec = try await videoTrack.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_H264, "video codec was \(codec.map(String.init) ?? "nil"), not H.264")

        let naturalSize = try await videoTrack.load(.naturalSize)
        #expect(naturalSize == CGSize(width: 1080, height: 1920))

        // ---- 3. Sync: keyed to the LOADED audio-track duration, ± one frame (§4B).
        let videoDuration = try await videoTrack.load(.timeRange).duration
        let sourceAudioDuration = measurement.audioDuration
        let frameSeconds = measurement.frameDuration.seconds
        let drift = abs(videoDuration.seconds - sourceAudioDuration.seconds)
        #expect(drift <= frameSeconds,
                "video \(videoDuration.seconds)s vs source audio \(sourceAudioDuration.seconds)s drifts \(drift)s (> one \(frameSeconds)s frame)")

        // The muxed AAC keeps the source's own packet timing; allow the container's
        // priming/rounding slack, which one frame is too tight for.
        let exportedAudioDuration = try await #require(audioTracks.first).load(.timeRange).duration
        #expect(abs(exportedAudioDuration.seconds - sourceAudioDuration.seconds) < 0.1,
                "exported audio \(exportedAudioDuration.seconds)s vs source \(sourceAudioDuration.seconds)s")

        let assetDuration = try await exported.load(.duration)
        #expect(assetDuration.seconds >= videoDuration.seconds - frameSeconds)

        // ---- 4. Content: the first frame is NOT black. A structural test alone
        // goes green on an all-black export, which is the exact failure mode of
        // the rejected CoreAnimationTool path (§4A/§7).
        let firstFrame = try await FrameProbe.image(from: output, at: .zero)
        let firstBrightness = FrameProbe.meanBrightness(of: firstFrame)
        #expect(firstFrame.width == 1080 && firstFrame.height == 1920)
        #expect(firstBrightness > 0.05, "first frame mean luminance \(firstBrightness) — the export is black")

        // ---- 5. And the reveal actually moves: coverage at the end > at the start.
        let lastTime = CMTimeSubtract(videoDuration, measurement.frameDuration)
        let lastFrame = try await FrameProbe.image(from: output, at: lastTime)
        let lastBrightness = FrameProbe.meanBrightness(of: lastFrame)
        #expect(lastBrightness > firstBrightness,
                "reveal did not brighten: first \(firstBrightness), last \(lastBrightness)")

        // ---- Measurements feeding §8's duration-cap call and §4G's preflight
        // constant. Printed (not asserted) — they are data, not a pass/fail bar.
        print("""
        S0_MEASUREMENT \
        frames=\(measurement.frameCount) \
        audioDuration=\(String(format: "%.3f", sourceAudioDuration.seconds))s \
        renderSeconds=\(String(format: "%.3f", measurement.renderSeconds)) \
        realtimeFactor=\(String(format: "%.2f", measurement.realtimeFactor))x \
        bytes=\(measurement.byteCount) \
        bytesPerSecond=\(Int(measurement.bytesPerSecond)) \
        firstFrameLuma=\(String(format: "%.3f", firstBrightness)) \
        lastFrameLuma=\(String(format: "%.3f", lastBrightness))
        """)
    }
}
