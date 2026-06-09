#if DEBUG
import Foundation
import os

/// Headless integration check of the *real* audio pipeline — no UI, no XCUITest
/// target. Records a short clip through a live `AVAudioSession`, extracts its
/// waveform, and plays it back, then writes a JSON verdict to
/// `Application Support/selftest_result.json` (and os_log). This exercises the
/// exact code unit tests bypass (real recorder/session/player + file I/O).
///
/// Triggered by the `-runAudioSelfTest` launch argument; DEBUG-only, never shipped.
/// Run it on a simulator with the mic pre-granted:
///   xcrun simctl privacy <udid> grant microphone com.soundpost.Soundpost
///   xcrun simctl launch <udid> com.soundpost.Soundpost -runAudioSelfTest
@MainActor
enum AudioSelfTest {
    static func run() async {
        let log = Logger(subsystem: "com.soundpost.Soundpost", category: "selftest")
        var r: [String: Any] = [:]
        let store = AudioStore()
        let recorder = AudioRecorder(store: store)
        let player = AudioPlayer(store: store)
        do {
            try store.ensureDirectory()
            r["permissionGranted"] = await AudioRecorder.requestPermission()
            try recorder.start()
            r["recordStarted"] = recorder.state == .recording
            try? await Task.sleep(for: .seconds(2.5))
            r["meterSamplesWhileRecording"] = recorder.levels.count
            guard let clip = recorder.stop() else { throw Err.msg("recorder.stop() returned nil") }
            r["fileName"] = clip.fileName
            r["durationSeconds"] = clip.duration
            let url = store.url(for: clip.fileName)
            r["fileExists"] = store.fileExists(clip.fileName)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
            r["fileSizeBytes"] = size ?? 0
            let samples = try WaveformExtractor.samples(from: url, buckets: 56)
            r["waveformCount"] = samples.count
            r["waveformPeak"] = Double(samples.max() ?? 0)
            try player.play(fileName: clip.fileName)
            try? await Task.sleep(for: .seconds(0.5))
            r["playerState"] = "\(player.state)"
            r["playStarted"] = player.state != .idle
            player.stop()
            try? store.delete(clip.fileName)
            // Pass if the full pipeline produced a real clip, a 56-bucket waveform, and playback began.
            r["PASS"] = (r["recordStarted"] as? Bool == true)
                && (r["fileExists"] as? Bool == true)
                && ((r["fileSizeBytes"] as? Int64 ?? 0) > 0)
                && (r["waveformCount"] as? Int == 56)
                && (r["playStarted"] as? Bool == true)
        } catch {
            r["error"] = "\(error)"
            r["PASS"] = false
        }
        finish(r, log)
    }

    private enum Err: Error { case msg(String) }

    private static func finish(_ r: [String: Any], _ log: Logger) {
        let data = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let out = URL.applicationSupportDirectory.appending(path: "selftest_result.json")
        try? data.write(to: out)
        log.notice("AUDIO_SELFTEST_RESULT \(String(data: data, encoding: .utf8) ?? "{}", privacy: .public)")
    }
}
#endif
