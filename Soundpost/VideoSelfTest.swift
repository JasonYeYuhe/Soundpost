#if DEBUG
import AVFoundation
import AVKit
import CoreMedia
import Foundation
import SwiftUI
import os

/// **M13 S2 — the human-gated device smoke test** (§5 S2, §8).
///
/// `VideoExporterTests` proves on the simulator that the export is structurally
/// right and that its pixels really move. What it cannot judge is whether the card
/// reads **upright and legible** on a real screen, or whether the sweep *looks*
/// in time with the sound. So this renders a genuine video on the device and plays
/// it back for a person to watch.
///
/// The clip is built to make sync **falsifiable by eye**: four short rising beeps
/// at known times over otherwise-silent audio, so the waveform shows four clearly
/// separated peaks and the playhead must cross each peak exactly as that beep
/// sounds. Drift of even a tenth of a second is visible against a peak — which a
/// constant tone could never reveal.
///
/// It also reports the **device** render time and output size, which are the
/// measurements §8's duration-cap decision and §4G's preflight constant need (the
/// simulator's software encoder is not representative).
///
/// DEBUG-only; never shipped. Run it with the `-runVideoSelfTest` launch argument
/// (Xcode scheme → Arguments, or `xcrun devicectl` / `simctl launch`).
@MainActor
struct VideoSelfTestView: View {
    /// Beep onsets, in seconds. Chosen off the quarter marks so a frame-rounding
    /// bug can't hide behind a coincidence.
    static let beepTimes: [Double] = [0.4, 1.9, 3.4, 5.1]
    static let clipSeconds: Double = 6.0

    @State private var status = "Rendering…"
    @State private var report: [String] = []
    @State private var passed: Bool?
    @State private var player: AVPlayer?
    /// Held for the view's lifetime so the rendered file outlives the render — the
    /// same retain-until-done rule the share sheet follows (§4G).
    @State private var workspace: VideoExportWorkspace?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let player {
                        VideoPlayer(player: player)
                            .frame(height: 460)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        // `Text(verbatim:)` throughout: this is a developer tool, so
                        // its copy must never enter the String Catalog (which the
                        // localization gate would then demand translations for).
                        Button { replay(player) } label: {
                            Label {
                                Text(verbatim: "Play again")
                            } icon: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    whatToLookFor
                    if !report.isEmpty {
                        Text(verbatim: report.joined(separator: "\n"))
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle(Text(verbatim: "M13 video self-test"))
        }
        .task { await run() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            switch passed {
            case .some(true):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .some(false):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case nil:
                ProgressView()
            }
            Text(verbatim: status).font(.headline)
        }
    }

    private var whatToLookFor: some View {
        let beeps = Self.beepTimes.map { String(format: "%.1fs", $0) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Judge by eye (the simulator can't):").font(.subheadline.weight(.semibold))
            Text(verbatim: """
            1. The card is UPRIGHT — mood glyph and date at the top, \
            “Made with Soundpost” at the bottom. Not mirrored, not flipped.
            2. The note and date are LEGIBLE, nothing clipped at the card's edges.
            3. The sweep runs LEFT → RIGHT once, at a steady rate, and reaches the \
            right edge exactly as the audio ends.
            4. SYNC: the playhead crosses each of the four waveform peaks exactly as \
            that beep sounds. Beeps are at \(beeps) of \(String(format: "%.0f", Self.clipSeconds))s.
            5. Turn the ringer ON — this plays through the media volume.
            """)
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func replay(_ player: AVPlayer) {
        player.seek(to: .zero)
        player.play()
    }

    // MARK: - Run

    private func run() async {
        let log = Logger(subsystem: "com.soundpost.Soundpost", category: "selftest")
        var facts: [String: Any] = [:]
        var lines: [String] = []

        do {
            // Playback through the media volume, so a person can actually hear the
            // beeps. `.playback` needs no background mode (PROJECT.md §1e.4).
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)

            let space = try VideoExportWorkspace.makeUnique()
            workspace = space

            // 1. A real, decodable AAC clip with four locatable beeps.
            let audioURL = space.url(named: "selftest-source.m4a")
            try Self.writeBeepClip(to: audioURL, seconds: Self.clipSeconds, beeps: Self.beepTimes)
            let samples = try WaveformExtractor.samples(from: audioURL, buckets: 56)
            facts["waveformBuckets"] = samples.count
            facts["waveformPeak"] = Double(samples.max() ?? 0)

            // 2. A capsule carrying it — standalone, never inserted into a store, so
            //    this touches no real data.
            let capsule = Capsule()
            try capsule.transition(to: .recording)
            try capsule.transition(to: .captured)
            capsule.audioData = try Data(contentsOf: audioURL)
            capsule.durationSeconds = Self.clipSeconds
            capsule.waveformSamples = samples
            capsule.note = "Four beeps — watch the playhead cross each peak."
            capsule.mood = .calm

            // 3. The real export path, exactly as the app will call it.
            let input = try VideoExporter.input(for: capsule, in: space)
            let startedAt = Date()
            let result = try await VideoExporter.export(input)
            let renderSeconds = Date().timeIntervalSince(startedAt)

            // 4. Structural facts, on the device.
            let asset = AVURLAsset(url: result.url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let videoTrack = videoTracks.first
            let codec = try await videoTrack?.load(.formatDescriptions).first
                .map { CMFormatDescriptionGetMediaSubType($0) }
            let naturalSize = try await videoTrack?.load(.naturalSize) ?? .zero
            let videoSeconds = try await videoTrack?.load(.timeRange).duration.seconds ?? 0
            let audioSeconds = result.duration.seconds
            let drift = abs(videoSeconds - audioSeconds)
            let frameSeconds = input.configuration.frameDuration.seconds

            facts["videoTracks"] = videoTracks.count
            facts["audioTracks"] = audioTracks.count
            facts["isH264"] = codec == kCMVideoCodecType_H264
            facts["width"] = Int(naturalSize.width)
            facts["height"] = Int(naturalSize.height)
            facts["audioTrackSeconds"] = audioSeconds
            facts["videoTrackSeconds"] = videoSeconds
            facts["driftSeconds"] = drift
            facts["frameCount"] = result.frameCount
            facts["byteCount"] = result.byteCount
            // The numbers §8 and §4G actually need, measured on real hardware with
            // the real per-frame reveal (not the simulator's software encoder).
            facts["renderSeconds"] = renderSeconds
            facts["realtimeFactor"] = audioSeconds > 0 ? renderSeconds / audioSeconds : 0
            facts["bytesPerSecond"] = audioSeconds > 0 ? Double(result.byteCount) / audioSeconds : 0
            facts["projected5MinuteMB"] = audioSeconds > 0
                ? (Double(result.byteCount) / audioSeconds) * 300 / 1_000_000 : 0
            facts["projected5MinuteRenderSeconds"] = audioSeconds > 0
                ? renderSeconds / audioSeconds * 300 : 0

            let machineChecksPassed = videoTracks.count == 1
                && audioTracks.count == 1
                && codec == kCMVideoCodecType_H264
                && naturalSize == CGSize(width: 1080, height: 1920)
                && result.byteCount > 0
                && drift <= frameSeconds
            facts["machineChecksPassed"] = machineChecksPassed

            // 5. Keep a copy somewhere retrievable (Xcode → Devices → Download
            //    Container) in case the video needs looking at off-device.
            let saved = URL.documentsDirectory.appending(path: "Soundpost-videoselftest.mp4",
                                                        directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: saved)
            try? FileManager.default.copyItem(at: result.url, to: saved)
            facts["savedCopy"] = saved.path

            lines = [
                "tracks         \(videoTracks.count) video / \(audioTracks.count) audio",
                "codec          \(codec == kCMVideoCodecType_H264 ? "H.264 ✓" : "NOT H.264 ✗")",
                "size           \(Int(naturalSize.width))×\(Int(naturalSize.height))",
                String(format: "audio track    %.3fs", audioSeconds),
                String(format: "video track    %.3fs  (drift %.4fs, one frame = %.4fs) %@",
                       videoSeconds, drift, frameSeconds, drift <= frameSeconds ? "✓" : "✗"),
                "frames         \(result.frameCount)",
                String(format: "output         %.2f MB", Double(result.byteCount) / 1_000_000),
                String(format: "render         %.2fs  (%.2f× realtime)",
                       renderSeconds, audioSeconds > 0 ? renderSeconds / audioSeconds : 0),
                String(format: "→ 5-min clip   ≈ %.0f MB, ≈ %.0fs to render",
                       facts["projected5MinuteMB"] as? Double ?? 0,
                       facts["projected5MinuteRenderSeconds"] as? Double ?? 0),
                "saved copy     \(saved.lastPathComponent) (app Documents)",
            ]

            player = AVPlayer(url: result.url)
            player?.play()
            status = machineChecksPassed
                ? "Machine checks passed — now judge the video by eye."
                : "Machine checks FAILED — see below."
            passed = machineChecksPassed
            facts["PASS"] = machineChecksPassed
        } catch {
            facts["error"] = "\(error)"
            facts["PASS"] = false
            status = "Render failed."
            passed = false
            lines = ["error          \(error)"]
        }

        report = lines
        // Same verdict shape as `AudioSelfTest`, so both are machine-readable.
        let data = (try? JSONSerialization.data(
            withJSONObject: facts,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        try? data.write(to: URL.applicationSupportDirectory.appending(path: "videoselftest_result.json"))
        log.notice("VIDEO_SELFTEST_RESULT \(String(data: data, encoding: .utf8) ?? "{}", privacy: .public)")
    }

    // MARK: - The beep clip

    enum SelfTestError: Error, CustomStringConvertible {
        case couldNotAllocateBuffer
        var description: String { "could not allocate the PCM buffer for the self-test clip" }
    }

    /// Write `seconds` of silence with a short rising beep starting at each of
    /// `beeps`. Real AAC in an `.m4a`, so the whole downstream path is the real one.
    static func writeBeepClip(
        to url: URL,
        seconds: Double,
        beeps: [Double],
        beepSeconds: Double = 0.22
    ) throws {
        let sampleRate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            throw SelfTestError.couldNotAllocateBuffer
        }
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) { channel[index] = 0 }

        for (order, start) in beeps.enumerated() {
            // Rising pitch so each beep is individually identifiable by ear.
            let frequency = 440.0 * pow(2.0, Double(order) / 3.0)
            let from = Int(start * sampleRate)
            let to = min(Int((start + beepSeconds) * sampleRate), Int(frameCount))
            guard from < to else { continue }
            for index in from..<to {
                let elapsed = Double(index - from) / sampleRate
                // A sine envelope keeps the onset clean — no click to mistake for a peak.
                let envelope = sin(.pi * elapsed / beepSeconds)
                channel[index] = Float(0.7 * envelope * sin(2 * .pi * frequency * Double(index) / sampleRate))
            }
        }
        try file.write(from: buffer)
    }
}
#endif
