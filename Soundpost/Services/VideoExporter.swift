import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit
import os

// MARK: - Configuration

/// Output format for a shareable capsule video (M13 §4D).
///
/// v1 is **vertical 1080×1920 / 30 fps / H.264 + AAC** — confirmed 2026-07-29, and
/// keyed to the Stories/Reels aspect the feature's whole point rests on. Other
/// ratios and templates are deliberately out of scope (§11); this stays a value
/// type so adding one later is a new constant, not a new code path.
struct VideoExportConfiguration: Equatable, Sendable {
    var width: Int = 1080
    var height: Int = 1920
    var frameRate: Int32 = 30
    /// Target average bitrate handed to the H.264 encoder. Near-static content
    /// encodes far under this (S0 measured ≈ 620 kbps at 4 Mbps target), so it is a
    /// quality ceiling rather than a size prediction — §4G's preflight uses its own
    /// measured constant.
    var averageBitRate: Int = 4_000_000

    /// **Measured** output bytes per second of audio for this preset, *with* the
    /// reveal drawing (M13 S2 measured ≈219 KB/s on the simulator's software
    /// encoder — about 3× the still-card figure, because the moving bars cost real
    /// bitrate; rounded up here). Per-preset so a future format carries its own
    /// number instead of inheriting this one.
    var measuredBytesPerSecond: Int64 = 230_000

    /// Above this estimate, ask before starting (§4G). ≈2:54 of audio at the
    /// measured rate, so only genuinely long clips ever see the prompt — a
    /// ten-second capsule is never nagged.
    var warnAboveByteCount: Int64 = 40_000_000

    static let vertical1080x1920 = VideoExportConfiguration()

    var pixelSize: CGSize { CGSize(width: width, height: height) }
    var frameDuration: CMTime { CMTime(value: 1, timescale: frameRate) }

    /// Estimated output size — **arithmetic only** (§1.4 / §4G / §6).
    ///
    /// Soundpost deliberately never asks how much free disk space there is:
    /// `FileManager`'s volume-capacity keys are a **Required-Reason API**
    /// (`NSPrivacyAccessedAPICategoryDiskSpace`) that would have to be declared in
    /// `PrivacyInfo.xcprivacy`. That is a real privacy cost for a warning we can
    /// give from duration × a measured constant, so we do it with arithmetic.
    ///
    /// Note this takes the capsule's *stored* duration on purpose: the point is to
    /// warn **before** doing any work. The render itself is always keyed to the
    /// loaded audio-track duration (§4B) and never to this number.
    func estimatedByteCount(forDuration seconds: Double) -> Int64 {
        Int64(max(0, seconds) * Double(measuredBytesPerSecond))
    }

    func needsSizeWarning(forDuration seconds: Double) -> Bool {
        estimatedByteCount(forDuration: seconds) > warnAboveByteCount
    }
}

// MARK: - Tint

/// A capsule's mood tint, resolved once to plain components so it can cross to the
/// background renderer as a value (§4F) — and resolved against a **fixed light**
/// trait so the exported video looks the same whatever the device's appearance was
/// at render time (the same determinism `ShareCardView` relies on).
struct VideoTint: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// System blue — the app's untinted fallback when a mood has no resolvable color.
    static let fallback = VideoTint(red: 0.0, green: 0.478, blue: 1.0)

    /// Resolve the colour this capsule's video should be drawn in.
    ///
    /// A user's custom colour (M14) is already concrete sRGB, so it is used as-is.
    /// Otherwise the mood's *semantic* default is flattened against a fixed light
    /// trait. Either way this reads the **stored palette, never `isPro`** — which is
    /// what keeps a video exported after a lapse looking like the one exported
    /// before it (M13 §11 / M14 §4D).
    static func resolved(from mood: Mood?, palette: MoodPalette) -> VideoTint {
        if let mood, let override = palette.overrides[mood] {
            let legible = override.legible
            return VideoTint(red: legible.red, green: legible.green, blue: legible.blue)
        }
        let color = UIColor(mood?.defaultTint ?? Color.accentColor)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .fallback }
        return VideoTint(red: Double(red), green: Double(green), blue: Double(blue))
    }

    func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// A dark, faintly tinted ground the near-white card reads well against.
    var backgroundTop: CGColor {
        CGColor(red: 0.05 + red * 0.20, green: 0.05 + green * 0.20, blue: 0.06 + blue * 0.20, alpha: 1)
    }

    var backgroundBottom: CGColor {
        CGColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1)
    }
}

// MARK: - Layout

/// Where the pieces sit inside one video frame — pure and `Equatable` so the frame
/// tests can name the exact card / waveform rectangles they sample (§5 S2) instead
/// of guessing at pixel coordinates.
///
/// Top-left origin, y-down, matching `WaveformGeometry` and the renderer's context.
struct VideoFrameLayout: Equatable, Sendable {
    let size: CGSize
    /// The branded `ShareCardView` raster.
    let card: CGRect
    /// The single animated waveform, below the card.
    let waveform: CGRect

    /// The card's pixel width for a configuration — independent of the card's own
    /// aspect ratio, so it can be known *before* the card is rasterised (which is
    /// what lets `ImageRenderer` render at exactly 1:1 with no resampling).
    static func cardWidth(for configuration: VideoExportConfiguration) -> CGFloat {
        (configuration.pixelSize.width * 0.84).rounded()
    }

    init(configuration: VideoExportConfiguration, cardAspectRatio: CGFloat) {
        let size = configuration.pixelSize
        let cardWidth = Self.cardWidth(for: configuration)
        let safeAspect = cardAspectRatio > 0 ? cardAspectRatio : 1
        // Never let a tall card (a long note) push the block past the canvas.
        let cardHeight = min((cardWidth / safeAspect).rounded(), size.height * 0.62)
        let waveformHeight = (size.height * 0.085).rounded()
        let gap = (size.height * 0.032).rounded()
        let top = ((size.height - (cardHeight + gap + waveformHeight)) / 2).rounded()
        let left = ((size.width - cardWidth) / 2).rounded()

        self.size = size
        self.card = CGRect(x: left, y: top, width: cardWidth, height: cardHeight)
        self.waveform = CGRect(x: left, y: top + cardHeight + gap, width: cardWidth, height: waveformHeight)
    }

    /// Bar geometry scaled for the video canvas. The on-screen card uses 2-pt
    /// spacing at 360 pt wide; the same *proportions* at 1080 px would be invisible,
    /// so the video scales them — same math (`WaveformGeometry`), bigger units.
    var waveformGeometry: WaveformGeometry {
        let scale = size.width / 360
        return WaveformGeometry(barSpacing: (2 * scale).rounded(), minBarHeight: (3 * scale).rounded())
    }
}

// MARK: - Workspace (temp lifecycle)

/// Owns the on-disk lifetime of one export run (§4G / Codex #9).
///
/// Every run gets its **own uniquely-named directory** under a container we own,
/// which fixes three things at once: `CapsuleExporter`'s date-only temp filename
/// could collide between runs; a rendered `.mp4` must survive until the share sheet
/// actually finishes with it; and a crash or a share sheet that never reports
/// completion must not leak files forever.
///
/// Cleanup only ever removes **children of our own container** — never a parent,
/// and never anything else in `tmp`. (M13 S0 found an M12 test that deleted
/// `folder.deletingLastPathComponent()` and so wiped the whole temporary
/// directory; that is the mistake this API is shaped to make impossible.)
struct VideoExportWorkspace: Equatable, Sendable {
    /// The one directory we own inside `tmp`.
    static let containerName = "SoundpostVideoExports"

    let directory: URL

    static func container(inTemporaryDirectory root: URL = FileManager.default.temporaryDirectory) -> URL {
        root.appending(path: containerName, directoryHint: .isDirectory)
    }

    /// A fresh directory for one export run.
    static func makeUnique(
        inTemporaryDirectory root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> VideoExportWorkspace {
        let directory = container(inTemporaryDirectory: root)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return VideoExportWorkspace(directory: directory)
    }

    func url(named name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Delete this run's directory — on share completion, failure, or cancel.
    func clean(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }

    /// Remove export directories left behind by a previous launch (a crash, a kill,
    /// or a share sheet that never called back). Called once at launch, where
    /// nothing is in flight; `olderThan` exists so it is safe to call at any time.
    ///
    /// Returns how many directories it removed, so it is testable rather than
    /// silently best-effort.
    @discardableResult
    static func scavenge(
        olderThan age: TimeInterval = 0,
        now: Date = .now,
        inTemporaryDirectory root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        let container = container(inTemporaryDirectory: root)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) >= age else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - Errors

/// Developer-facing render failures. Deliberately **not** `LocalizedError`: the
/// user-visible copy is one honest, localized alert owned by the view (S4), so
/// these carry no translatable strings and no PII.
enum VideoExportError: Error, Equatable, CustomStringConvertible {
    case noAudioToRender
    case audioTrackMissing
    case audioFormatMissing
    case cardImageUnavailable
    case writerRejectedInput(String)
    case writerFailed(String)
    case pixelBufferUnavailable

    var description: String {
        switch self {
        case .noAudioToRender: "the capsule has no audio to render"
        case .audioTrackMissing: "the source audio file has no audio track"
        case .audioFormatMissing: "the source audio track has no format description"
        case .cardImageUnavailable: "the share card produced no image"
        case .writerRejectedInput(let which): "AVAssetWriter rejected the \(which) input"
        case .writerFailed(let stage): "the writer failed during \(stage)"
        case .pixelBufferUnavailable: "no drawable pixel buffer was available"
        }
    }
}

// MARK: - Input / Result

/// Everything the renderer needs, **frozen once** before it leaves the main actor.
///
/// `ImageRenderer` and SwiftUI are `@MainActor`, so the branded card is rasterised
/// there and only the finished `CGImage` plus value types cross to the background
/// renderer (§4F). The `CGImage` is the one non-`Sendable` member: it is immutable
/// and never touched on the main actor again after this is built, which is the
/// hand-off the Swift 6 flip will need to annotate (§11).
///
/// It is also the *only* thing the render reads. Nothing here is re-derived from
/// the model, the entitlement, or the clock mid-render — the eligibility decision
/// is taken once, before this exists (§4E).
struct VideoExportInput {
    let audioURL: URL
    let outputURL: URL
    let card: CGImage
    let samples: [Float]
    let tint: VideoTint
    let configuration: VideoExportConfiguration

    var layout: VideoFrameLayout {
        VideoFrameLayout(
            configuration: configuration,
            cardAspectRatio: CGFloat(card.width) / CGFloat(max(card.height, 1))
        )
    }
}

struct VideoExportResult: Equatable, Sendable {
    let url: URL
    let frameCount: Int
    /// The authoritative duration: loaded from the source audio **track**, never a
    /// stored `Capsule.durationSeconds` (§4B).
    let duration: CMTime
    let byteCount: Int64
}

// MARK: - Exporter

/// Renders a capsule to a branded, shareable `.mp4`: the card, with its waveform
/// revealing in time with the audio (M13).
///
/// **Path (§4A):** `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` for the
/// video track, muxed with the capsule's own AAC read through `AVAssetReader`. Not
/// `AVVideoCompositionCoreAnimationTool` — an audio-only composition has no frames
/// for it to post-process, so that path exports black, and its supporting APIs are
/// deprecated on the iOS 26 SDK. This path is iOS-17-safe, warning-free,
/// deterministic enough to unit-test, and memory-bounded by the writer's pool.
///
/// Nothing leaves the device: the file is written to a temp workspace the caller
/// owns and goes only where the user explicitly shares it (§6).
enum VideoExporter {
    static let logger = Logger(subsystem: "com.soundpost.Soundpost", category: "videoexport")

    /// Cap on live pixel buffers. The loop appends and releases one frame at a time,
    /// so this is never reached in practice — it is a ceiling that makes "peak
    /// memory is a handful of frames" a property of the code rather than a hope.
    private static let poolAllocationThreshold = 6

    // MARK: Main-actor preparation

    /// Freeze `capsule` into a render input inside `workspace`. Main-actor because
    /// rasterising the card is (§4F); everything after this is off-main.
    ///
    /// Throws `.noAudioToRender` for a capsule with no usable clip — the caller
    /// surfaces that honestly rather than exporting a silent video.
    @MainActor
    static func input(
        for capsule: Capsule,
        in workspace: VideoExportWorkspace,
        configuration: VideoExportConfiguration = .vertical1080x1920,
        audioStore: AudioStore = AudioStore()
    ) throws -> VideoExportInput {
        guard let audioURL = try audioFileURL(for: capsule, in: workspace, audioStore: audioStore) else {
            throw VideoExportError.noAudioToRender
        }
        let cardWidth = VideoFrameLayout.cardWidth(for: configuration)
        guard let card = cardImage(for: capsule, targetWidth: cardWidth)?.cgImage else {
            throw VideoExportError.cardImageUnavailable
        }
        return VideoExportInput(
            audioURL: audioURL,
            outputURL: workspace.url(named: outputFileName(for: capsule)),
            card: card,
            samples: capsule.waveformSamples,
            tint: VideoTint.resolved(from: capsule.mood, palette: .current),
            configuration: configuration
        )
    }

    /// The video's branded card: the same `ShareCardView` the image share uses, with
    /// its decorative waveform off and the note capped, so the fixed canvas can't
    /// be overrun by a long or heavily-localized line (§4C).
    @MainActor
    static func cardImage(for capsule: Capsule, targetWidth: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(
            content: ShareCardView(capsule: capsule, showsWaveform: false, noteLineLimit: 4)
        )
        // `ShareCardView` is a fixed 360 pt wide; render it at exactly the pixel
        // width it will occupy so no resampling softens the text.
        renderer.scale = max(1, targetWidth / 360)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Copy the capsule's clip into the run's own directory. Unique by
    /// construction, so it cannot collide with a concurrent or previous export the
    /// way a shared date-only filename can (§3).
    @MainActor
    private static func audioFileURL(
        for capsule: Capsule,
        in workspace: VideoExportWorkspace,
        audioStore: AudioStore
    ) throws -> URL? {
        let destination = workspace.url(named: "source.m4a")
        if let data = capsule.audioData {
            try data.write(to: destination, options: .atomic)
            return destination
        }
        if let name = capsule.audioFileName, audioStore.fileExists(name) {
            try FileManager.default.copyItem(at: audioStore.url(for: name), to: destination)
            return destination
        }
        return nil
    }

    /// A friendly name for the share sheet. Safe to repeat across runs now that
    /// each run owns its own directory.
    static func outputFileName(for capsule: Capsule) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Soundpost-\(formatter.string(from: capsule.createdAt)).mp4"
    }

    // MARK: Render

    /// Render `input` to its `outputURL`. Runs off the main actor; honours task
    /// cancellation between frames and reports determinate progress (0…1).
    ///
    /// On any failure or cancellation the writer is cancelled and the partial file
    /// removed, so a failed export never leaves a half-written `.mp4` behind for
    /// the share sheet to find.
    static func export(
        _ input: VideoExportInput,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoExportResult {
        let configuration = input.configuration

        // ---- Source audio. The LOADED track duration is authoritative (§4B):
        // `Capsule.durationSeconds` is a stored Double that can differ from the
        // real track by AAC priming/rounding, and keying the composition to it
        // would drift the reveal against the sound.
        let source = AVURLAsset(url: input.audioURL)
        guard let audioTrack = try await source.loadTracks(withMediaType: .audio).first else {
            throw VideoExportError.audioTrackMissing
        }
        let duration = try await audioTrack.load(.timeRange).duration
        guard let sourceFormat = try await audioTrack.load(.formatDescriptions).first else {
            throw VideoExportError.audioFormatMissing
        }
        let frameCount = max(1, Int((duration.seconds * Double(configuration.frameRate)).rounded()))

        // ---- Writer + reader.
        try? FileManager.default.removeItem(at: input.outputURL)
        let writer = try AVAssetWriter(outputURL: input.outputURL, fileType: .mp4)
        // Front-load the index so a shared file starts playing without a full download.
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.averageBitRate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int(configuration.frameRate) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: configuration.width,
                kCVPixelBufferHeightKey as String: configuration.height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        guard writer.canAdd(videoInput) else { throw VideoExportError.writerRejectedInput("H.264 video") }
        writer.add(videoInput)

        let reader = try AVAssetReader(asset: source)
        // `outputSettings: nil` passes the stored AAC packets through untouched —
        // lossless, cheap, and it adds no second round of encoder priming.
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        guard reader.canAdd(readerOutput) else { throw VideoExportError.writerRejectedInput("audio reader") }
        reader.add(readerOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormat)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw VideoExportError.writerRejectedInput("AAC audio") }
        writer.add(audioInput)

        guard reader.startReading() else { throw VideoExportError.writerFailed("reader start") }
        guard writer.startWriting() else { throw VideoExportError.writerFailed("writer start") }
        writer.startSession(atSourceTime: .zero)
        logger.info("video export started: \(frameCount, privacy: .public) frames")

        do {
            // Inside the `do` on purpose: the pool only exists once the writer has
            // started, which is also the moment the output file starts existing. A
            // throw from here has to go through the cleanup path like any other, or
            // it would leave a zero-byte .mp4 behind.
            guard let pool = adaptor.pixelBufferPool else { throw VideoExportError.pixelBufferUnavailable }
            let composer = try FrameComposer(input: input)
            try await pump(
                videoInput: videoInput,
                adaptor: adaptor,
                pool: pool,
                audioInput: audioInput,
                readerOutput: readerOutput,
                frameCount: frameCount,
                frameRate: configuration.frameRate,
                duration: duration,
                composer: composer,
                progress: progress
            )
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw VideoExportError.writerFailed("finish (status \(writer.status.rawValue))")
            }
        } catch {
            // A half-written .mp4 must never reach the share sheet. This is the
            // cancellation path too — a user cancel arrives here as `CancellationError`,
            // and leaves nothing behind either.
            //
            // Two mechanisms, deliberately kept both: `cancelWriting()` discards the
            // file the writer owns, and the unlink covers the cases where it does not —
            // a failure after `finishWriting`, or a writer already out of `.writing`.
            // On the cancel path they are redundant, and it is `cancelWriting()` that
            // does the removing: deleting the unlink alone leaves the test green
            // (measured 2026-09-05). Neither line is dead; whichever is dropped, the
            // other still has to be the one that covers its own case.
            if writer.status == .writing { writer.cancelWriting() }
            reader.cancelReading()
            try? FileManager.default.removeItem(at: input.outputURL)
            if error is CancellationError {
                logger.info("video export cancelled")
            } else {
                // Log the shape of the failure, never a raw error string: those can
                // carry file URLs. `VideoExportError`'s descriptions are static.
                let reason = (error as? VideoExportError)?.description ?? "\(type(of: error))"
                logger.error("video export failed: \(reason, privacy: .public)")
            }
            throw error
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: input.outputURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        logger.info("video export finished: \(byteCount, privacy: .public) bytes")
        return VideoExportResult(
            url: input.outputURL,
            frameCount: frameCount,
            duration: duration,
            byteCount: byteCount
        )
    }

    /// One single-threaded loop that services whichever writer input is ready.
    ///
    /// **This shape is load-bearing** (found in S0): feeding one input to
    /// exhaustion deadlocks, because `isReadyForMoreMediaData` goes false on
    /// whichever input runs ahead and is only cleared by the *other* input's data.
    /// Servicing whichever is ready — and sleeping only when neither is — also
    /// keeps peak memory at one frame and makes cancellation immediate.
    private static func pump(
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        pool: CVPixelBufferPool,
        audioInput: AVAssetWriterInput,
        readerOutput: AVAssetReaderTrackOutput,
        frameCount: Int,
        frameRate: Int32,
        duration: CMTime,
        composer: FrameComposer,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let totalSeconds = duration.seconds
        var frame = 0
        var videoDone = false
        var audioDone = false
        var reportedPercent = -1

        while !videoDone || !audioDone {
            // The cancellation point that carries the *promptness* promise: a user's
            // Cancel lands here between frames, so it takes effect within one frame's
            // work rather than at the end of the render.
            //
            // It is not the only place cancellation can surface — the back-pressure
            // `Task.sleep` below throws `CancellationError` too, and with this line
            // deleted a cancel still eventually escapes through it. So a test that only
            // asserts "cancel throws" cannot tell you this line is here; what it
            // protects is *when*, not *whether* (measured 2026-09-05).
            try Task.checkCancellation()
            var progressed = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                if frame < frameCount {
                    let index = frame
                    // `nil` means the pool is momentarily at its allocation ceiling —
                    // not an error. Fall through without advancing so the loop waits
                    // and retries, which is what keeps memory bounded under back
                    // pressure instead of failing the export.
                    if let buffer = try vendPixelBuffer(from: pool) {
                        try autoreleasepool {
                            // The reveal's position is `t / audioTrackDuration` — the
                            // loaded track's duration, so the sweep lands on the sound
                            // rather than on a stored approximation of it (§4B).
                            let seconds = Double(index) / Double(frameRate)
                            let fraction = totalSeconds > 0 ? min(1, seconds / totalSeconds) : 1
                            try composer.render(into: buffer, playbackFraction: fraction)
                            let time = CMTime(value: CMTimeValue(index), timescale: frameRate)
                            guard adaptor.append(buffer, withPresentationTime: time) else {
                                throw VideoExportError.writerFailed("video frame \(index)")
                            }
                        }
                        frame += 1
                        // Report at most once per whole percent: a 5-minute clip is
                        // ~9 000 frames, and one main-actor hop per frame would cost
                        // more than the encoding.
                        let percent = frame * 100 / frameCount
                        if percent != reportedPercent {
                            reportedPercent = percent
                            progress?(Double(frame) / Double(frameCount))
                        }
                        progressed = true
                    }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                    progressed = true
                }
            }

            if !audioDone, audioInput.isReadyForMoreMediaData {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else {
                        throw VideoExportError.writerFailed("audio sample")
                    }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }

            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }
    }

    /// Take a frame buffer from the writer's pool, bounded by
    /// `poolAllocationThreshold`.
    ///
    /// Returns `nil` — not an error — when the pool is at its ceiling, so the caller
    /// can wait instead of failing. That is what makes the memory bound real: the
    /// render slows down under pressure rather than growing.
    private static func vendPixelBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer? {
        var vended: CVPixelBuffer?
        let auxiliary = [
            kCVPixelBufferPoolAllocationThresholdKey as String: poolAllocationThreshold
        ] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &vended)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let buffer = vended else {
            throw VideoExportError.pixelBufferUnavailable
        }
        return buffer
    }
}

// MARK: - Frame composition

/// Composes video frames.
///
/// The still parts — the tinted ground, the branded card, and the waveform in its
/// **unplayed** state — are drawn **once** into a cached image. Each frame is then
/// that image blitted in, plus only the bars the playhead has already passed
/// repainted at full tint. So a 5-minute clip's ~9 000 frames cost a memcpy, a few
/// dozen small rounded rects, and an encode each — not 9 000 full re-renders (§4A).
final class FrameComposer {
    private let layout: VideoFrameLayout
    private let tint: VideoTint
    /// Bar rectangles, computed once: they are identical in every frame, and only
    /// each bar's *colour* depends on the playhead.
    private let bars: [WaveformGeometry.Bar]
    private let still: CGImage

    /// 32-bit BGRA with the alpha byte ignored — the pixel format the writer's
    /// adaptor is configured for, and a layout `CGContext` accepts directly.
    private static let bitmapInfo =
        CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(input: VideoExportInput) throws {
        let layout = input.layout
        self.layout = layout
        self.tint = input.tint
        self.bars = layout.waveformGeometry.bars(for: input.samples, in: layout.waveform.size)
        self.still = try Self.makeStill(input: input, layout: layout, bars: bars)
    }

    /// Draw the frame for `playbackFraction` (0…1) into `buffer`.
    func render(into buffer: CVPixelBuffer, playbackFraction: Double) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: Self.bitmapInfo
              ) else {
            throw VideoExportError.pixelBufferUnavailable
        }
        Self.makeTopLeft(context, height: CGFloat(height))
        Self.drawTopLeft(still, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), into: context)
        drawReveal(playbackFraction: playbackFraction, into: context)
    }

    // MARK: Reveal

    /// Repaint the bars behind the playhead at full tint, and mark the playhead
    /// itself with one thin line.
    ///
    /// A gentle left→right position sweep, nothing more (§1.3): no pulsing, no
    /// bouncing, no reaction to the audio's content — the bar lights up because the
    /// playhead reached it.
    private func drawReveal(playbackFraction: Double, into context: CGContext) {
        guard !bars.isEmpty else { return }
        let fraction = min(max(playbackFraction, 0), 1)

        context.saveGState()
        context.translateBy(x: layout.waveform.minX, y: layout.waveform.minY)

        // One path for every played bar, one fill. `isPlayed` is monotonic in the
        // index, so the first unplayed bar ends the run.
        context.setFillColor(tint.cgColor())
        for (index, bar) in bars.enumerated() {
            guard WaveformGeometry.isPlayed(index: index, count: bars.count, progress: fraction) else { break }
            let radius = WaveformGeometry.clampedCornerRadius(bar)
            context.addPath(CGPath(roundedRect: bar.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()

        let playheadWidth = max(2, (layout.size.width / 360).rounded())
        let x = min(max(0, layout.waveform.width * CGFloat(fraction)), layout.waveform.width - playheadWidth)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: x, y: 0, width: playheadWidth, height: layout.waveform.height))

        context.restoreGState()
    }

    // MARK: Still

    private static func makeStill(
        input: VideoExportInput,
        layout: VideoFrameLayout,
        bars: [WaveformGeometry.Bar]
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: Int(layout.size.width),
            height: Int(layout.size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw VideoExportError.pixelBufferUnavailable
        }
        makeTopLeft(context, height: layout.size.height)
        context.interpolationQuality = .high

        drawBackground(tint: input.tint, size: layout.size, into: context)
        drawTopLeft(input.card, in: layout.card, into: context)
        drawUnplayedWaveform(bars: bars, tint: input.tint, in: layout.waveform, into: context)

        guard let image = context.makeImage() else { throw VideoExportError.pixelBufferUnavailable }
        return image
    }

    private static func drawBackground(tint: VideoTint, size: CGSize, into context: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [tint.backgroundTop, tint.backgroundBottom] as CFArray,
            locations: [0, 1]
        ) else {
            context.setFillColor(tint.backgroundBottom)
            context.fill(CGRect(origin: .zero, size: size))
            return
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: size.height),
            options: []
        )
    }

    /// The waveform in its **unplayed** state — every bar dimmed. This is baked into
    /// the cached still; each frame then repaints only the bars behind the playhead
    /// at full tint. The dim/bright pair is the same 1.0 / 0.25-ish contrast the
    /// on-screen `WaveformView` uses for playback progress, so the video reads like
    /// the app rather than like a different product.
    private static func drawUnplayedWaveform(
        bars: [WaveformGeometry.Bar],
        tint: VideoTint,
        in rect: CGRect,
        into context: CGContext
    ) {
        guard !bars.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.setFillColor(tint.cgColor(alpha: 0.28))
        for bar in bars {
            let radius = WaveformGeometry.clampedCornerRadius(bar)
            context.addPath(CGPath(
                roundedRect: bar.rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
        }
        context.fillPath()
        context.restoreGState()
    }

    // MARK: Coordinate space

    /// Flip `context` to an **explicit top-left origin, y-down** space (UIKit-like)
    /// so nothing renders upside down and one set of geometry serves both the
    /// on-screen `Canvas` and the video (§4A / workflow #4).
    private static func makeTopLeft(_ context: CGContext, height: CGFloat) {
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
    }

    /// Draw an image upright inside a top-left, y-down context by locally undoing
    /// the flip — the same thing `UIImage.draw(in:)` does.
    private static func drawTopLeft(_ image: CGImage, in rect: CGRect, into context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
