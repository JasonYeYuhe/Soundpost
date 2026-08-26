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

    /// Whether anything was **stored**. Not the same question as whether anything
    /// can be shown — see `showablePhrases`, and read this name as the warning it is.
    ///
    /// It used to be spelled `isEmpty`, which read as "nothing here" and meant
    /// "no labels in the string". A value can hold a label that has since left the
    /// vocabulary, or one below a floor that has since been raised — both real, since
    /// the vocabulary grew from 52 to 93 and the floors moved twice — and such a
    /// value answers `false` here while every display path renders nothing. That cost
    /// one ghost "Sounds like" header over zero chips on the capture sheet
    /// (`CaptureView`), and after M17 §S2 it would have cost one on every new surface.
    ///
    /// The storage layer genuinely wants this question: an analysed-but-empty
    /// soundprint is *not* an error, it is Soundpost choosing to say nothing, and
    /// `SoundprintRemediation` reopens exactly those. Display never does.
    var hasNoLabels: Bool { labels.isEmpty }

    /// Every stored identifier, showable or not. The **storage** view; a render site
    /// wants `showablePhrases`.
    var identifiers: [String] { labels.map(\.identifier) }

    // MARK: What anyone can actually be shown (M17 §4C)

    /// Whether this stored label may be shown **today**.
    ///
    /// Two conditions, and both can change under a value that was written years ago:
    /// the label must still be in the curated vocabulary, and it must still clear the
    /// confidence floor that applies to it. `SoundprintRemediation.rejudge` applies
    /// the identical pair when it decides whether a superseded verdict survives — the
    /// same rule, asked at rest rather than at display time.
    static func isShowable(_ label: Label,
                           defaultFloor: Double = SoundprintService.confidenceFloor) -> Bool {
        SoundVocabulary.isAllowed(label.identifier)
            && label.confidence >= SoundVocabulary.confidenceFloor(
                for: label.identifier, default: defaultFloor)
    }

    /// The labels a screen could put in front of someone, highest confidence first.
    func showableLabels(defaultFloor: Double = SoundprintService.confidenceFloor) -> [Label] {
        labels.filter { Self.isShowable($0, defaultFloor: defaultFloor) }
    }

    /// A showable label together with the phrase it renders as.
    ///
    /// Both, because the two are wanted by different things about the same chip: the
    /// reader needs the phrase in their language, and a gallery facet needs the stable
    /// classifier identifier — matching a *phrase* would tie a saved filter to the
    /// device's current language, and would go through the fuzzy word-boundary rules
    /// free-text search needs and a facet must not (M17 §S3).
    struct Showable: Equatable, Sendable, Identifiable {
        let identifier: String
        let phrase: String
        var id: String { identifier }
    }

    /// Showable labels paired with their phrases, highest confidence first. The one
    /// place the vocabulary lookup happens, so a facet and a caption can never
    /// disagree about which labels exist.
    func showable(defaultFloor: Double = SoundprintService.confidenceFloor) -> [Showable] {
        showableLabels(defaultFloor: defaultFloor).compactMap { label in
            SoundVocabulary.displayName(for: label.identifier)
                .map { Showable(identifier: label.identifier, phrase: $0) }
        }
    }

    /// The localized phrases, in the order they would be shown, for the reader's
    /// language.
    ///
    /// **This is what every render site asks for**, and it is deliberately the only
    /// convenient way to get from a stored value to words. A site that assembled its
    /// own from `identifiers` would be re-deciding the vocabulary and floor rules by
    /// hand, which is how the four existing sites came to disagree about them: the
    /// export, the reveal and search each dropped out-of-vocabulary labels but honoured
    /// no floor, and the capture sheet counted labels it could not render.
    ///
    /// Empty means "nothing to show", which is the question a header should be driven
    /// by — never `hasNoLabels`.
    func showablePhrases(defaultFloor: Double = SoundprintService.confidenceFloor) -> [String] {
        showable(defaultFloor: defaultFloor).map(\.phrase)
    }

    /// The identifiers a screen could show — and therefore the only ones a gallery
    /// facet may match on. Finding a capsule by a label it was never told about is a
    /// result the app cannot explain (§4C).
    func showableIdentifiers(defaultFloor: Double = SoundprintService.confidenceFloor) -> [String] {
        showable(defaultFloor: defaultFloor).map(\.identifier)
    }

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
