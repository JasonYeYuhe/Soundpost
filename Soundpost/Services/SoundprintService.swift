import Foundation
import SoundAnalysis
import os

/// The seam between "run a Core ML model" and "decide what to say about it"
/// (M15 §4J / Codex F11).
///
/// Every rule that matters — the gates, the confidence floor, the deny-list, the
/// copy — is tested against a stub through this protocol. Exactly one integration
/// test exercises the real classifier, and it asserts *loosely*, so CI never depends
/// on Core ML output being bit-stable across OS versions.
protocol SoundClassifying: Sendable {
    /// Identifier of the underlying taxonomy, stored as provenance on the result.
    var classifierIdentifier: String { get }
    /// Raw, ungated classifications for a clip — highest confidence first.
    func classify(clipAt url: URL) async throws -> [Soundprint.Label]
}

/// Turns a recorded clip into a `Soundprint`, on-device (M15 §4A/§4C).
///
/// **The gates matter more than the model.** The capability probe showed that
/// Apple's classifier does not fail quietly on degenerate input — it fails
/// *confidently*:
///
///  * 3 seconds of **digital silence** → `music 0.25 | synthesizer 0.13`
///  * a **0.5 s** clip → zero callbacks at all
///
/// So a confidence floor alone is not enough; a floor below 0.25 would have told
/// users their silent recording sounds like music. Analysis is gated on **duration**
/// and **amplitude first**, and only then filtered by confidence.
enum SoundprintService {
    private static let logger = Logger(subsystem: "com.soundpost.Soundpost", category: "soundprint")

    /// One classification window is ~0.975 s; below that the analyzer returns nothing.
    static let minimumDuration: TimeInterval = 1.0

    /// Absolute peak (pre-normalisation) below which we treat the clip as silent and
    /// never ask the classifier. Deliberately conservative: saying nothing is always
    /// better than saying something wrong about someone's memory (M15 §1.2).
    static let minimumPeak: Float = 0.02

    /// Must sit **above** the measured silence artefact (0.25), or silence leaks
    /// through as "music". Provisional — S2 tunes it against real recordings, which
    /// is safe to do later because raw confidences are stored.
    static let confidenceFloor: Double = 0.30

    /// A capsule is a moment, not an inventory. Three labels is plenty.
    static let maximumLabels = 3

    /// Classify a clip, applying every gate. Never throws: a failure is an outcome,
    /// because "we could not listen" must not be able to break saving a memory.
    static func soundprint(
        forClipAt url: URL,
        duration: TimeInterval,
        peak: Float,
        classifier: some SoundClassifying = SoundAnalysisClassifier(),
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) async -> SoundprintOutcome {
        // Consent first, before anything else is even considered (M15 §4I). A
        // defaulted parameter rather than a read inside the body: callers cannot
        // forget it, and tests can drive both sides.
        guard isEnabled else { return .skipped(.notPermitted) }
        guard duration >= minimumDuration else { return .skipped(.tooShort) }
        guard peak >= minimumPeak else { return .skipped(.tooQuiet) }

        do {
            let raw = try await classifier.classify(clipAt: url)
            let kept = raw
                // Only vocabulary we can actually name gets stored at all (M15 §4D).
                // Filtering here rather than at display time means a label we refuse
                // to show never enters storage or iCloud in the first place — which
                // is a stronger guarantee than "we promise not to render it".
                .filter { SoundVocabulary.isAllowed($0.identifier) }
                .filter { $0.confidence >= confidenceFloor }
                .sorted { $0.confidence > $1.confidence }
                .prefix(maximumLabels)
            // An empty result here is a legitimate, terminal answer: analysed, and
            // nothing worth saying.
            return .analysed(Soundprint(classifier: classifier.classifierIdentifier,
                                        labels: Array(kept)))
        } catch {
            logger.error("classification failed: \(String(describing: type(of: error)), privacy: .public)")
            return .skipped(.failed)
        }
    }
}

/// The real classifier, over Apple's built-in `.version1` taxonomy — 303 labels,
/// on-device, no network.
///
/// Three API traps this type exists to contain (M15 §4A / Codex F3):
///  1. `SNAudioFileAnalyzer.add(_:withObserver:)` does **not retain the observer**.
///     Both analyzer and observer are held for the whole run.
///  2. Results arrive on the analyzer's **own queue**, not the main actor — so this
///     type never touches SwiftData; it returns values and lets the caller decide.
///  3. Completing with **zero** callbacks is normal (a too-short clip), so "no
///     results" is a successful empty return, never a hang.
struct SoundAnalysisClassifier: SoundClassifying {
    let classifierIdentifier = SNClassifierIdentifier.version1.rawValue

    func classify(clipAt url: URL) async throws -> [Soundprint.Label] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)

        await analyzer.analyze()
        // `add(_:withObserver:)` does not retain `collector`; keeping it explicitly
        // alive across the await is the whole reason results are not silently lost.
        return withExtendedLifetime(collector) { collector.best() }
    }

    /// Accumulates the per-window classifications the analyzer emits.
    ///
    /// A clip yields one result per ~0.975 s window, so a 30 s clip produces ~57 of
    /// them; the label for the clip is the **mean confidence per label across
    /// windows**, which is far steadier than any single window and stops one loud
    /// second from defining the whole memory.
    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var totals: [String: (sum: Double, count: Int)] = [:]
        private var windows = 0

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            lock.lock()
            defer { lock.unlock() }
            windows += 1
            for entry in classification.classifications {
                let existing = totals[entry.identifier] ?? (0, 0)
                totals[entry.identifier] = (existing.sum + Double(entry.confidence), existing.count + 1)
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {}

        func best() -> [Soundprint.Label] {
            lock.lock()
            defer { lock.unlock() }
            guard windows > 0 else { return [] }
            return totals
                .map { Soundprint.Label(identifier: $0.key, confidence: $0.value.sum / Double(windows)) }
                .sorted { $0.confidence > $1.confidence }
        }
    }
}
