import Testing
import AVFoundation
import Foundation
import SoundAnalysis
@testable import Soundpost

/// THROWAWAY probe (M15 planning): does Apple's built-in sound classifier actually
/// produce labels worth building a feature on, at our iOS 17 target, on-device?
/// Deleted once the findings are written into docs/M15-DEVPLAN.md.
private final class ProbeObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    var top: [(String, Double)] = []
    var failure: Error?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        for c in result.classifications.prefix(3) where c.confidence > 0.05 {
            top.append((c.identifier, c.confidence))
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { failure = error }
}

struct SoundClassifierProbeTests {

    /// Write `seconds` of a chosen signal as a real m4a.
    private func writeClip(_ kind: String, seconds: Double, to url: URL) throws {
        let sampleRate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        var lowpass: Float = 0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            switch kind {
            case "tone":                                     // a steady 440 Hz tone
                channel[i] = Float(0.5 * sin(2 * .pi * 440 * t))
            case "noise":                                    // broadband hiss ~ rain-ish
                channel[i] = Float.random(in: -0.5...0.5)
            case "silent":
                channel[i] = 0
            case "rumble":                                   // low-passed noise ~ traffic-ish
                lowpass += (Float.random(in: -1...1) - lowpass) * 0.02
                channel[i] = lowpass * 2
            default:
                channel[i] = 0
            }
        }
        try file.write(from: buffer)
    }

    @Test func probeBuiltInClassifier() async throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let labels = request.knownClassifications
        print("PROBE labelCount=\(labels.count)")

        // Which of the sounds this app is actually about does it know?
        let wanted = ["rain", "speech", "laughter", "bird", "traffic", "wind", "water",
                      "music", "keyboard", "typing", "cat", "dog", "footsteps", "crowd",
                      "applause", "car", "train", "coffee", "cutlery", "ocean", "thunder",
                      "singing", "crying", "cooking", "vacuum", "door", "bell", "piano"]
        var found: [String: [String]] = [:]
        for w in wanted {
            let hits = labels.filter { $0.localizedCaseInsensitiveContains(w) }
            if !hits.isEmpty { found[w] = Array(hits.prefix(4)) }
        }
        print("PROBE coverage \(found.count)/\(wanted.count) of the everyday-sound terms:")
        for key in found.keys.sorted() { print("   \(key) -> \(found[key]!.joined(separator: ", "))") }
        let missing = wanted.filter { found[$0] == nil }
        print("PROBE missing: \(missing.joined(separator: ", "))")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SNProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for kind in ["tone", "noise", "rumble"] {
            let url = directory.appending(path: "\(kind).m4a", directoryHint: .notDirectory)
            try writeClip(kind, seconds: 3.0, to: url)
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let observer = ProbeObserver()
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: observer)
            let started = Date()
            await analyzer.analyze()
            let elapsed = Date().timeIntervalSince(started)
            let best = observer.top
                .sorted { $0.1 > $1.1 }
                .prefix(4)
                .map { "\($0.0) \(String(format: "%.2f", $0.1))" }
                .joined(separator: " | ")
            print("PROBE \(kind): \(elapsed < 0.001 ? "?" : String(format: "%.2fs", elapsed)) -> \(best.isEmpty ? "(nothing above 0.05)" : best)")
            if let failure = observer.failure { print("PROBE \(kind) FAILED: \(failure)") }
        }

        #expect(labels.count > 0)
    }

    /// Codex FINDING 7 (harmful labels) + FINDING 2 (short/silent clips) — both
    /// marked HYPOTHESIS by Codex. Settle them against the real classifier.
    @Test func probeHarmfulLabelsAndDegenerateClips() async throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let labels = request.knownClassifications

        let sensitive = ["cry", "sob", "scream", "shout", "yell", "moan", "groan", "gasp",
                         "argu", "cough", "sneeze", "snor", "vomit", "burp", "breath",
                         "whisper", "baby", "child", "infant", "sigh", "wheez", "hiccup",
                         "slap", "gunshot", "glass", "siren", "alarm", "smoke"]
        var hits: [String] = []
        for term in sensitive { hits += labels.filter { $0.localizedCaseInsensitiveContains(term) } }
        let unique = Array(Set(hits)).sorted()
        print("PROBE2 sensitiveLabelCount=\(unique.count)")
        print("PROBE2 sensitive: \(unique.joined(separator: ", "))")

        // Degenerate clips: does a sub-window or silent clip yield nothing, or
        // confident nonsense?
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SNProbe2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, kind, seconds) in [("short-0.5s", "noise", 0.5),
                                      ("silence-3s", "silent", 3.0),
                                      ("silence-30s", "silent", 30.0)] {
            let url = directory.appending(path: "\(name).m4a", directoryHint: .notDirectory)
            try writeClip(kind, seconds: seconds, to: url)
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let observer = ProbeObserver()
            try analyzer.add(try SNClassifySoundRequest(classifierIdentifier: .version1),
                             withObserver: observer)
            await analyzer.analyze()
            let best = observer.top.sorted { $0.1 > $1.1 }.prefix(3)
                .map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: " | ")
            print("PROBE2 \(name): callbacks=\(observer.top.count) -> \(best.isEmpty ? "(NOTHING above 0.05)" : best)"
                  + (observer.failure.map { " FAILED \($0)" } ?? ""))
        }
    }
}
