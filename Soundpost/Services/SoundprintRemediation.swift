import Foundation
import SwiftData

/// Reopens capsules an **older generation of gates** wrote off.
///
/// `1/version1|` means "we listened and had nothing to say", and it is terminal on
/// purpose: the backfill only refetches `soundprintRaw == nil`, which is what stops
/// it re-examining the same silent clip on every launch forever. The cost of that
/// design is that a verdict outlives the thresholds that produced it — and 1.6.0's
/// thresholds were wrong in a way that mattered.
///
/// 1.6.0's amplitude gate was handed a bucket average whose value moved with a
/// waveform-*drawing* parameter that differed per call site (56 at capture, 32 at
/// backfill, §11C). A quiet-but-audible recording could clear the gate at capture
/// and fail it during backfill, and the failure was written as this marker. Those
/// capsules are unlabelled, unsearchable, and — without this — permanently so.
///
/// **Only empty markers are reopened.** A stored label is evidence about the audio;
/// a threshold change does not make it wrong, and re-analysing it would churn every
/// capsule in the library for nothing. An empty marker is the opposite: it is
/// entirely a judgement call by the gates, so it is exactly what a gate change
/// invalidates.
///
/// Reopening means setting `soundprintRaw` back to `nil`, which hands the capsule to
/// the ordinary backfill — no second analysis path to keep in step with the first.
enum SoundprintRemediation {

    /// Every empty marker a *superseded* gate could have written, as exact strings.
    ///
    /// Exact equality rather than a prefix or suffix test so the fetch stays a plain
    /// indexed predicate: SwiftData's `#Predicate` support for string operations is
    /// narrow, and "ends with a pipe" is not something to lean on.
    static var supersededEmptyMarkers: [String] {
        guard Soundprint.gateVersion > 1 else { return [] }
        // Only `version1` has ever shipped. A future classifier would add its own
        // markers here; the set stays small because it is (classifiers × gates).
        return (1..<Soundprint.gateVersion).map {
            Soundprint.emptyMarker(classifier: "version1", gate: $0)
        }
    }

    /// Clear up to `limit` superseded empty markers so the backfill reconsiders them.
    ///
    /// Bounded like the backfill, and for the same reason: a long-time user's library
    /// should fill in over a few launches rather than stalling one. Each pass
    /// permanently removes its capsules from the candidate set, so repeated launches
    /// converge.
    ///
    /// Returns how many were reopened.
    @discardableResult
    static func reopenSupersededVerdicts(
        in context: ModelContext,
        limit: Int = 40,
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) -> Int {
        // Consent first. Reopening is only ever a prelude to analysing again, and a
        // user who turned listening off must not have their library quietly queued
        // up for it.
        guard isEnabled else { return 0 }

        let markers = supersededEmptyMarkers
        guard !markers.isEmpty else { return 0 }

        var descriptor = FetchDescriptor<Capsule>(
            predicate: #Predicate { capsule in
                if let raw = capsule.soundprintRaw {
                    return markers.contains(raw)
                } else {
                    return false
                }
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return 0 }

        for capsule in stale { capsule.soundprintRaw = nil }
        do {
            try context.save()
        } catch {
            Diagnostics.notice("Reopening superseded soundprint verdicts failed")
            return 0
        }
        Diagnostics.info("Reopened superseded soundprint verdicts for re-analysis")
        return stale.count
    }
}
