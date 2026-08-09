import Foundation
import SwiftData

/// Re-judges capsules an **older generation of gates** decided about.
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
/// and fail it during backfill, and the failure was written as an empty marker.
///
/// **Labelled results are re-judged too.** The first version of this reopened only
/// empty markers, arguing that "a stored label is evidence about the audio, and a
/// threshold change does not make it wrong". That argument does not survive its own
/// motivation: the per-label floor exists *because* measured `waterfall` labels at
/// 0.30–0.38 were wrong about quiet rooms. A capsule carrying `waterfall=0.35` from
/// gate 1 would otherwise keep displaying, searching and exporting as "a waterfall"
/// forever — the §1.2 failure the floor was raised to prevent, grandfathered in.
///
/// So a superseded capsule takes one of two paths, and neither costs an analysis it
/// does not need:
/// - its labels still clear the current gates → the stored value is **re-stamped**
///   with the current gate. Vetted without re-reading the audio, and it leaves the
///   candidate set, so passes converge instead of re-examining it every launch.
/// - they do not → it is **reopened** (`soundprintRaw = nil`) and the ordinary
///   backfill re-analyses it. No second analysis path to keep in step with the first.
enum SoundprintRemediation {

    /// The prefix every value written before gate versioning carries.
    ///
    /// Gate 1 was written without a gate component (it *is* 1.6.0's format), so every
    /// superseded value — empty or labelled — begins `1/<classifier>|`. A prefix test
    /// keeps the fetch a predicate the store can run rather than a full scan.
    static func legacyPrefix(classifier: String = "version1") -> String {
        "\(Soundprint.schemaVersion)/\(classifier)|"
    }

    /// What a re-judgement decided.
    enum Outcome: Equatable {
        /// Labels still stand; the value was re-stamped with the current gate.
        case revalidated
        /// The verdict was invalidated; the capsule goes back to the backfill.
        case reopened
    }

    /// Re-judge one stored value under the **current** gates.
    ///
    /// Pure, so the rule is testable without a store: an empty verdict is always
    /// reopened (it was entirely a threshold judgement), and a labelled one keeps
    /// only labels that still clear today's allow-list and floors. If nothing
    /// survives, there is no longer anything to say and the capsule is reopened.
    static func rejudge(_ stored: String) -> (outcome: Outcome, stored: String?) {
        guard let print = Soundprint(stored: stored), print.gate < Soundprint.gateVersion else {
            return (.revalidated, stored)
        }
        guard !print.isEmpty else { return (.reopened, nil) }

        let surviving = print.labels.filter {
            SoundVocabulary.isAllowed($0.identifier)
                && $0.confidence >= SoundVocabulary.confidenceFloor(
                    for: $0.identifier, default: SoundprintService.confidenceFloor)
        }
        guard !surviving.isEmpty else { return (.reopened, nil) }
        return (.revalidated,
                Soundprint(classifier: print.classifier, labels: surviving).stored)
    }

    /// Keep re-judging until nothing superseded is left.
    ///
    /// Bounded per batch for the same reason as the backfill, and drained for the
    /// same reason too: this pass is what *feeds* the backfill for a library labelled
    /// under gate 1, so leaving it at one batch per launch would just move the
    /// fifteen-launch wait one step upstream. It reads no audio — parse, decide,
    /// save — so a batch is cheap.
    ///
    /// Returns how many were reopened for re-analysis.
    @discardableResult
    static func drain(
        in context: ModelContext,
        batchSize: Int = 40,
        maximumBatches: Int = 100,
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) -> Int {
        var reopened = 0
        for batch in 0..<maximumBatches {
            let result = rejudgeBatch(in: context, limit: batchSize, isEnabled: isEnabled)
            reopened += result.reopened
            // Nothing *touched* means nothing superseded is left. Re-stamps count as
            // progress here — counting only reopenings would loop forever over a
            // library whose gate-1 labels all still stand.
            if result.touched == 0 { return reopened }
            if batch == maximumBatches - 1 {
                Diagnostics.notice("M15 remediation: stopped at the batch ceiling with work remaining")
            }
        }
        return reopened
    }

    /// Re-judge up to `limit` superseded capsules.
    ///
    /// Returns how many capsules were **touched** (reopened or re-stamped) and how
    /// many of those were **reopened**. The drain needs the first to know whether
    /// there is more to do; callers care about the second.
    @discardableResult
    static func rejudgeBatch(
        in context: ModelContext,
        limit: Int = 40,
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) -> (touched: Int, reopened: Int) {
        // Consent first. Re-judging is a prelude to analysing again, and a user who
        // turned listening off must not have their library quietly queued up for it.
        guard isEnabled else { return (0, 0) }
        guard Soundprint.gateVersion > 1 else { return (0, 0) }

        let prefix = legacyPrefix()
        var descriptor = FetchDescriptor<Capsule>(
            predicate: #Predicate { capsule in
                if let raw = capsule.soundprintRaw {
                    return raw.starts(with: prefix)
                } else {
                    return false
                }
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let superseded = try? context.fetch(descriptor), !superseded.isEmpty else { return (0, 0) }

        // Remember the originals: `rollback()` does not restore already-materialised
        // objects — this project established that the hard way when the first version
        // of the backfill's consent fix passed its own assertion and still left the
        // capsule mutated. On failure the values are put back by hand.
        let originals = superseded.map { ($0, $0.soundprintRaw) }
        var reopened = 0
        for capsule in superseded {
            guard let raw = capsule.soundprintRaw else { continue }
            let (outcome, replacement) = rejudge(raw)
            capsule.soundprintRaw = replacement
            if outcome == .reopened { reopened += 1 }
        }

        do {
            try context.save()
        } catch {
            for (capsule, original) in originals { capsule.soundprintRaw = original }
            Diagnostics.notice("Re-judging superseded soundprint verdicts failed")
            return (0, 0)
        }
        Diagnostics.info("Re-judged superseded soundprint verdicts")
        return (superseded.count, reopened)
    }
}
