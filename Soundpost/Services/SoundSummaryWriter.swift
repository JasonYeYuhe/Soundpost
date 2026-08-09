import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// One warm sentence about a resurfaced capsule, written **on-device** by Apple
/// Intelligence where it exists (M15 §4G / S6).
///
/// **A bonus, never the plan.** It requires iOS 26 *and* eligible hardware *and*
/// Apple Intelligence switched on, which is a small slice of the install base — so
/// it may only ever add polish on top of something that already works. Every caller
/// gets a `nil` and carries on with the copy it would have shown anyway. If this
/// type were the only route to a feature, that feature would be broken for most
/// users, which is why the plan marked S6 explicitly droppable.
///
/// **What it is allowed to do.** It is given only facts Soundpost already holds and
/// already shows — what the classifier heard, the user's own line, the place, how
/// long ago — and is instructed to rearrange them, not to add to them. It is never
/// asked how the moment *felt*: a mood is the user's reading, and inferring emotion
/// from a recording is out of scope for this milestone (§2). Output is validated
/// before it is shown, because a model that invents something about someone's
/// memory is worse than no sentence at all (§1.2).
///
/// Nothing is stored: the sentence is generated when the screen appears and
/// forgotten when it closes. That keeps it from going stale, and keeps generated
/// prose out of the user's iCloud.
enum SoundSummaryWriter {
    private static let logger = Logger(subsystem: "com.soundpost.Soundpost", category: "summary")

    /// The facts we are willing to hand the model — deliberately a small, explicit
    /// value type rather than a `Capsule`, so it is obvious at a glance that no
    /// audio and no hidden field can reach it.
    struct Facts: Equatable, Sendable {
        var soundPhrases: [String]
        var note: String?
        var placeName: String?
        var elapsedPhrase: String

        /// Nothing worth writing about: no sounds *and* no words of the user's own.
        var isEmpty: Bool {
            soundPhrases.isEmpty && (note?.isEmpty ?? true)
        }
    }

    /// Why no sentence was produced. Surfaced for logging and tests, never to users.
    enum Unavailable: String, Equatable, Sendable {
        case notSupportedOnThisOS
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
        case nothingToSay
        case listeningOff
        case generationFailed
        case rejectedOutput
        /// The model does not speak the language this person reads the app in.
        case unsupportedLanguage
    }

    /// Does the model speak the language the app is being read in?
    ///
    /// Pure and injectable so it is testable without Apple Intelligence — the whole
    /// generation path cannot be exercised in CI, so every guard around it has to be
    /// something that can.
    ///
    /// Compared on `languageCode` alone: the model advertises regional variants
    /// (`ja-JP`, `zh-Hans-CN`) and `Locale.current.language` may or may not carry a
    /// region, so an exact match would reject supported languages at random. Script
    /// matters for Chinese, so it is compared when both sides declare one.
    static func isLanguageSupported(_ language: Locale.Language,
                                    in supported: Set<Locale.Language>) -> Bool {
        let wantedScript = effectiveScript(language)
        return supported.contains { candidate in
            guard candidate.languageCode == language.languageCode else { return false }
            if let a = effectiveScript(candidate), let b = wantedScript { return a == b }
            return true
        }
    }

    /// The script, inferred when it is not written down.
    ///
    /// `Locale.Language(identifier: "zh-TW").script` is nil — the script is implied
    /// by the region, not stated. Comparing the declared script alone therefore let
    /// a Traditional Chinese reader match a Simplified-only model and be served
    /// Simplified prose. `maximalIdentifier` resolves `zh-TW` to `zh-Hant-TW`, which
    /// is the comparison that was meant.
    private static func effectiveScript(_ language: Locale.Language) -> Locale.Script? {
        language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
    }

    /// The longest sentence we will show. A model that runs on is a model that has
    /// started inventing.
    static let maximumCharacters = 160

    /// Whether a sentence could be produced at all right now — cheap, and safe to
    /// call on any OS version.
    static func availability() -> Unavailable? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .notSupportedOnThisOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            // Ask in a language the model does not speak and it answers in English —
            // which then renders above the user's own Japanese or Chinese note as if
            // it described their memory. Saying nothing is the better failure: the
            // caller's own copy is already localized (§1.2).
            guard isLanguageSupported(Locale.current.language,
                                      in: SystemLanguageModel.default.supportedLanguages) else {
                return .unsupportedLanguage
            }
            return nil
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .modelNotReady
        }
        #else
        return .notSupportedOnThisOS
        #endif
    }

    /// Write the sentence, or return `nil` so the caller uses its own copy.
    static func summary(
        for facts: Facts,
        isListeningEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) async -> String? {
        // The same consent that governs listening governs writing about what was
        // heard — otherwise turning listening off would still leave a model reading
        // the results of it.
        guard isListeningEnabled else { return nil }
        guard !facts.isEmpty else { return nil }
        guard availability() == nil else { return nil }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(
                to: prompt(for: facts),
                options: GenerationOptions(
                    // Low temperature and a hard token ceiling: this is a rephrasing
                    // job, not a creative one, and a short leash is the cheapest
                    // defence against embellishment.
                    temperature: 0.3,
                    maximumResponseTokens: 60
                )
            )
            return validated(response.content, describing: facts)
        } catch {
            logger.error("summary generation failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Accept only something that looks like the one sentence we asked for.
    /// Anything else is discarded in favour of the caller's own copy.
    static func validated(_ raw: String, describing facts: Facts) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models like to wrap prose in quotes; that is presentation, not content.
        // Note the pair is not symmetric — a typographic quote OPENS with U+201C and
        // CLOSES with U+201D, so a `first == last` test silently never fires.
        // Japanese and Chinese models wrap prose in corner brackets, not quotes. With
        // 「 left on the front, a `hasPrefix("申し訳")` check never fires — so the
        // refusal list below was reachable only for output that happened to be
        // unwrapped, which is not how these models format.
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"),
            ("\u{300C}", "\u{300D}"),   // 「 」
            ("\u{300E}", "\u{300F}"),   // 『 』
            ("\u{2018}", "\u{2019}"),   // ‘ ’
        ]
        var stripped = true
        while stripped {
            stripped = false
            guard let first = text.first, let last = text.last, text.count >= 2 else { break }
            for pair in quotePairs where first == pair.0 && last == pair.1 {
                text = String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
                break
            }
        }
        guard !text.isEmpty, text.count <= maximumCharacters else { return nil }
        // A refusal or a preamble is not a sentence about a memory.
        let lowered = text.lowercased()
        guard !refusalPrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) else { return nil }
        // Multi-paragraph output means it ignored the brief.
        guard !text.contains("\n\n") else { return nil }
        // And the language-independent one: it has to actually mention something we
        // gave it.
        guard mentionsAGivenFact(facts, in: text) else { return nil }
        // And that it came back in the script the facts were written in.
        guard looksLikeTheSameScript(as: facts, text: text) else { return nil }
        return text
    }

    /// Openings that mean the model is talking about itself rather than the memory.
    ///
    /// **In all three shipped languages, not just English.** The original list was
    /// English-only matched with `hasPrefix`, which was a real hole rather than a
    /// theoretical one: the model is now instructed to answer in the reader's
    /// language, so a Japanese or Chinese refusal is precisely what it would produce
    /// — and it cleared every other guard (non-empty, under 160 characters, no blank
    /// line) and rendered above the user's own note as if it described their memory.
    ///
    /// A blocklist is a weak instrument and this one is honest about its reach: it
    /// covers en/ja/zh-Hans because those are the languages the app ships and the
    /// language gate now confines the model to. `mentionsAGivenFact` is the guard
    /// that does not depend on knowing the phrasing.
    static let refusalPrefixes = [
        // English
        "i can't", "i cannot", "i can not", "i'm sorry", "i am sorry", "sorry,",
        "as an ai", "i'm unable", "i am unable", "sure,", "here's", "here is",
        "certainly", "of course",
        // Japanese
        "申し訳", "すみません", "ごめん", "できません", "できかねます", "はい、", "もちろん",
        "以下", "こちら",
        // Simplified Chinese
        "抱歉", "对不起", "我无法", "无法", "我不能", "不能", "当然", "好的", "以下是", "这是",
    ]

    /// Does the sentence mention anything we actually handed the model?
    ///
    /// The guard that survives not knowing the language. A refusal, an apology or a
    /// preamble does not contain the user's place name or the sound the classifier
    /// heard, in any language — whereas the sentence we asked for is built out of
    /// exactly those.
    ///
    /// Only sound phrases and the place are used as anchors. They are short localized
    /// nouns, which makes containment meaningful in scripts with and without word
    /// breaks. The note is deliberately not an anchor: it is free text of any length,
    /// and a legitimate one-sentence rephrasing may share nothing quotable with it.
    /// When those are the only facts, the blocklist above is the whole defence — a
    /// limit worth stating rather than papering over.
    ///
    /// Rejecting a good sentence costs nothing dangerous: the caller falls back to
    /// its own localized copy. Accepting a bad one breaks §1.2.
    static func mentionsAGivenFact(_ facts: Facts, in text: String) -> Bool {
        var anchors = (facts.soundPhrases + [facts.placeName].compactMap { $0 })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The note grounds a capsule that has neither a sound nor a place. The first
        // version stood aside there and returned `true`, which meant a note-only
        // capsule had NO factual check at all — "You watched fireworks together."
        // would have been accepted against the note "the storm broke". Under §1.2
        // ungrounded prose about someone's memory is exactly what must not ship, so
        // the fallback is now to reject, not to wave through.
        if anchors.isEmpty, let note = facts.note {
            anchors = contentTokens(of: note)
        }
        guard !anchors.isEmpty else { return false }
        return anchors.contains { anchorMatches($0, in: text) }
    }

    /// Anchor matching, per script.
    ///
    /// For Latin text this must respect word boundaries, because plain containment
    /// reintroduces the exact bug this project already fixed once for search: the
    /// phrase for `train` contains `rain`, so a summary saying "A train passed" would
    /// have satisfied an anchor of "rain" and been shown as a description of a rainy
    /// morning (§4E / Codex F4). `GalleryFilter.matches` is the boundary rule search
    /// already uses.
    ///
    /// For Japanese and Chinese that rule cannot apply: there are no spaces, so it
    /// degrades to "must start the sentence", and 「今朝は雨でした」would fail its own
    /// anchor 雨. Applying it there would not make the check stricter — it would
    /// switch the feature off for two of the three shipped languages. The
    /// substring risk is also different in kind: these anchors are whole localized
    /// nouns, not fragments that happen to nest inside other words.
    private static func anchorMatches(_ anchor: String, in text: String) -> Bool {
        containsCJK(anchor)
            ? text.localizedStandardContains(anchor)
            : GalleryFilter.matches(phrase: text, query: anchor)
    }

    static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3134F:
                return true
            default:
                return false
            }
        }
    }

    /// Is the sentence written in the same kind of script as the facts?
    ///
    /// The language gate establishes only that the model *can* speak the reader's
    /// language, and the brief only *asks* it to. Neither checks what came back — and
    /// the prompt's own field labels are English, which pulls the other way. Given
    /// Japanese facts, "A rainy afternoon in 東京." satisfies the place anchor while
    /// being the exact failure this was all meant to prevent.
    ///
    /// A script comparison is coarse and that is the point: it needs no language
    /// identification, and it catches the case that actually occurs — English prose
    /// returned for CJK facts.
    static func looksLikeTheSameScript(as facts: Facts, text: String) -> Bool {
        let given = facts.soundPhrases + [facts.note, facts.placeName].compactMap { $0 }
        guard containsCJK(given.joined(separator: " ")) else { return true }
        // Look at the sentence with the given facts REMOVED. Asking only whether the
        // output contains CJK is satisfied by a single quoted place name — "A rainy
        // afternoon in 東京." would pass while being precisely the English-on-a-
        // Japanese-screen failure this exists to catch. What matters is the script of
        // the model's own prose, which is what is left once the nouns we handed it
        // are taken back out.
        var remainder = text
        for fact in given.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: fact, with: " ",
                                                       options: [.caseInsensitive, .diacriticInsensitive])
        }
        let prose = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing but the facts themselves is not evidence either way; the anchor
        // check has already established it is about this capsule.
        guard prose.contains(where: { $0.isLetter }) else { return true }
        return containsCJK(prose)
    }

    /// Substrings of a note worth treating as anchors.
    ///
    /// Words for scripts that space them; two-character runs for scripts that do not,
    /// which is the shortest unit that still means something in Japanese or Chinese.
    private static func contentTokens(of note: String) -> [String] {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count >= 3 }
        if !words.isEmpty { return words }
        let characters = Array(trimmed)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    /// Internal rather than private so the language rule can be asserted — the
    /// generation path itself is unreachable in CI, so the brief is one of the few
    /// parts of it a test can actually hold to account.
    static let instructions = """
        You write a single short sentence that helps someone recognise a moment from \
        their own past. You will be given only facts that the app already displays.

        Rules, in order of importance:
        1. Use only the given facts. Never invent a detail, a place, a person or an event.
        2. Never state or guess how the person felt. Describe the moment, not the emotion.
        3. One sentence, at most twenty words. No preamble, no quotation marks, no emoji.
        4. Write warmly and plainly, as a friend would. Do not be poetic or dramatic.
        5. If the facts are too thin to say anything true, repeat the given sounds plainly.
        6. Write in the SAME LANGUAGE as the facts you are given. The facts are already \
        in the reader's language; your sentence must match them. Do not translate them \
        into English, and do not answer in English when the facts are not English.
        """

    static func prompt(for facts: Facts) -> String {
        var lines = ["Time since: \(facts.elapsedPhrase)"]
        if !facts.soundPhrases.isEmpty {
            lines.append("Sounds heard: \(facts.soundPhrases.joined(separator: ", "))")
        }
        if let note = facts.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("Their own note: \(note)")
        }
        if let place = facts.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            lines.append("Place: \(place)")
        }
        return lines.joined(separator: "\n")
    }
}
