import Foundation

/// What Soundpost's on-device classifier heard in a capsule (M15 §4B).
///
/// **A guess, and stored as one.** Every label carries its confidence, and the
/// stored form carries the *provenance* of the guess — a schema version and the
/// identifier of the classifier that produced it — so a future taxonomy
/// (`.version2`) is distinguishable from this one rather than silently mixed with
/// it. Without that, a re-analysis pass could not tell stale rows from fresh
/// (M15 §4B / Codex F4, F13).
///
/// Stored on `Capsule` as a single optional `String`, which keeps the
/// CloudKit-mirrored schema additive and legal — the same reasoning `MoodPalette`
/// (M14) and the rest of `Capsule` follow.
///
/// Form: `1/version1|rain=0.82;wind_rustling_leaves=0.41`
///  * `1`        — schema version of this encoding
///  * `version1` — the `SNClassifierIdentifier` that produced it
///  * pairs      — label identifier + confidence, highest first
///
/// An **empty** label list is meaningful and distinct from `nil`: `1/version1|`
/// means *"we analysed this and had nothing confident to say"*, whereas `nil` means
/// *"never analysed"*. The backfill (S7) relies on that difference to be idempotent
/// instead of retrying forever.
struct Soundprint: Equatable, Sendable {
    /// Bump only when the *encoding* changes, not when the classifier does.
    static let schemaVersion = 1

    /// The version of the **gates** that produced this result — the amplitude
    /// threshold, the confidence floor, the allow-list — as distinct from the
    /// encoding (`schemaVersion`) and the model (`classifier`).
    ///
    /// It exists because an *empty* soundprint is a verdict, and a verdict is only
    /// as good as the thresholds behind it. "We listened and had nothing to say" is
    /// terminal by design — the backfill only ever refetches `soundprintRaw == nil`,
    /// which is what stops it re-examining the same silent clip on every launch. But
    /// with no record of *which* gates said so, a capsule written off under one set
    /// of thresholds could never be reconsidered under a better one, and the
    /// thresholds have now moved twice: the amplitude gate's input changed from a
    /// bucket average to a true peak (§11C), and `waterfall` got a raised floor.
    /// Codex and Gemini both named this unprompted, from opposite directions.
    ///
    /// **Bump this whenever a gate changes in a way that could alter an empty
    /// verdict.** `SoundprintRemediation` reopens empty markers from older gates so
    /// they are analysed once more; labelled results are left alone, since a label
    /// is evidence about the audio rather than a judgement call about a threshold.
    ///
    /// 1 = shipped in 1.6.0 (bucket-average amplitude input, flat 0.30 floor).
    /// 2 = absolute-peak amplitude input, per-label floors.
    static let gateVersion = 2

    /// The stored form of "we listened and had nothing to say", for a given
    /// classifier and gate generation. Exact strings, so the remediation pass can
    /// select them with a plain equality predicate instead of parsing in SQL.
    static func emptyMarker(classifier: String, gate: Int = gateVersion) -> String {
        Soundprint(classifier: classifier, gate: gate).stored
    }

    struct Label: Equatable, Sendable {
        let identifier: String
        let confidence: Double
    }

    /// The `SNClassifierIdentifier` raw value this came from, e.g. `version1`.
    let classifier: String
    /// Which generation of gates produced this. Values stored by 1.6.0 carry no
    /// gate component and read back as `1` — see `gateVersion`.
    let gate: Int
    /// Highest confidence first. May be empty — see the type doc.
    let labels: [Label]

    init(classifier: String, gate: Int = Soundprint.gateVersion, labels: [Label] = []) {
        self.classifier = classifier
        self.gate = gate
        self.labels = labels.sorted { $0.confidence > $1.confidence }
    }

    /// Parse the stored form. Returns `nil` for anything unrecognisable, so a
    /// corrupted value degrades to "never analysed" rather than to wrong labels.
    init?(stored: String?) {
        guard let stored, !stored.isEmpty else { return nil }
        // <schema>/<classifier>[/<gate>]|<pairs>
        //
        // The gate component is optional on read and always written. 1.6.0 shipped
        // `1/version1|…` and those values must keep parsing exactly as before —
        // rejecting them would strand every capsule it analysed, since the backfill
        // only looks at `soundprintRaw == nil` and would never see them again.
        let head = stored.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard head.count == 2 else { return nil }
        let provenance = head[0].split(separator: "/")
        // Exactly two components (legacy) or three (with a gate). Deliberately
        // strict, and a review argued the opposite: that splitting from the right
        // would tolerate a classifier identifier containing a slash. It would — and
        // it would also make `1/version1/x|rain=0.8` parse as the classifier
        // "version1/x" with real labels, which breaks the guarantee this type is
        // built on: *a corrupted value degrades to "never analysed", never to wrong
        // labels.* No `SNClassifierIdentifier` contains a slash, and if one ever did,
        // degrading to "never analysed" hands the capsule back to the backfill, which
        // is recovery rather than loss. Strictness costs a hypothetical and buys the
        // documented invariant.
        guard provenance.count == 2 || provenance.count == 3,
              let schema = Int(provenance[0]),
              schema == Self.schemaVersion,
              !provenance[1].isEmpty else { return nil }
        let gate: Int
        if provenance.count == 3 {
            guard let parsed = Int(provenance[2]), parsed > 0 else { return nil }
            gate = parsed
        } else {
            gate = 1
        }
        let classifier = String(provenance[1])

        var parsed: [Label] = []
        for pair in head[1].split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  let confidence = Double(parts[1]),
                  confidence.isFinite else { continue }
            parsed.append(Label(identifier: String(parts[0]), confidence: confidence))
        }
        self.init(classifier: classifier, gate: gate, labels: parsed)
    }

    var stored: String {
        let pairs = labels
            .map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ";")
        // Gate 1 is written *without* the component, because gate 1 IS the format
        // 1.6.0 shipped. One representation per (schema, classifier, gate), and the
        // legacy values already in users' stores are byte-identical to what gate 1
        // would produce now — which is what lets the remediation pass find them with
        // a plain equality predicate. A first draft always wrote the component, so
        // it looked for `1/version1/1|` and would have matched nothing at all.
        let provenance = gate > 1
            ? "\(Self.schemaVersion)/\(classifier)/\(gate)"
            : "\(Self.schemaVersion)/\(classifier)"
        return "\(provenance)|\(pairs)"
    }

    /// Whether this soundprint has anything to show. An analysed-but-empty
    /// soundprint is *not* an error — it is Soundpost choosing to say nothing.
    var isEmpty: Bool { labels.isEmpty }

    var identifiers: [String] { labels.map(\.identifier) }

    /// Exact-token membership. **Never substring**: the classifier's own vocabulary
    /// contains both `rain` and `train`, so a `contains` match would find rainy
    /// capsules when searching for trains and vice versa (M15 §4E / Codex F4).
    func contains(_ identifier: String) -> Bool {
        labels.contains { $0.identifier == identifier }
    }
}

/// The terminal outcome of one classification attempt (M15 §4A).
///
/// Deliberately closed and terminal: there is **no "still pending" case**. Apple's
/// analyzer completes with zero callbacks for a clip shorter than one classification
/// window, so an implementation that only records results in `didProduce:` would
/// leave such a capsule in a permanent in-flight limbo (Codex F2, confirmed by probe:
/// a 0.5 s clip produced 0 callbacks).
enum SoundprintOutcome: Equatable, Sendable {
    /// Analysed. The soundprint may still be empty — that means "nothing confident".
    case analysed(Soundprint)
    /// Not analysed, and we know why. Never retried on the same clip.
    case skipped(Reason)

    enum Reason: String, Equatable, Sendable {
        /// Shorter than one classifier window — the analyzer would return nothing.
        case tooShort
        /// Near-silent. Analysing silence returns *confident nonsense*
        /// (probe: 3 s of digital silence → `music 0.25`), so we never ask.
        case tooQuiet
        /// The analyzer itself failed.
        case failed
        /// The user has turned listening off (M15 §4I). Not an error, and never
        /// retried — the backfill must respect it too.
        case notPermitted
    }

    var soundprint: Soundprint? {
        if case .analysed(let print) = self { return print }
        return nil
    }
}
