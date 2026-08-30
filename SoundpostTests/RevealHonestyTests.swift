import Testing
import Foundation
@testable import Soundpost

/// M18 §4D / S0 — the reveal stops presenting a guess as a fact.
///
/// `SoundSummaryWriter` used to be handed `Sounds heard: rain, wind` under
/// instruction 1, "use only the given facts", and it would write *"A rainy morning
/// at home."* — a classifier guess, stated as fact, in generated prose, on the
/// screen the whole app builds towards. M17 wrote the rule that breaks and did not
/// fix it (M17 §14C).
///
/// **The fix is withholding the input, not checking the output.** Three external
/// reviewers rejected the validator approach independently: "a rainy day" versus
/// "sounds of rain" is not a lexical property, and there is no regex for it across
/// EN, JA and ZH-Hans at once. So the guess never reaches the generator, and the
/// deterministic attributed line renders beside what it writes.
///
/// **This suite claims no UI coverage** — there is no UI-test target here. What it
/// pins is the policy the reveal reads, and the fact that the reveal reads it at all
/// is why `SoundSummaryWriter.facts(for:elapsedPhrase:)` and
/// `SoundprintDisplay.sentence(for:on:)` exist as functions rather than as
/// expressions inside a view body.
@MainActor
struct RevealHonestyTests {

    private func capsule(note: String? = nil,
                         place: String? = nil,
                         labels: [(String, Double)] = [("rain", 0.91)]) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = note
        if let place { capsule.place = Place(latitude: 35.71, longitude: 139.77, name: place) }
        capsule.soundprintRaw = labels.isEmpty ? nil : Soundprint(
            classifier: "version1",
            labels: labels.map { Soundprint.Label(identifier: $0.0, confidence: $0.1) }
        ).stored
        return capsule
    }

    private var rainPhrase: String { SoundVocabulary.displayName(for: "rain") ?? "rain" }
    private var windPhrase: String {
        SoundVocabulary.displayName(for: "wind_rustling_leaves") ?? "wind"
    }

    // MARK: The guess never reaches the generator

    /// The load-bearing test of §4D. A capsule that was heard as rain and wind builds
    /// a prompt that mentions neither — not the localized phrases the reveal would
    /// show, and not the classifier identifiers behind them.
    ///
    /// Asserted against `SoundSummaryWriter.facts(for:)`, the one place a `Facts` is
    /// built from a capsule, because the defect was never in the prompt builder: it
    /// was in a call site inside a view, where nothing could reach it.
    @Test func aCapsuleHeardAsRainBuildsAPromptThatNeverMentionsRain() throws {
        let heard = try capsule(note: "the storm broke", place: "Home",
                                labels: [("rain", 0.91), ("wind_rustling_leaves", 0.62)])
        // The premise: these ARE the phrases the reveal is about to render, so a
        // prompt free of them is a real absence and not an empty soundprint.
        #expect(SoundprintDisplay.phrases(for: heard, on: .detail, rejecting: .none, listening: true)
                == [rainPhrase, windPhrase])

        let prompt = SoundSummaryWriter.prompt(
            for: SoundSummaryWriter.facts(for: heard, elapsedPhrase: "8 months ago"))

        for phrase in [rainPhrase, windPhrase] {
            #expect(!prompt.localizedCaseInsensitiveContains(phrase),
                    "the prompt offers the model \(phrase), which it will state as fact")
        }
        for identifier in ["rain", "wind_rustling_leaves"] {
            #expect(!prompt.localizedCaseInsensitiveContains(identifier))
        }
        #expect(!prompt.localizedCaseInsensitiveContains("sound"))
        // And the facts that ARE the person's own are still there — otherwise this
        // passes by handing the model nothing at all.
        #expect(prompt.contains("the storm broke"))
        #expect(prompt.contains("Home"))
        #expect(prompt.contains("8 months ago"))
    }

    /// The brief went with the field. Rule 5 used to read "if the facts are too thin
    /// to say anything true, repeat the given sounds plainly" — an instruction to
    /// assert the guess, in the exact case where there is nothing else to assert.
    @Test func theBriefNoLongerAsksForTheSoundsBack() {
        let brief = SoundSummaryWriter.instructions
        #expect(!brief.localizedCaseInsensitiveContains("sound"))
        #expect(!brief.localizedCaseInsensitiveContains("heard"))
        // The rules that remain are still numbered contiguously, so removing one did
        // not leave the model reading a list with a hole in it.
        for number in 1...5 { #expect(brief.contains("\(number). ")) }
        #expect(!brief.contains("6. "))
    }

    // MARK: A capsule with nothing of the person's own gets no sentence

    /// The feature is honestly smaller now: sounds used to make a capsule "worth a
    /// sentence" all by themselves, and the sentence was the guess.
    @Test func aCapsuleWithNoNoteAndNoPlaceYieldsNoSentenceAtAll() throws {
        let soundsOnly = try capsule(note: nil, place: nil, labels: [("rain", 0.91)])
        #expect(SoundSummaryWriter.facts(for: soundsOnly, elapsedPhrase: "8 months ago").isEmpty)

        // One of the person's own facts is enough, either one.
        let noted = try capsule(note: "the storm broke", place: nil)
        let placed = try capsule(note: nil, place: "Home")
        #expect(!SoundSummaryWriter.facts(for: noted, elapsedPhrase: "8 months ago").isEmpty)
        #expect(!SoundSummaryWriter.facts(for: placed, elapsedPhrase: "8 months ago").isEmpty)
    }

    // There is deliberately no `summary(for:) == nil` assertion here. It would pass
    // on every machine in this project without exercising anything: `availability()`
    // returns `.deviceNotEligible` on a simulator, so `summary` returns nil before it
    // ever reaches the emptiness guard. `SoundSummaryWriterTests` carries one for
    // continuity with M15; this suite asserts the decision that is actually reachable.

    // MARK: The attributed line the reveal shows instead

    /// The reveal asks on `.detail`, not `.card`: it has room, and the guess sits
    /// below the note rather than in its place, so a capsule with a note still gets
    /// the line. That distinction is the whole reason the surface is a parameter.
    @Test func theRevealsAttributedLineIsProducedForACapsuleWithShowableLabels() throws {
        let heard = try capsule(note: "the storm broke", place: "Home")
        let sentence = try #require(
            SoundprintDisplay.sentence(for: heard, on: .detail, rejecting: .none, listening: true))
        #expect(sentence.contains(rainPhrase))
        // Attribution is in the copy, never in the layout — a bare noun under a note
        // reads as something the person wrote about their own memory.
        #expect(sentence != rainPhrase)
        #expect(sentence == SoundprintDisplay.sentence(for: [rainPhrase]))
        // The card would say nothing here, because a note occupies the one line it
        // has. The reveal is not the card.
        #expect(SoundprintDisplay.sentence(for: heard, on: .card, rejecting: .none, listening: true) == nil)
    }

    @Test func theRevealsAttributedLineIsAbsentWhenThereIsNothingShowable() throws {
        let unanalysed = try capsule(labels: [])
        #expect(SoundprintDisplay.sentence(for: unanalysed, on: .detail, rejecting: .none, listening: true) == nil)

        // Stored but not showable: below today's floor, so no screen may name it and
        // neither may this one.
        let tooQuiet = try capsule(labels: [("waterfall", 0.35)])
        #expect(SoundprintDisplay.sentence(for: tooQuiet, on: .detail, rejecting: .none, listening: true) == nil)

        // And with listening off, whatever is stored.
        let heard = try capsule()
        #expect(SoundprintDisplay.sentence(for: heard, on: .detail, rejecting: .none, listening: false) == nil)

        // A sealed-not-due capsule's sound is as hidden as its words.
        let sealed = try capsule()
        sealed.sealUntil = Date.now.addingTimeInterval(86_400)
        try sealed.transition(to: .sealed)
        #expect(SoundprintDisplay.sentence(for: sealed, on: .detail, rejecting: .none, listening: true) == nil)
    }
}
