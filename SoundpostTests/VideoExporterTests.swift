import Testing
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI
import UIKit
@testable import Soundpost

/// `import SwiftUI` (needed for `ImageRenderer`) also brings in SwiftUI's `Capsule`
/// shape, which collides with the app's model of the same name. Inside the app
/// module the model wins by scope; from the test module it has to be named.
private typealias Capsule = Soundpost.Capsule

/// The headless video render path (M13 §5 S1). CI-safe: everything here runs on a
/// simulator, and the assertions are structural **plus** pixel content — S0 proved
/// a structure-only test goes green on a black export.
@MainActor
struct VideoExporterTests {

    // MARK: - Fixtures

    /// A capsule with real, decodable AAC audio, plus a scratch root that is ours to
    /// delete. Every temp path below lives under `root`, never beside it.
    private struct Fixture {
        let root: URL
        let capsule: Capsule
        let workspace: VideoExportWorkspace
    }

    private func makeFixture(seconds: Double = 1.0, note: String? = "the sound of rain") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VideoExportTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let audioStore = AudioStore(directory: root.appending(path: "audio", directoryHint: .isDirectory))
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: seconds)

        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.audioData = try Data(contentsOf: audioStore.url(for: fileName))
        // Deliberately WRONG on the model: the render must key off the loaded audio
        // track, never this stored value (§4B).
        capsule.durationSeconds = seconds * 3
        capsule.waveformSamples = (0..<48).map { Float(0.2 + 0.7 * abs(sin(Double($0) * 0.37))) }
        capsule.note = note
        capsule.mood = .calm

        return Fixture(
            root: root,
            capsule: capsule,
            workspace: try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        )
    }

    // MARK: - Structure

    @Test func exportProducesOneH264VideoTrackAndOneAudioTrack() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let input = try VideoExporter.input(for: fixture.capsule, in: fixture.workspace)
        let result = try await VideoExporter.export(input)

        #expect(result.url.pathExtension == "mp4")
        #expect(result.byteCount > 0)

        let asset = AVURLAsset(url: result.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1, "expected one video track, got \(videoTracks.count)")
        #expect(audioTracks.count == 1, "expected one audio track, got \(audioTracks.count)")

        let videoTrack = try #require(videoTracks.first)
        let codec = try await videoTrack.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_H264)
        #expect(try await videoTrack.load(.naturalSize) == CGSize(width: 1080, height: 1920))
    }

    /// The composition length comes from the **loaded audio track**, not the stored
    /// `durationSeconds` — which this fixture sets to 3× the truth on purpose.
    @Test func durationTracksTheLoadedAudioTrackNotTheStoredValue() async throws {
        let fixture = try makeFixture(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let input = try VideoExporter.input(for: fixture.capsule, in: fixture.workspace)
        let result = try await VideoExporter.export(input)

        let sourceAudio = try #require(
            try await AVURLAsset(url: input.audioURL).loadTracks(withMediaType: .audio).first
        )
        let sourceDuration = try await sourceAudio.load(.timeRange).duration
        let frameSeconds = VideoExportConfiguration.vertical1080x1920.frameDuration.seconds

        // The render's own reported duration is the track's.
        #expect(abs(result.duration.seconds - sourceDuration.seconds) < 0.0001)
        #expect(result.frameCount == 30)
        // …and nowhere near the model's (deliberately wrong) 3 s.
        #expect(abs(result.duration.seconds - fixture.capsule.durationSeconds) > 1.0)

        let exported = AVURLAsset(url: result.url)
        let videoTrack = try #require(try await exported.loadTracks(withMediaType: .video).first)
        let videoDuration = try await videoTrack.load(.timeRange).duration
        #expect(abs(videoDuration.seconds - sourceDuration.seconds) <= frameSeconds,
                "video \(videoDuration.seconds)s drifted from audio \(sourceDuration.seconds)s by more than one frame")

        // The muxed AAC keeps the source's packet timing, so it gets its own looser
        // bar — container priming/rounding puts it a few ms out (S0 finding).
        let audioTrack = try #require(try await exported.loadTracks(withMediaType: .audio).first)
        let audioDuration = try await audioTrack.load(.timeRange).duration
        #expect(abs(audioDuration.seconds - sourceDuration.seconds) < 0.1)
    }

    // MARK: - Content (the assertions a structural test can't make)

    @Test func exportedFramesAreNotBlackAndTheCardIsRightSideUp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let input = try VideoExporter.input(for: fixture.capsule, in: fixture.workspace)
        let result = try await VideoExporter.export(input)
        let layout = input.layout

        let frame = try await VideoFrameProbe.image(from: result.url, at: .zero)
        #expect(frame.width == 1080 && frame.height == 1920)

        // 1. Not black — the failure the rejected render path would have produced.
        let whole = try VideoFrameProbe.meanBrightness(of: frame)
        #expect(whole > 0.05, "the exported frame is black (mean luminance \(whole))")

        // 2. Right side up. Two independent checks, because a vertical flip is the
        //    one orientation bug the simulator *can* catch (visual legibility stays
        //    the device smoke test, §5 S2):
        //
        //    (a) the near-white card sits ABOVE the waveform on the dark ground, so
        //        its rectangle must sample clearly brighter than the waveform's;
        let cardBrightness = try VideoFrameProbe.meanBrightness(of: frame, in: layout.card)
        let waveformBrightness = try VideoFrameProbe.meanBrightness(of: frame, in: layout.waveform)
        #expect(cardBrightness > 0.5, "the card region is too dark (\(cardBrightness)) — is the frame flipped?")
        #expect(cardBrightness > waveformBrightness + 0.15,
                "card \(cardBrightness) vs waveform \(waveformBrightness): the composition looks upside down")

        //    (b) the gap between the card and the waveform is bare background, so it
        //        must be dark. Mirrored about the frame's centre that strip lands
        //        *inside* the card, so a flipped render makes it bright — a sharper
        //        signal than comparing two regions that both contain tinted ink.
        let inset: CGFloat = 6
        let gap = CGRect(
            x: layout.card.minX,
            y: layout.card.maxY + inset,
            width: layout.card.width,
            height: layout.waveform.minY - layout.card.maxY - inset * 2
        )
        #expect(gap.height > 0)
        let gapBrightness = try VideoFrameProbe.meanBrightness(of: frame, in: gap)
        #expect(gapBrightness < 0.25,
                "the card/waveform gap should be bare dark background, measured \(gapBrightness) — flipped?")
    }

    /// The reveal, asserted over the **exported file** rather than the composition
    /// that produced it (§5 S2). Frames are decoded with zero time tolerance at
    /// t = 0, three points through the clip, and `duration − frameDuration`; the lit
    /// share of the waveform region must grow at every step, while the card stays
    /// put. That is what "the waveform lights up in time with the audio" means in a
    /// form a machine can check — the *look* of it stays the device smoke test.
    @Test func theRevealSweepsLeftToRightAndOnlyEverGrows() async throws {
        let fixture = try makeFixture(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let input = try VideoExporter.input(for: fixture.capsule, in: fixture.workspace)
        let result = try await VideoExporter.export(input)

        let times: [CMTime] = [.zero]
            + [0.25, 0.5, 0.75].map { CMTimeMultiplyByFloat64(result.duration, multiplier: $0) }
            + [CMTimeSubtract(result.duration, input.configuration.frameDuration)]

        var coverage: [Double] = []
        var cardBrightness: [Double] = []
        for time in times {
            let frame = try await VideoFrameProbe.image(from: result.url, at: time)
            // Every sampled frame is a real, non-black frame.
            #expect(try VideoFrameProbe.meanBrightness(of: frame) > 0.05)
            coverage.append(try VideoFrameProbe.brightCoverage(of: frame, in: input.layout.waveform))
            cardBrightness.append(try VideoFrameProbe.meanBrightness(of: frame, in: input.layout.card))
        }

        // Thresholds sit well inside the measured behaviour (coverage runs
        // ≈0.02 → 0.14 → 0.31 → 0.45 → 0.62, card brightness holds to ±0.001), so
        // they assert the real property without going flaky on encoder jitter.

        // 1. Monotonically increasing reveal — never a step backwards.
        for (earlier, later) in zip(coverage, coverage.dropFirst()) {
            #expect(later > earlier, "reveal coverage went backwards: \(coverage)")
        }
        // 2. It is a genuine sweep, not a flicker: almost nothing lit at the start,
        //    most of the waveform lit at the end.
        #expect(coverage[0] < 0.08, "too much already lit at t=0: \(coverage)")
        #expect(coverage.last ?? 0 > 0.4, "the waveform never fills in: \(coverage)")

        // 3. The card ROI is stable — the reveal happens in its own region and must
        //    not disturb the branded card behind it.
        for value in cardBrightness.dropFirst() {
            #expect(abs(value - cardBrightness[0]) < 0.01,
                    "the card region shifted during the reveal: \(cardBrightness)")
        }
    }

    // MARK: - Honest refusals

    @Test func aCapsuleWithNoAudioCannotBeExported() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VideoExportTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.waveformSamples = [0.3, 0.6]

        let workspace = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        #expect(throws: VideoExportError.noAudioToRender) {
            _ = try VideoExporter.input(for: capsule, in: workspace)
        }
    }

    // MARK: - The video card

    @Test func theVideoCardDropsTheDecorativeWaveform() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shared = try #require(ImageRenderer(content: ShareCardView(capsule: fixture.capsule)).uiImage)
        let video = try #require(
            ImageRenderer(content: ShareCardView(capsule: fixture.capsule, showsWaveform: false)).uiImage
        )
        // The video frame draws one animated waveform in its own region, so the card
        // must not carry a second, decorative one (§4C).
        #expect(video.size.height < shared.size.height)
        #expect(shared.size.height - video.size.height >= 72)
        // The image share is untouched: still 360 pt wide, still has its waveform.
        #expect(shared.size.width == 360)
    }

    @Test func aLongNoteIsCappedSoTheVideoCardCannotOverrunTheCanvas() throws {
        let fixture = try makeFixture(note: String(repeating: "a long line about this moment ", count: 40))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let uncapped = try #require(
            ImageRenderer(content: ShareCardView(capsule: fixture.capsule, showsWaveform: false)).uiImage
        )
        let capped = try #require(
            ImageRenderer(content: ShareCardView(capsule: fixture.capsule,
                                                showsWaveform: false,
                                                noteLineLimit: 4)).uiImage
        )
        #expect(capped.size.height < uncapped.size.height)
    }

    /// The card must be light **top to bottom**, because every ink on it is a fixed
    /// dark grey chosen for a near-white ground (`ink` 0.12 / `inkSecondary` 0.42).
    ///
    /// Regression guard: the card's gradient ends in a *translucent* tint, so it needs
    /// an opaque base under it. Without one, `ImageRenderer`'s opaque backing shows
    /// through and the bottom of the card renders near-black (measured luminance
    /// 0.13), hiding the duration, the place, and the "Made with Soundpost" mark. The
    /// simulator's structural tests were all green while that was true — it took
    /// looking at an exported frame to see it (M13 S2).
    @Test func theShareCardIsLightTopToBottomSoItsInkStaysLegible() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for mood in Mood.allCases {
            fixture.capsule.mood = mood
            let card = try #require(VideoExporter.cardImage(for: fixture.capsule, targetWidth: 907)?.cgImage)
            let width = CGFloat(card.width)
            let height = CGFloat(card.height)
            let top = CGRect(x: 0, y: 0, width: width, height: height / 8)
            let bottom = CGRect(x: 0, y: height * 7 / 8, width: width, height: height / 8)

            let topLuma = try VideoFrameProbe.meanBrightness(of: card, in: top)
            let bottomLuma = try VideoFrameProbe.meanBrightness(of: card, in: bottom)
            #expect(topLuma > 0.7, "\(mood.rawValue): card top is dark (\(topLuma))")
            #expect(bottomLuma > 0.7, "\(mood.rawValue): card bottom is dark (\(bottomLuma)) — its grey ink is unreadable there")
        }
    }

    // MARK: - Layout

    @Test func layoutKeepsCardAndWaveformOnCanvasWithoutOverlapping() {
        let layout = VideoFrameLayout(configuration: .vertical1080x1920, cardAspectRatio: 360.0 / 300.0)
        #expect(layout.size == CGSize(width: 1080, height: 1920))
        #expect(layout.card.minX >= 0)
        #expect(layout.card.maxX <= 1080)
        #expect(layout.card.minY >= 0)
        #expect(layout.waveform.maxY <= 1920)
        // The waveform sits strictly below the card, with a gap.
        #expect(layout.waveform.minY > layout.card.maxY)
        #expect(layout.card.minX == layout.waveform.minX)
        #expect(layout.card.width == layout.waveform.width)
    }

    @Test func aVeryTallCardIsCappedSoTheBlockStaysOnCanvas() {
        // A pathological card (an extremely long note) must not push the waveform
        // off the bottom of a fixed canvas.
        let layout = VideoFrameLayout(configuration: .vertical1080x1920, cardAspectRatio: 0.2)
        #expect(layout.card.minY >= 0)
        #expect(layout.waveform.maxY <= 1920)
    }

    @Test func aDegenerateAspectRatioDoesNotProduceNaNRects() {
        let layout = VideoFrameLayout(configuration: .vertical1080x1920, cardAspectRatio: 0)
        #expect(layout.card.height.isFinite)
        #expect(layout.waveform.height.isFinite)
        #expect(layout.card.height > 0)
    }

    @Test func videoWaveformSpacingScalesWithTheCanvas() {
        let layout = VideoFrameLayout(configuration: .vertical1080x1920, cardAspectRatio: 1.2)
        // 1080 px is 3× the card's 360 pt, so the 2-pt on-screen gap becomes 6 px —
        // same math, bigger units, so the video reads like the card (§4C).
        #expect(layout.waveformGeometry.barSpacing == 6)
        #expect(layout.waveformGeometry.minBarHeight == 9)
    }

    // MARK: - Temp lifecycle (§4G)

    @Test func eachRunGetsItsOwnDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkspaceTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        let second = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        #expect(first.directory != second.directory)
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.directory.path))

        // Same capsule date in both runs → same friendly file name, but different
        // directories, so they cannot collide the way a shared temp name could (§3).
        let capsule = Capsule()
        let name = VideoExporter.outputFileName(for: capsule)
        #expect(name.hasSuffix(".mp4"))
        #expect(first.url(named: name) != second.url(named: name))
    }

    @Test func cleaningOneRunLeavesTheOtherAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkspaceTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let doomed = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        let keeper = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        try Data("x".utf8).write(to: keeper.url(named: "keep.mp4"))

        doomed.clean()
        #expect(!FileManager.default.fileExists(atPath: doomed.directory.path))
        #expect(FileManager.default.fileExists(atPath: keeper.url(named: "keep.mp4").path))
        // And the container itself survives, so a later run still has a home.
        #expect(FileManager.default.fileExists(
            atPath: VideoExportWorkspace.container(inTemporaryDirectory: root).path
        ))
    }

    /// The launch scavenge reclaims abandoned runs — and touches nothing else.
    /// (S0 found an M12 test that deleted a parent directory and wiped all of `tmp`;
    /// this asserts the export cleanup can never do that.)
    @Test func scavengeRemovesStaleRunsAndNothingOutsideOurContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkspaceTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A bystander living next to our container, standing in for everything else
        // the app or another test keeps in the temporary directory.
        let bystander = root.appending(path: "someone-elses-file.txt", directoryHint: .notDirectory)
        try Data("do not delete".utf8).write(to: bystander)

        let stale = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        try Data("old".utf8).write(to: stale.url(named: "old.mp4"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: stale.directory.path
        )
        let inFlight = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        try Data("new".utf8).write(to: inFlight.url(named: "new.mp4"))

        let removed = VideoExportWorkspace.scavenge(olderThan: 600, inTemporaryDirectory: root)
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.directory.path))
        #expect(FileManager.default.fileExists(atPath: inFlight.url(named: "new.mp4").path))
        #expect(FileManager.default.fileExists(atPath: bystander.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func scavengeWithNoContainerIsASafeNoOp() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkspaceTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(VideoExportWorkspace.scavenge(inTemporaryDirectory: root) == 0)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    /// A failed render must not leave a half-written `.mp4` for the share sheet.
    @Test func aFailedRenderLeavesNoPartialFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let good = try VideoExporter.input(for: fixture.capsule, in: fixture.workspace)
        // Point the render at audio that isn't decodable audio at all.
        let brokenAudio = fixture.workspace.url(named: "broken.m4a")
        try Data(repeating: 0x00, count: 2048).write(to: brokenAudio)
        let broken = VideoExportInput(
            audioURL: brokenAudio,
            outputURL: good.outputURL,
            card: good.card,
            samples: good.samples,
            tint: good.tint,
            configuration: good.configuration
        )

        await #expect(throws: (any Error).self) {
            _ = try await VideoExporter.export(broken)
        }
        #expect(!FileManager.default.fileExists(atPath: good.outputURL.path))
    }
}
