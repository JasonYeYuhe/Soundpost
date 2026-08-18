import Testing
import Foundation
import SoundAnalysis
import SwiftData
@testable import Soundpost

/// A stub classifier so every rule — gates, floor, ordering, provenance — is tested
/// without Core ML in the loop (M15 §4J / Codex F11). CI must never depend on model
/// output being bit-stable across OS versions.
private struct StubClassifier: SoundClassifying {
    let classifierIdentifier: String
    var labels: [Soundprint.Label] = []
    var error: Error?
    /// Records whether the classifier was reached at all — how the gates are proven
    /// to short-circuit *before* analysis rather than filtering after it.
    final class Calls: @unchecked Sendable { var count = 0 }
    let calls = Calls()

    init(identifier: String = "stub", labels: [Soundprint.Label] = [], error: Error? = nil) {
        self.classifierIdentifier = identifier
        self.labels = labels
        self.error = error
    }

    func classify(clipAt url: URL) async throws -> [Soundprint.Label] {
        calls.count += 1
        if let error { throw error }
        return labels
    }
}

private struct Boom: Error {}

struct SoundprintTests {

    private func label(_ id: String, _ confidence: Double) -> Soundprint.Label {
        Soundprint.Label(identifier: id, confidence: confidence)
    }

    // MARK: - Encoding

    @Test func storedFormCarriesItsProvenanceAndRoundTrips() throws {
        let print = Soundprint(classifier: "version1",
                               labels: [label("rain", 0.82), label("wind", 0.41)])
        // New writes carry the gate generation; gate 1 alone is written without it,
        // because gate 1 is the format 1.6.0 shipped (see `Soundprint.stored`).
        #expect(print.stored == "1/version1/\(Soundprint.gateVersion)|rain=0.82;wind=0.41")

        let parsed = try #require(Soundprint(stored: print.stored))
        #expect(parsed.classifier == "version1")
        #expect(parsed.identifiers == ["rain", "wind"])
        #expect(abs((parsed.labels.first?.confidence ?? 0) - 0.82) < 0.001)
    }

    @Test func labelsAreAlwaysOrderedByConfidence() {
        let print = Soundprint(classifier: "version1",
                               labels: [label("quiet", 0.31), label("loud", 0.90), label("mid", 0.55)])
        #expect(print.identifiers == ["loud", "mid", "quiet"])
    }

    /// An analysed-but-empty soundprint is a real, distinct state: it records that we
    /// listened and chose to say nothing, which is what stops the backfill retrying
    /// the same clip forever.
    @Test func analysedButEmptyIsDistinctFromNeverAnalysed() throws {
        let empty = Soundprint(classifier: "version1", labels: [])
        #expect(empty.stored == "1/version1/\(Soundprint.gateVersion)|")
        let parsed = try #require(Soundprint(stored: empty.stored))
        #expect(parsed.isEmpty)
        #expect(parsed.classifier == "version1")
        // Never analysed:
        #expect(Soundprint(stored: nil) == nil)
        #expect(Soundprint(stored: "") == nil)
    }

    @Test func corruptStorageDegradesToNeverAnalysed() {
        for junk in ["nonsense", "1|rain=0.5", "rain=0.5", "1/", "/version1|rain=0.5",
                     "x/version1|rain=0.5", "1/version1", "|"] {
            #expect(Soundprint(stored: junk) == nil, "\(junk.debugDescription) should not parse")
        }
        // A future schema is not silently reinterpreted under this one's rules.
        #expect(Soundprint(stored: "2/version1|rain=0.9") == nil)
        // Individual bad pairs are dropped, the good ones survive.
        let mixed = Soundprint(stored: "1/version1|rain=0.8;broken;wind=abc;ok=0.5")
        #expect(mixed?.identifiers == ["rain", "ok"])
    }

    /// The classifier's own vocabulary contains both `rain` and `train`, so matching
    /// must be on whole identifiers. A substring match would find rainy capsules when
    /// searching for trains (Codex F4).
    @Test func matchingIsExactTokenNeverSubstring() {
        let print = Soundprint(classifier: "version1", labels: [label("train", 0.7)])
        #expect(print.contains("train"))
        #expect(!print.contains("rain"))
        #expect(!print.contains("train_whistle"))
    }

    // MARK: - The gates (M15 §4C)

    /// A clip shorter than one classification window yields nothing from Apple's
    /// analyzer, so we must not even ask — and must land in a terminal state rather
    /// than waiting for a callback that never comes.
    @Test func aClipShorterThanOneWindowIsNeverAnalysed() async {
        let stub = StubClassifier(labels: [label("rain", 0.9)])
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 0.5, peak: 0.9, classifier: stub)
        #expect(outcome == .skipped(.tooShort))
        #expect(stub.calls.count == 0, "the gate must short-circuit before analysis")
    }

    /// The one the probe caught: 3 s of digital silence classifies as `music 0.25`.
    /// Filtering after the fact is not enough — we never ask about a silent clip.
    @Test func aSilentClipIsNeverAnalysed() async {
        let stub = StubClassifier(labels: [label("music", 0.25)])
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 30, peak: 0.001, classifier: stub)
        #expect(outcome == .skipped(.tooQuiet))
        #expect(stub.calls.count == 0)
    }

    /// Belt and braces: even if a near-silent clip slipped past the amplitude gate,
    /// the confidence floor must sit above the measured 0.25 silence artefact.
    @Test func theConfidenceFloorSitsAboveTheMeasuredSilenceArtefact() async {
        #expect(SoundprintService.confidenceFloor > 0.25)
        let stub = StubClassifier(labels: [label("music", 0.25), label("synthesizer", 0.13)])
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 3, peak: 0.9, classifier: stub)
        #expect(outcome.soundprint?.isEmpty == true, "silence-shaped output must survive as nothing")
    }

    @Test func confidentLabelsSurviveAndAreCapped() async throws {
        let stub = StubClassifier(identifier: "version1", labels: [
            // `didgeridoo` is a REAL classifier label we deliberately do not name, and
            // it is the most confident one here — so this also proves the allow-list
            // outranks confidence rather than merely tie-breaking with it.
            label("didgeridoo", 0.99),
            label("rain", 0.91), label("wind", 0.72), label("bird_chirp_tweet", 0.55),
            label("traffic_noise", 0.40), label("music", 0.10),
        ])
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 12, peak: 0.6, classifier: stub)
        let print = try #require(outcome.soundprint)
        #expect(print.identifiers == ["rain", "wind", "bird_chirp_tweet"])  // capped at 3, ordered
        #expect(!print.contains("didgeridoo"), "an unnamed sound must never be stored")
        #expect(print.classifier == "version1")                             // provenance recorded
    }

    /// A denied label must not survive even at maximum confidence — and, because the
    /// filter runs before storage, it never reaches the model or the user's iCloud
    /// at all (M15 §4D-bis).
    @Test func aDeniedLabelIsNeverStoredEvenWhenCertain() async throws {
        let stub = StubClassifier(identifier: "version1", labels: [
            label("crying_sobbing", 1.0), label("screaming", 0.98), label("rain", 0.44),
        ])
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 12, peak: 0.6, classifier: stub)
        let print = try #require(outcome.soundprint)
        #expect(print.identifiers == ["rain"])
        for denied in ["crying_sobbing", "screaming"] {
            #expect(!print.stored.contains(denied), "\(denied) leaked into storage")
        }
    }

    /// "We could not listen" must never be able to break saving a memory.
    @Test func aClassifierFailureIsAnOutcomeNotAThrow() async {
        let stub = StubClassifier(labels: [], error: Boom())
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 5, peak: 0.5, classifier: stub)
        #expect(outcome == .skipped(.failed))
        #expect(outcome.soundprint == nil)
    }

    // MARK: - The amplitude source (M15 §4K — one decode, not two)

    // `TestSupport.writeSineClip` is main-actor bound, so this one test is too —
    // `MainActor.assumeIsolated` from a non-isolated suite *traps*, it does not hop.
    @MainActor
    @Test func theExtractorReportsAbsoluteLoudnessAlongsideTheWaveform() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SoundprintTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AudioStore(directory: directory)

        let loud = try TestSupport.writeSineClip(into: store, seconds: 1.0)
        let extraction = try WaveformExtractor.extract(from: store.url(for: loud), buckets: 32)

        // The waveform is normalized — its peak is always 1, which is exactly why it
        // cannot serve as a silence gate on its own.
        #expect(extraction.samples.count == 32)
        #expect(abs((extraction.samples.max() ?? 0) - 1.0) < 0.001)
        // The absolute peak survives separately, and a real tone is well above the gate.
        #expect(extraction.peak > SoundprintService.minimumPeak)
        // And the legacy accessor still behaves for every existing call site.
        #expect(try WaveformExtractor.samples(from: store.url(for: loud), buckets: 32) == extraction.samples)
    }

    // MARK: - The model field

    @Test func aCapsuleStartsWithNoSoundprintAndRoundTripsOne() throws {
        let capsule = Capsule()
        #expect(capsule.soundprintRaw == nil)
        #expect(Soundprint(stored: capsule.soundprintRaw) == nil)

        capsule.soundprintRaw = Soundprint(classifier: "version1", labels: [label("rain", 0.8)]).stored
        #expect(Soundprint(stored: capsule.soundprintRaw)?.contains("rain") == true)
    }
}

// MARK: - The vocabulary (M15 §4D / §4D-bis)

struct SoundVocabularyTests {

    /// The curated list is the *whole* answer to "may we show this?", so it must be
    /// deliberate: big enough to be useful, small enough to stay translated.
    ///
    /// §4D originally set 40–60. Raised twice, each time as a deliberate revision
    /// rather than a test bent to fit: to 40–90 at 74 labels (§11M), then to 40–120
    /// at 92 (§11N, after measurement cleared a batch that intuition had held back).
    /// The bound exists to stop the list drifting toward "everything the classifier
    /// knows", and the cost it stands for is three hand-written translations per
    /// label plus the gate that keeps them honest. It stays *well below* the
    /// taxonomy's 303 so exceeding it always costs this argument again.
    @Test func theVocabularyIsCuratedNotExhaustive() {
        let count = SoundVocabulary.displayNames.count
        #expect(count >= 40 && count <= 120, "\(count) labels — §4D/§11N targets a curated 40–120")
        #expect(SoundVocabulary.allowedIdentifiers.count == count)
        for (identifier, phrase) in SoundVocabulary.displayNames {
            #expect(!identifier.isEmpty)
            #expect(!phrase.isEmpty, "\(identifier) has no display phrase")
        }
    }

    /// The one that catches a typo. These identifiers are matched against the
    /// classifier's output as exact tokens, so a misspelling would not fail loudly —
    /// it would silently never match anything, forever.
    @Test func everyAllowedIdentifierReallyExistsInApplesVocabulary() throws {
        let known = Set(try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications)
        for identifier in SoundVocabulary.allowedIdentifiers {
            #expect(known.contains(identifier), "\(identifier) is not a real classifier label")
        }
    }

    /// Same trap on the other list — a denied label that does not exist protects
    /// nothing, and would quietly rot as the taxonomy changes.
    @Test func everyDeniedIdentifierReallyExistsToo() throws {
        let known = Set(try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications)
        for identifier in SoundVocabulary.denied {
            #expect(known.contains(identifier), "denied label \(identifier) is not a real classifier label")
        }
    }

    /// The guard rail: nobody can ever add "crying_sobbing" to the allow-list without
    /// this failing. That is the whole point of keeping the deny-list around when the
    /// allow-list already decides everything.
    @Test func nothingIsBothAllowedAndDenied() {
        let overlap = Set(SoundVocabulary.allowedIdentifiers).intersection(SoundVocabulary.denied)
        #expect(overlap.isEmpty, "these are both allowed and denied: \(overlap.sorted())")
    }

    @Test func theDenyListCoversTheDistressAndAlarmClasses() {
        // Spot-check the ones that would be worst on a lock screen.
        for identifier in ["crying_sobbing", "baby_crying", "screaming", "gunshot_gunfire",
                           "glass_breaking", "snoring", "whispering", "toilet_flush"] {
            #expect(SoundVocabulary.denied.contains(identifier), "\(identifier) should be denied")
            #expect(!SoundVocabulary.isAllowed(identifier), "\(identifier) must not be showable")
        }
    }

    @Test func anUnknownLabelHasNoName() {
        #expect(SoundVocabulary.displayName(for: "not_a_real_label") == nil)
        #expect(!SoundVocabulary.isAllowed("not_a_real_label"))
        // A real classifier label we simply chose not to name is equally invisible.
        #expect(!SoundVocabulary.isAllowed("didgeridoo"))
    }

    @Test func anAllowedLabelResolvesToRealCopy() throws {
        let name = try #require(SoundVocabulary.displayName(for: "rain"))
        #expect(!name.isEmpty)
    }
}

// MARK: - Capture suggestions (M15 §4E / S3)

/// Suggestions must never become decisions. These pin the three ways that could go
/// wrong: applying itself, eating what the user wrote, or claiming a mood.
@MainActor
struct SoundSuggestionTests {

    private func viewModel(withNote note: String = "") -> CaptureViewModel {
        let vm = CaptureViewModel()
        vm.note = note
        return vm
    }

    /// A soundprint arriving must not touch the note or the mood on its own — the
    /// user has to tap.
    ///
    /// The earlier version of this test never landed a soundprint: it built a bare
    /// view model and asserted the note and mood were still empty, which is a
    /// scenario where nothing *could* have changed. It passed identically against an
    /// implementation that pre-filled the note from a guess. This one drives the
    /// actual save path with a classification present.
    @Test func aSoundprintNeverAppliesItself() async throws {
        let store = try TestSupport.freshStore()
        let vm = CaptureViewModel()
        // Drive the REAL arrival path: the classification completion is where a
        // regression would write the note, and setting `soundprint` from the test
        // would step right over it.
        vm.classify = { _, _, _ in
            Soundprint(classifier: "version1",
                       labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)])
        }
        vm.finishRecordingForTesting(fileName: "abc.m4a", duration: 7)
        await vm.awaitClassificationForTesting()
        #expect(vm.soundprint != nil, "the classification must actually have landed")
        #expect(vm.note.isEmpty, "and the completion must not have written the user's line")
        #expect(vm.mood == nil)

        let capsule = try #require(try vm.save(using: store))

        #expect(capsule.soundprintRaw != nil, "the soundprint itself is stored")
        #expect(capsule.note == nil, "a guess must never become the user's one line")
        #expect(capsule.mood == nil, "and never their mood")
    }

    /// Declining is the other half: the user typed their own line, the classifier
    /// heard something else, and what they wrote survives untouched.
    @Test func decliningTheSuggestionLeavesTheUsersOwnWords() async throws {
        let store = try TestSupport.freshStore()
        let vm = CaptureViewModel()
        vm.classify = { _, _, _ in
            Soundprint(classifier: "version1",
                       labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)])
        }
        vm.finishRecordingForTesting(fileName: "abc.m4a", duration: 7)
        vm.note = "the storm broke"
        await vm.awaitClassificationForTesting()

        let capsule = try #require(try vm.save(using: store))
        #expect(capsule.note == "the storm broke")
    }

    /// Joining a suggestion onto existing text must not wedge an ASCII space between
    /// two CJK runs — two of the three languages this ships in do not write that way,
    /// and this is the exact path the release notes advertise.
    @Test func acceptingASuggestionJoinsCorrectlyForEachScript() {
        #expect(CaptureView.needsSpaceBetween("morning", "rain"))
        #expect(CaptureView.needsSpaceBetween("朝の音", "rain"))
        #expect(CaptureView.needsSpaceBetween("morning", "雨"))
        #expect(!CaptureView.needsSpaceBetween("朝の音", "雨"))
        #expect(!CaptureView.needsSpaceBetween("下雨的清晨", "雨声"))
        #expect(!CaptureView.needsSpaceBetween("", "雨"))
    }

    /// The classifier describes the room; the mood is the user's reading of the
    /// moment. M15 deliberately never infers one from the other, so no mapping from
    /// sound label to `Mood` exists anywhere to be tested — this pins that absence.
    @Test func moodIsNeverDerivedFromSound() {
        // Every allowed label resolves to copy, and to nothing else.
        for identifier in SoundVocabulary.allowedIdentifiers {
            #expect(SoundVocabulary.displayName(for: identifier) != nil)
        }
        // A capsule's mood remains whatever the user set, independent of any soundprint.
        let capsule = Capsule()
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "laughter", confidence: 0.99)]
        ).stored
        #expect(capsule.mood == nil, "a confident 'laughter' must not imply joyful")
    }

    @Test func nothingIsSuggestedWhenThereIsNothingConfidentToSay() {
        let empty = Soundprint(classifier: "version1", labels: [])
        #expect(empty.isEmpty, "an empty soundprint renders no chips at all")
        #expect(Soundprint(stored: nil) == nil)
    }
}

// MARK: - Search by sound (M15 §S4)

/// Sound is content. The rule that matters is not "does search work" but "does it
/// leak" — a sealed-not-due capsule's sound must be as hidden as its note.
@MainActor
struct SoundSearchTests {

    private func captured(soundLabels: [String], note: String? = nil) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = note
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: soundLabels.enumerated().map {
                Soundprint.Label(identifier: $1, confidence: 0.9 - Double($0) * 0.1)
            }
        ).stored
        return capsule
    }

    @Test func searchingForASoundFindsTheCapsule() throws {
        let rainy = try captured(soundLabels: ["rain"])
        let noisy = try captured(soundLabels: ["traffic_noise"])
        let results = GalleryFilter.apply([rainy, noisy], .init(searchText: "rain"))
        #expect(results.count == 1)
        #expect(results.first === rainy)
    }

    /// The trap the classifier's own vocabulary sets: it contains both `rain` and
    /// `train`. Matching the shown phrase (not the raw blob) keeps them apart.
    @Test func searchingForRainDoesNotMatchATrain() throws {
        let train = try captured(soundLabels: ["train"])
        #expect(GalleryFilter.apply([train], .init(searchText: "rain")).isEmpty)
        #expect(GalleryFilter.apply([train], .init(searchText: "train")).count == 1)
    }

    /// The load-bearing one: a sealed-not-due capsule must not be findable by the
    /// sound it hides, exactly as it is not findable by its note.
    @Test func aSealedCapsuleNeverLeaksItsSound() throws {
        let sealed = try captured(soundLabels: ["rain"], note: "the storm")
        try sealed.transition(to: .sealed)
        sealed.sealUntil = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)

        #expect(!sealed.isContentVisible())
        #expect(GalleryFilter.apply([sealed], .init(searchText: "rain")).isEmpty,
                "a sealed capsule's sound is as hidden as its note")
        #expect(GalleryFilter.apply([sealed], .init(searchText: "storm")).isEmpty)

        // Once its day comes, it is findable by both again.
        sealed.sealUntil = Date(timeIntervalSinceNow: -60)
        #expect(sealed.isContentVisible())
        #expect(GalleryFilter.apply([sealed], .init(searchText: "rain")).count == 1)
    }

    @Test func aCapsuleWithNoSoundprintSimplyDoesNotMatch() throws {
        let plain = try captured(soundLabels: [])
        plain.soundprintRaw = nil
        #expect(GalleryFilter.apply([plain], .init(searchText: "rain")).isEmpty)
        #expect(!GalleryFilter.soundMatches(plain, query: "rain"))
    }

    /// A label we refuse to name is not searchable either — there is no phrase to
    /// match, so it cannot be reached even if it somehow got stored.
    @Test func anUnnamedLabelIsUnsearchable() throws {
        let capsule = try captured(soundLabels: [])
        capsule.soundprintRaw = "1/version1|crying_sobbing=0.99"
        #expect(!GalleryFilter.soundMatches(capsule, query: "crying"))
        #expect(GalleryFilter.apply([capsule], .init(searchText: "crying")).isEmpty)
    }
}

/// The phrase matcher, pinned directly — the `rain` / "a train" collision is subtle
/// enough that it deserves its own tests rather than only being caught through the
/// gallery.
struct SoundPhraseMatchingTests {
    @Test func aMatchMustBeginAWord() {
        #expect(GalleryFilter.matches(phrase: "a train", query: "train"))
        #expect(GalleryFilter.matches(phrase: "a train", query: "a"))
        #expect(!GalleryFilter.matches(phrase: "a train", query: "rain"),
                "'rain' sits inside 'train' — matching it would surface the wrong memory")
        #expect(GalleryFilter.matches(phrase: "rain", query: "rain"))
        #expect(GalleryFilter.matches(phrase: "raindrops", query: "rain"))
    }

    @Test func matchingIsCaseAndDiacriticInsensitiveAndProgressive() {
        #expect(GalleryFilter.matches(phrase: "birdsong", query: "BIRD"))
        #expect(GalleryFilter.matches(phrase: "a crackling fire", query: "crack"))
        #expect(GalleryFilter.matches(phrase: "a crackling fire", query: "fire"))
        #expect(!GalleryFilter.matches(phrase: "a crackling fire", query: "ire"))
        #expect(!GalleryFilter.matches(phrase: "birdsong", query: ""))
    }

    /// The boundary rule applies to scripts that have boundaries. Requiring one in
    /// ja/zh degraded matching to "prefix of the phrase" — not a stricter rule, a
    /// broken one, on the feature 1.6.0 leads with (§11I).
    @Test func cjkQueriesMatchAnywhereInThePhrase() {
        #expect(GalleryFilter.matches(phrase: "车流声", query: "车流"))
        #expect(GalleryFilter.matches(phrase: "鳥のさえずり", query: "鳥"))
        // These are the ones that used to fail.
        #expect(GalleryFilter.matches(phrase: "鳥のさえずり", query: "さえずり"),
                "a Japanese user searching the word they remember must find the phrase")
        #expect(GalleryFilter.matches(phrase: "车流声", query: "流声"))
        #expect(GalleryFilter.matches(phrase: "猫がのどを鳴らす音", query: "のど"))
    }

    /// Every containment among the 52 shipped Japanese phrases is morphological, so
    /// substring matching there returns *more right* answers, not wrong ones.
    @Test func cjkContainmentIsSemanticallyRight() {
        #expect(GalleryFilter.matches(phrase: "雷雨", query: "雨"), "thunderstorm is a kind of rain")
        #expect(GalleryFilter.matches(phrase: "雨だれ", query: "雨"))
        #expect(GalleryFilter.matches(phrase: "風に揺れる葉", query: "風"))
        #expect(GalleryFilter.matches(phrase: "赤ちゃんの笑い声", query: "笑い声"))
    }

    /// Loosening CJK must not loosen Latin: `rain`/`train` is an orthographic
    /// accident, and a train is not a kind of rain.
    @Test func looseningCJKDoesNotLoosenLatin() {
        #expect(!GalleryFilter.matches(phrase: "a train", query: "rain"))
        #expect(!GalleryFilter.matches(phrase: "a crackling fire", query: "ire"))
    }

    /// A mixed query still takes the CJK path — the point is the script the user is
    /// typing in, and a query containing kana is not a Latin query.
    @Test func aMixedScriptQueryTakesTheCJKPath() {
        #expect(GalleryFilter.matches(phrase: "Wi-Fiの音", query: "Fiの"))
    }
}

// MARK: - Consent + the resurface moment (M15 §4I / S5)

/// `.serialized` because these mutate one shared `UserDefaults` key: run in
/// parallel, one test's save/restore races another's read.
@Suite(.serialized)
struct SoundConsentTests {

    // Save-and-restore of the shared key was not enough: suites run in parallel, so
    // another suite reads between this one's write and its restore. Each test now
    // owns its storage (TestSupport.withIsolatedListeningPreference).
    private func withListening(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        try TestSupport.withIsolatedListeningPreference(enabled, body)
    }

    /// Listening is on unless the user says otherwise — and that has to be explicit,
    /// because `bool(forKey:)` returns false for an unset key.
    @Test func listeningDefaultsToOn() {
        let name = "soundpost.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        // A store with the key genuinely unset — the state a first launch sees.
        SoundAnalysisPreferences.$defaultsSuiteName.withValue(name) {
            #expect(UserDefaults(suiteName: name)?.object(forKey: SoundAnalysisPreferences.enabledKey) == nil)
            #expect(SoundAnalysisPreferences.isEnabled)
        }
    }

    @Test func consentRoundTrips() {
        withListening(false) { #expect(!SoundAnalysisPreferences.isEnabled) }
        withListening(true) { #expect(SoundAnalysisPreferences.isEnabled) }
    }

    /// Withdrawing consent must stop the analysis itself, not merely hide its
    /// output — and it must short-circuit before the classifier is ever reached.
    @Test func withholdingConsentStopsAnalysisEntirely() async {
        let stub = StubClassifier(labels: [Soundprint.Label(identifier: "rain", confidence: 0.99)])
        let outcome = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"),
            duration: 30, peak: 0.9, classifier: stub, isEnabled: false)
        #expect(outcome == .skipped(.notPermitted))
        #expect(stub.calls.count == 0, "consent must be checked before anything else")
        #expect(outcome.soundprint == nil)
    }
}

/// The lock-screen rule: a sound label is the user's private words, so it can only
/// appear where their note already could.
struct SoundNotificationCopyTests {

    private func digest(note: String? = nil, place: String? = nil, sound: String?) -> NotificationCopy.Digest {
        NotificationCopy.Digest(
            createdAt: Date(timeIntervalSinceNow: -12 * 86_400),
            note: note,
            placeName: place,
            mood: .calm,
            soundprint: sound.map {
                Soundprint(classifier: "version1",
                           labels: [Soundprint.Label(identifier: $0, confidence: 0.9)])
            }
        )
    }

    @Test func aSoundFillsTheGapWhenThereAreNoWords() throws {
        let lead = try #require(digest(sound: "rain").lead)
        #expect(lead == SoundVocabulary.displayName(for: "rain"))
    }

    /// The user's own words always win — a guess never displaces them.
    @Test func theUsersOwnWordsOutrankTheGuess() {
        #expect(digest(note: "the storm broke", sound: "rain").lead == "the storm broke")
        #expect(digest(place: "Home", sound: "rain").lead == "Home")
    }

    @Test func nothingIsInventedWhenThereIsNoSoundprint() {
        #expect(digest(sound: nil).lead == nil)
        // A label we refuse to name yields no lead either.
        #expect(digest(sound: "crying_sobbing").lead == nil)
    }

    /// The load-bearing privacy check: with personalized notifications off, no sound
    /// label can reach a notification body — the generic copy is used instead.
    @Test func aSoundLabelNeverReachesALockScreenTheUserOptedOutOf() throws {
        let item = PlannedNotification(capsuleID: UUID(),
                                       fireDate: Date(timeIntervalSinceNow: 60),
                                       timeZoneID: nil,
                                       kind: .echo)
        let withSound = digest(sound: "rain")
        let phrase = try #require(SoundVocabulary.displayName(for: "rain"))

        let optedOut = NotificationCopy.make(for: item, digest: withSound, personalized: false)
        #expect(!optedOut.body.contains(phrase), "opted out, yet the sound leaked into the body")

        let optedIn = NotificationCopy.make(for: item, digest: withSound, personalized: true)
        #expect(optedIn.body.contains(phrase))
    }
}

// MARK: - Backfill (M15 §4H / S7)

/// `.serialized`, and every assertion is scoped to the capsule the test created.
///
/// These tests are `async`, so — unlike the synchronous `@MainActor` suites — they
/// genuinely interleave with everything else. That makes the *shared* container
/// unusable here: another suite's `TestSupport.freshStore()` is a container-wide
/// `delete(model:)`, and landing it inside one of these `await`s deletes the
/// capsule under test, so the backfill finds nothing and the failure reads as a
/// product bug. Each test therefore takes its own container via `isolatedStore()`.
@Suite(.serialized)
@MainActor
struct SoundprintBackfillTests {
    // Every call pins `isEnabled` explicitly. The backfill reads
    // `SoundAnalysisPreferences` by default, and `SoundConsentTests` mutates that
    // same key — in parallel, that made these tests silently return 0. A test must
    // not depend on global mutable state it does not own.

    private func seed(_ store: CapsuleStore, audio: Data?, duration: Double = 6) throws -> Capsule {
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "clip.m4a", audioData: audio,
                               durationSeconds: duration, waveformSamples: [0.5])
        return capsule
    }

    private func realClip() throws -> (store: AudioStore, data: Data, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BackfillTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let audioStore = AudioStore(directory: directory)
        let name = try TestSupport.writeSineClip(into: audioStore, seconds: 2.0)
        return (audioStore, try Data(contentsOf: audioStore.url(for: name)), directory)
    }

    @Test func itLabelsCapsulesRecordedBeforeM15() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        let capsule = try seed(store, audio: clip.data)
        try store.save()
        #expect(capsule.soundprintRaw == nil)

        let stub = StubClassifier(identifier: "version1",
                                  labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)])
        _ = await SoundprintBackfill.backfill(in: store.context, limit: 10, classifier: stub, isEnabled: true)
        // Scoped to *this* capsule rather than a global count.
        #expect(Soundprint(stored: capsule.soundprintRaw)?.contains("rain") == true)
    }

    /// The idempotence guarantee: a clip that legitimately yields nothing gets an
    /// analysed-but-empty marker, so the next launch does not examine it again.
    @Test func aTerminalNoResultIsRecordedSoItIsNeverRetried() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        // Duration under one classifier window → terminally unclassifiable.
        let capsule = try seed(store, audio: clip.data, duration: 0.4)
        try store.save()

        let stub = StubClassifier(identifier: "version1", labels: [])
        _ = await SoundprintBackfill.backfill(in: store.context, limit: 10, classifier: stub, isEnabled: true)

        // The verdict is recorded — analysed, with nothing to say — not left nil.
        let recorded = try #require(Soundprint(stored: capsule.soundprintRaw))
        #expect(recorded.isEmpty)
        #expect(recorded.classifier == "version1")

        // And a second pass does not reconsider it: the predicate only ever selects
        // capsules whose soundprint is still nil.
        let before = capsule.soundprintRaw
        _ = await SoundprintBackfill.backfill(in: store.context, limit: 10, classifier: stub, isEnabled: true)
        #expect(capsule.soundprintRaw == before)
    }

    /// §11H: a library larger than one batch must settle in **one** launch.
    ///
    /// The bound is on memory (one clip in flight) and on politeness, not on how much
    /// gets done — but stopping after a single batch made "search finds your rainy
    /// mornings" true only after roughly fifteen launches for a 300-capsule library.
    @Test func drainingSettlesALibraryBiggerThanOneBatch() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        for _ in 0..<7 { _ = try seed(store, audio: clip.data) }
        try store.save()

        let stub = StubClassifier(identifier: "version1",
                                  labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)])
        let actor = SoundprintBackfill(modelContainer: store.context.container)
        let written = await actor.drain(batchSize: 2, pauseBetweenBatches: .zero,
                                        classifier: stub, isEnabled: true)

        #expect(written == 7, "every capsule, not just the first batch")
        let pending = try store.context.fetch(
            FetchDescriptor<Capsule>(predicate: #Predicate { $0.soundprintRaw == nil }))
        #expect(pending.isEmpty)
    }

    /// The ceiling is a runaway guard, not a quota — and hitting it must not read as
    /// completion, so it stops and says so rather than reporting the library settled.
    @Test func drainingStopsAtItsCeilingRatherThanRunningForever() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        for _ in 0..<6 { _ = try seed(store, audio: clip.data) }
        try store.save()

        let stub = StubClassifier(identifier: "version1",
                                  labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)])
        let actor = SoundprintBackfill(modelContainer: store.context.container)
        let written = await actor.drain(batchSize: 2, maximumBatches: 2,
                                        pauseBetweenBatches: .zero,
                                        classifier: stub, isEnabled: true)

        #expect(written == 4, "two batches of two, then the ceiling")
        let pending = try store.context.fetch(
            FetchDescriptor<Capsule>(predicate: #Predicate { $0.soundprintRaw == nil }))
        #expect(pending.count == 2, "the remainder is left for the next launch, not silently dropped")
    }

    /// A user who turned listening off must not have their back catalogue quietly
    /// analysed instead — consent is checked in the backfill too, not only capture.
    @Test func itRespectsWithdrawnConsent() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        let capsule = try seed(store, audio: clip.data)
        try store.save()

        let stub = StubClassifier(identifier: "version1",
                                  labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)])
        let written = await SoundprintBackfill.backfill(in: store.context, limit: 10,
                                                       classifier: stub, isEnabled: false)
        #expect(written == 0)
        #expect(stub.calls.count == 0)
        #expect(capsule.soundprintRaw == nil, "a withheld consent must leave the capsule untouched")
    }

    /// An already-analysed capsule is never reconsidered, so a settled library
    /// costs nothing on every launch.
    @Test func anAlreadyAnalysedCapsuleIsLeftAlone() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        let capsule = try seed(store, audio: clip.data)
        let existing = Soundprint(classifier: "version1",
                                  labels: [Soundprint.Label(identifier: "ocean", confidence: 0.8)]).stored
        capsule.soundprintRaw = existing
        try store.save()

        let stub = StubClassifier(identifier: "version1",
                                  labels: [Soundprint.Label(identifier: "rain", confidence: 0.99)])
        _ = await SoundprintBackfill.backfill(in: store.context, limit: 10, classifier: stub, isEnabled: true)
        #expect(capsule.soundprintRaw == existing, "an analysed capsule must not be re-analysed")
    }

    /// Consent withdrawn *during* a batch. The batch reads `isEnabled` once at
    /// entry, so without a live re-check it would classify happily and then save
    /// labels on top of the capsules the erase had just cleared — on the same
    /// device, seconds after the user asked it to stop.
    @Test func itDiscardsTheBatchWhenConsentIsWithdrawnMidRun() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.isolatedStore()
        let capsule = try seed(store, audio: clip.data)
        try store.save()

        let stub = StubClassifier(identifier: "version1",
                                  labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)])
        // Granted at entry, withdrawn by the time the loop looks again.
        let granted = MutableFlag(true)
        let written = await SoundprintBackfill.backfill(
            in: store.context, limit: 10, classifier: stub, isEnabled: true,
            consentStillGranted: { granted.take() }
        )

        #expect(written == 0)
        #expect(capsule.soundprintRaw == nil, "a batch that outlived consent must write nothing")
        // Without this the test would also pass against a backfill that never got
        // going at all — it has to prove the batch ran and was then *discarded*.
        #expect(stub.calls.count > 0, "the batch must have actually classified before being abandoned")
    }
}

/// A `Sendable` one-shot flag: the first read returns the seeded value, every read
/// after it returns `false`. Models "consent was granted when the batch started and
/// withdrawn before it looked again" without needing a real clock.
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { value = false }
        return value
    }
}

// MARK: - Erasing what it heard (M15 §4I)

/// The one behaviour the 1.6.0 release notes promise by name — "turning this off
/// also erases what it already heard". It had no coverage at all while it lived as
/// a private method inside `SettingsView`.
@Suite(.serialized)
@MainActor
struct SoundprintEraserTests {

    private func seed(_ store: CapsuleStore, soundprint: String?) throws -> Capsule {
        let capsule = store.create()
        capsule.soundprintRaw = soundprint
        return capsule
    }

    @Test func itClearsEveryStoredSoundprint() throws {
        let store = try TestSupport.isolatedStore()
        let heard = try seed(store, soundprint: Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)]).stored)
        let analysedEmpty = try seed(store, soundprint: Soundprint(classifier: "version1").stored)
        let never = try seed(store, soundprint: nil)
        try store.save()

        let erased = try SoundprintEraser.eraseAll(in: store.context)

        #expect(erased == 2, "both the labelled and the analysed-but-empty capsule are cleared")
        #expect(heard.soundprintRaw == nil)
        #expect(analysedEmpty.soundprintRaw == nil, "the analysed-but-empty marker is also something it heard")
        #expect(never.soundprintRaw == nil)
    }

    /// Back to `nil`, not to the analysed-but-empty marker: `nil` is the truthful
    /// "never analysed", and it is also what lets the backfill pick the capsule up
    /// again if the user changes their mind.
    @Test func itErasesToNeverAnalysedSoTurningItBackOnWorks() async throws {
        let store = try TestSupport.isolatedStore()
        let capsule = try seed(store, soundprint: Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)]).stored)
        try store.save()

        _ = try SoundprintEraser.eraseAll(in: store.context)
        #expect(Soundprint(stored: capsule.soundprintRaw) == nil)

        let pending = try store.context.fetch(
            FetchDescriptor<Capsule>(predicate: #Predicate { $0.soundprintRaw == nil }))
        #expect(pending.contains { $0.id == capsule.id },
                "an erased capsule is eligible for the backfill again")
    }

    @Test func erasingAnUnheardLibraryIsANoOp() throws {
        let store = try TestSupport.isolatedStore()
        _ = try seed(store, soundprint: nil)
        try store.save()
        #expect(try SoundprintEraser.eraseAll(in: store.context) == 0)
    }
}

// MARK: - The Apple Intelligence sentence (M15 §4G / S6)

/// The generation itself cannot be unit-tested — it needs iOS 26, eligible hardware
/// and Apple Intelligence switched on, and its output is nondeterministic by design.
/// What IS testable is everything guarding it: when we refuse to ask, and what we
/// refuse to show. That is where the risk lives.
struct SoundSummaryWriterTests {

    private func facts(sounds: [String] = ["rain"], note: String? = nil) -> SoundSummaryWriter.Facts {
        SoundSummaryWriter.Facts(soundPhrases: sounds, note: note,
                                 placeName: "Home", elapsedPhrase: "8 months ago")
    }

    /// Withdrawing consent to listen also withdraws consent to write about what was
    /// heard — otherwise the switch would stop the ears and leave the mouth running.
    @Test func itDoesNotWriteWhenListeningIsOff() async {
        #expect(await SoundSummaryWriter.summary(for: facts(), isListeningEnabled: false) == nil)
    }

    @Test func itDoesNotWriteWhenThereIsNothingToSay() async {
        let empty = SoundSummaryWriter.Facts(soundPhrases: [], note: nil,
                                             placeName: "Home", elapsedPhrase: "a year ago")
        #expect(empty.isEmpty)
        #expect(await SoundSummaryWriter.summary(for: empty, isListeningEnabled: true) == nil)
        // A user's own words alone are enough to be worth a sentence.
        #expect(!facts(sounds: [], note: "the storm broke").isEmpty)
    }

    /// On any device without Apple Intelligence this returns a reason rather than
    /// crashing or hanging — and the caller simply shows its own copy.
    @Test func availabilityIsSafeToAskOnEveryOS() {
        let reason = SoundSummaryWriter.availability()
        if let reason {
            #expect(!reason.rawValue.isEmpty)
        }
    }

    /// Facts whose anchors ("rain", "Home") the sample sentences below mention, so
    /// these tests exercise the guard they are about rather than tripping over the
    /// fact-mention check.
    private var rainFacts: SoundSummaryWriter.Facts {
        facts(sounds: ["rain"], note: nil)
    }

    // MARK: Output validation — the part that protects the memory

    @Test func itStripsTheQuotesModelsLikeToAdd() {
        #expect(SoundSummaryWriter.validated("\"Rain on the window.\"", describing: rainFacts) == "Rain on the window.")
        #expect(SoundSummaryWriter.validated("“Rain on the window.”", describing: rainFacts) == "Rain on the window.")
    }

    @Test func itRejectsARefusalOrAPreamble() {
        for raw in ["I can't help with that.", "I'm sorry, but I cannot.",
                    "Sure, here's a sentence: rain.", "Here is your sentence.",
                    "As an AI language model, I..."] {
            #expect(SoundSummaryWriter.validated(raw, describing: rainFacts) == nil, "\(raw.debugDescription) should be rejected")
        }
    }

    @Test func itRejectsAnythingThatRanOn() {
        #expect(SoundSummaryWriter.validated(String(repeating: "a", count: 500), describing: rainFacts) == nil)
        #expect(SoundSummaryWriter.validated("First thought.\n\nSecond thought.", describing: rainFacts) == nil)
        #expect(SoundSummaryWriter.validated("   ", describing: rainFacts) == nil)
        #expect(SoundSummaryWriter.validated("", describing: rainFacts) == nil)
    }

    @Test func itAcceptsTheSentenceWeAskedFor() {
        let good = "A rainy afternoon at home, eight months ago."
        #expect(SoundSummaryWriter.validated(good, describing: rainFacts) == good)
    }

    // MARK: The prompt only ever carries what the app already shows

    // MARK: Language — the guards that keep an English sentence off a Japanese screen

    /// Regional variants must match. The model advertises `ja-JP`; the app may be
    /// running as plain `ja`. An exact-Locale comparison would refuse a language the
    /// model actually speaks.
    @Test func aRegionalVariantCountsAsSupport() {
        let supported: Set<Locale.Language> = [Locale.Language(identifier: "ja-JP"),
                                               Locale.Language(identifier: "en-US")]
        #expect(SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "ja"), in: supported))
        #expect(SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "en"), in: supported))
    }

    @Test func anUnsupportedLanguageIsNotClaimedAsSupported() {
        let supported: Set<Locale.Language> = [Locale.Language(identifier: "en-US")]
        #expect(!SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "ja"), in: supported))
        #expect(!SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "zh-Hans"), in: supported))
    }

    /// Script is compared when both sides declare one — Simplified and Traditional
    /// are not interchangeable to a reader.
    @Test func scriptIsRespectedWhenBothSidesDeclareOne() {
        let supported: Set<Locale.Language> = [Locale.Language(identifier: "zh-Hans-CN")]
        #expect(SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "zh-Hans"), in: supported))
        #expect(!SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "zh-Hant"), in: supported))
    }

    /// The failure this prevents: an English sentence rendered above a Japanese note,
    /// because nothing in the brief ever told the model which language to answer in.
    @Test func theBriefPinsTheOutputLanguageToTheFacts() {
        let brief = SoundSummaryWriter.instructions
        #expect(brief.localizedCaseInsensitiveContains("same language"))
        #expect(brief.localizedCaseInsensitiveContains("do not translate"))
        #expect(brief.localizedCaseInsensitiveContains("English"),
                "the rule has to name the failure mode it is preventing")
    }

    @Test func theRefusalListCoversEveryShippedLanguage() {
        #expect(SoundSummaryWriter.refusalPrefixes.contains { $0.contains("申し訳") })
        #expect(SoundSummaryWriter.refusalPrefixes.contains { $0.contains("抱歉") })
        #expect(SoundSummaryWriter.refusalPrefixes.contains { $0.hasPrefix("i can") })
    }

    /// The hole this closes: the blocklist was English-only while the model is now
    /// asked to answer in the reader's language, so a Japanese or Chinese refusal
    /// cleared every guard and rendered as if it described the memory.
    @Test func itRejectsARefusalInJapaneseOrChinese() {
        for raw in ["申し訳ありませんが、お手伝いできません。",
                    "すみません、それはできません。",
                    "抱歉，我无法完成这个请求。",
                    "对不起，我不能这样做。",
                    "以下是您的句子：雨。"] {
            #expect(SoundSummaryWriter.validated(raw, describing: rainFacts) == nil,
                    "\(raw) should be rejected")
        }
    }

    /// The guard that does not depend on knowing the phrasing: a sentence that
    /// mentions none of the facts we handed over is not a sentence about this memory.
    @Test func itRejectsProseThatMentionsNoneOfTheGivenFacts() {
        let unrelated = "A quiet afternoon in the garden with the cat."
        #expect(SoundSummaryWriter.validated(unrelated, describing: rainFacts) == nil)
    }

    @Test func aSentenceMentioningTheSoundOrThePlaceIsKept() {
        let withSound = "Rain, eight months ago."
        let withPlace = "An afternoon at Home, eight months ago."
        #expect(SoundSummaryWriter.validated(withSound, describing: rainFacts) == withSound)
        #expect(SoundSummaryWriter.validated(withPlace, describing: facts(sounds: [])) == withPlace)
    }

    @Test func thePromptCarriesOnlyFactsWeAlreadyDisplay() {
        let prompt = SoundSummaryWriter.prompt(for: facts(note: "the storm broke"))
        #expect(prompt.contains("rain"))
        #expect(prompt.contains("the storm broke"))
        #expect(prompt.contains("Home"))
        #expect(prompt.contains("8 months ago"))
        // No audio, no identifiers, no hidden fields.
        #expect(!prompt.lowercased().contains("audio"))
        #expect(!prompt.contains("soundprint"))
    }

    /// The model is never asked how the moment felt — inferring emotion from a
    /// recording is out of scope for this milestone, and a mood is the user's own.
    @Test func itNeverAsksAboutFeelings() {
        let prompt = SoundSummaryWriter.prompt(for: facts())
        for word in ["mood", "feel", "emotion", "happy", "sad"] {
            #expect(!prompt.lowercased().contains(word), "the prompt mentions \(word)")
        }
    }
}

// MARK: - Per-label confidence floors (measured, M15 §11C)

/// A single global floor assumes every label is equally confusable. Measured
/// against the real classifier, `waterfall` is not: quiet broadband room tone
/// returns it at 0.30–0.38, over the 0.30 floor.
struct ElevatedConfidenceFloorTests {

    @Test func waterfallNeedsMoreThanTheDefaultFloor() {
        let floor = SoundVocabulary.confidenceFloor(for: "waterfall",
                                                    default: SoundprintService.confidenceFloor)
        #expect(floor > SoundprintService.confidenceFloor)
        // Above every false positive measured (max 0.38).
        #expect(floor > 0.38)
    }

    @Test func ordinaryLabelsKeepTheDefaultFloor() {
        for identifier in ["rain", "music", "singing"] {
            #expect(SoundVocabulary.confidenceFloor(for: identifier,
                                                    default: SoundprintService.confidenceFloor)
                    == SoundprintService.confidenceFloor)
        }
    }

    /// An elevated floor may only ever raise the bar, never lower it — otherwise a
    /// stale table entry could quietly admit weaker guesses than the default.
    @Test func anElevatedFloorCanOnlyRaiseTheBar() {
        for (identifier, _) in SoundVocabulary.elevatedConfidenceFloors {
            #expect(SoundVocabulary.confidenceFloor(for: identifier, default: 0.99) == 0.99)
        }
    }

    @Test func everyElevatedLabelIsActuallyInTheAllowList() {
        for (identifier, _) in SoundVocabulary.elevatedConfidenceFloors {
            #expect(SoundVocabulary.isAllowed(identifier),
                    "\(identifier) has a raised floor but is not a label we ever show")
        }
    }

    /// The gate itself: a `waterfall` guess in the measured false-positive range must
    /// not be stored, while the same confidence for an ordinary label is fine.
    @Test func aWeakWaterfallGuessIsDroppedButAnEqualRainGuessIsKept() async {
        let weak = 0.35
        let waterfallStub = StubClassifier(identifier: "version1",
                                           labels: [Soundprint.Label(identifier: "waterfall", confidence: weak)])
        let rainStub = StubClassifier(identifier: "version1",
                                      labels: [Soundprint.Label(identifier: "rain", confidence: weak)])

        let waterfall = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 5, peak: 0.5,
            classifier: waterfallStub, isEnabled: true)
        let rain = await SoundprintService.soundprint(
            forClipAt: URL(fileURLWithPath: "/dev/null"), duration: 5, peak: 0.5,
            classifier: rainStub, isEnabled: true)

        guard case .analysed(let w) = waterfall, case .analysed(let r) = rain else {
            Issue.record("both clips should have been analysed"); return
        }
        #expect(w.identifiers.isEmpty, "a 0.35 waterfall is inside the measured false-positive band")
        #expect(r.identifiers == ["rain"], "an ordinary label at the same confidence is unaffected")
    }
}

// MARK: - Gate provenance and reopening superseded verdicts (M15 §11E)

/// An empty soundprint is a *verdict*, and a verdict is only as good as the gates
/// behind it. Recording which generation of gates produced one is what lets a
/// capsule written off under bad thresholds be reconsidered under better ones.
@Suite(.serialized)
@MainActor
struct SoundprintGateVersionTests {

    // MARK: Encoding

    @Test func theStoredFormCarriesTheGateGeneration() throws {
        let print = Soundprint(classifier: "version1", gate: 7,
                               labels: [Soundprint.Label(identifier: "rain", confidence: 0.82)])
        #expect(print.stored == "1/version1/7|rain=0.82")
        let parsed = try #require(Soundprint(stored: print.stored))
        #expect(parsed.gate == 7)
        #expect(parsed.classifier == "version1")
        #expect(parsed.identifiers == ["rain"])
    }

    /// 1.6.0 shipped `1/version1|…` with no gate component. Those must keep parsing
    /// exactly as before: rejecting them would strand every capsule it analysed,
    /// because the backfill only ever looks at `soundprintRaw == nil` and would
    /// never see them again.
    @Test func valuesWrittenBeforeGateVersioningStillParseAsGateOne() throws {
        let legacy = try #require(Soundprint(stored: "1/version1|rain=0.82;wind=0.41"))
        #expect(legacy.gate == 1)
        #expect(legacy.classifier == "version1")
        #expect(legacy.identifiers == ["rain", "wind"])

        let legacyEmpty = try #require(Soundprint(stored: "1/version1|"))
        #expect(legacyEmpty.gate == 1)
        #expect(legacyEmpty.isEmpty)
    }

    @Test func aNonsenseGateComponentDegradesToNeverAnalysed() {
        for junk in ["1/version1/x|rain=0.8", "1/version1/0|rain=0.8", "1/version1/-1|", "1/version1/2/3|"] {
            #expect(Soundprint(stored: junk) == nil, "\(junk.debugDescription) should not parse")
        }
    }

    @Test func newWritesCarryTheCurrentGate() {
        #expect(Soundprint(classifier: "version1").gate == Soundprint.gateVersion)
        #expect(Soundprint.emptyMarker(classifier: "version1")
                == "1/version1/\(Soundprint.gateVersion)|")
    }

    // MARK: Which markers are superseded

    /// The prefix must be the one 1.6.0 actually wrote. A first draft built markers
    /// by always emitting the gate component, so it looked for `1/version1/1|` — a
    /// string no build has ever produced — and the pass would have run, reported
    /// success, and touched nothing.
    @Test func theLegacyPrefixIsWhatShippedNotWhatIsWrittenNow() {
        #expect(SoundprintRemediation.legacyPrefix() == "1/version1|")
        #expect("1/version1|".hasPrefix(SoundprintRemediation.legacyPrefix()))
        #expect("1/version1|rain=0.91".hasPrefix(SoundprintRemediation.legacyPrefix()))
        // A current-generation value must NOT look superseded.
        let current = Soundprint(classifier: "version1").stored
        #expect(!current.hasPrefix(SoundprintRemediation.legacyPrefix()))
    }

    // MARK: Reopening

    private func seed(_ store: CapsuleStore, _ raw: String?) -> Capsule {
        let capsule = store.create()
        capsule.soundprintRaw = raw
        return capsule
    }

    /// Empty verdicts come back for re-analysis; labels that still stand are
    /// re-stamped with the current gate so they leave the candidate set.
    @Test func itReopensOnlyTheVerdictsAStaleGateWroteOff() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            let stale = seed(store, "1/version1|")                                   // 1.6.0's "nothing to say"
            let current = seed(store, Soundprint.emptyMarker(classifier: "version1")) // this gate said so
            let labelled = seed(store, "1/version1|rain=0.82")                        // evidence, not a judgement
            let never = seed(store, nil)
            try store.save()

            let result = SoundprintRemediation.rejudgeBatch(in: store.context)

            #expect(result.reopened == 1)
            #expect(result.touched == 2, "the stale empty AND the re-stamped label both count as progress")
            #expect(stale.soundprintRaw == nil, "a stale empty verdict is handed back to the backfill")
            #expect(current.soundprintRaw != nil, "this generation's own verdict stands")
            #expect(labelled.soundprintRaw == "1/version1/\(Soundprint.gateVersion)|rain=0.82",
                    "a label that still clears the gates is re-stamped, not re-analysed")
            #expect(never.soundprintRaw == nil)
        }
    }

    /// Reopening is a prelude to analysing again, so it has to respect the switch
    /// that says not to.
    @Test func itDoesNothingWithoutListeningConsent() throws {
        try TestSupport.withIsolatedListeningPreference(false) {
            let store = try TestSupport.isolatedStore()
            let stale = seed(store, "1/version1|")
            try store.save()

            #expect(SoundprintRemediation.rejudgeBatch(in: store.context) == (0, 0))
            #expect(SoundprintRemediation.drain(in: store.context) == 0)
            #expect(stale.soundprintRaw == "1/version1|")
        }
    }

    @Test func aBatchIsBoundedAndConverges() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            for _ in 0..<5 { _ = seed(store, "1/version1|") }
            try store.save()

            #expect(SoundprintRemediation.rejudgeBatch(in: store.context, limit: 2).reopened == 2)
            #expect(SoundprintRemediation.rejudgeBatch(in: store.context, limit: 2).reopened == 2)
            #expect(SoundprintRemediation.rejudgeBatch(in: store.context, limit: 2).reopened == 1)
            // Converged: nothing left, so repeated launches stop costing.
            #expect(SoundprintRemediation.rejudgeBatch(in: store.context, limit: 2) == (0, 0))
        }
    }

    /// The whole point of §11H: one launch settles the library, not fifteen.
    @Test func drainingFinishesTheLibraryInOnePass() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            for _ in 0..<5 { _ = seed(store, "1/version1|") }
            try store.save()

            #expect(SoundprintRemediation.drain(in: store.context, batchSize: 2) == 5)
            #expect(SoundprintRemediation.drain(in: store.context, batchSize: 2) == 0)
        }
    }

    /// Re-stamps must count as progress, or a library whose gate-1 labels all still
    /// stand would spin: every batch touches capsules, none of them reopens one, and
    /// a loop keyed on reopenings alone would never decide it was finished.
    @Test func drainingTerminatesWhenEveryLabelStillStands() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            for _ in 0..<5 { _ = seed(store, "1/version1|rain=0.91") }
            try store.save()

            #expect(SoundprintRemediation.drain(in: store.context, batchSize: 2) == 0,
                    "nothing needed re-analysis")
            let stamped = try store.context.fetch(FetchDescriptor<Capsule>())
                .compactMap { $0.soundprintRaw }
                .filter { $0.hasPrefix("1/version1/\(Soundprint.gateVersion)|") }
            #expect(stamped.count == 5, "but every one was re-stamped and left the candidate set")
        }
    }
}

// MARK: - Guards added after external review (2026-08-09)

/// Findings from a Codex/Gemini review pass, each pinned so the fix cannot rot.
struct PostReviewGuardTests {

    /// A Japanese or Chinese model wraps prose in corner brackets, not quotes. With
    /// 「 left on the front, the refusal check never fired — so the trilingual
    /// blocklist was reachable only for output that happened to be unwrapped.
    @Test func aRefusalWrappedInCornerBracketsIsStillRejected() {
        let facts = SoundSummaryWriter.Facts(soundPhrases: ["rain"], note: nil,
                                             placeName: nil, elapsedPhrase: "eight months ago")
        for raw in ["「申し訳ありませんが、お手伝いできません。」",
                    "『すみません、それはできません。』",
                    "「抱歉，我无法完成这个请求。」"] {
            #expect(SoundSummaryWriter.validated(raw, describing: facts) == nil, "\(raw) should be rejected")
        }
    }

    /// `Locale.Language(identifier: "zh-TW").script` is nil — the script is implied
    /// by the region. Comparing declared scripts alone served Simplified prose to a
    /// Traditional Chinese reader.
    @Test func traditionalChineseIsNotMatchedByASimplifiedOnlyModel() {
        let simplifiedOnly: Set<Locale.Language> = [Locale.Language(identifier: "zh-Hans-CN")]
        #expect(!SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "zh-TW"),
                                                        in: simplifiedOnly))
        #expect(SoundSummaryWriter.isLanguageSupported(Locale.Language(identifier: "zh-CN"),
                                                       in: simplifiedOnly))
    }

    /// A join after Japanese punctuation must not take an ASCII space: "朝の音、雨",
    /// never "朝の音、 雨".
    @Test func cjkPunctuationCountsAsCJKForJoining() {
        #expect(!CaptureView.needsSpaceBetween("朝の音、", "雨"))
        #expect(!CaptureView.needsSpaceBetween("下雨了，", "雨声"))
        #expect(!CaptureView.needsSpaceBetween("音。", "雨"))
        #expect(CaptureView.needsSpaceBetween("morning,", "rain"))
    }

    /// The invariant the parser exists to hold, restated after a review argued for
    /// loosening it: corruption degrades to "never analysed", never to wrong labels.
    @Test func corruptProvenanceNeverBecomesRealLabels() {
        for junk in ["1/version1/x|rain=0.8", "1/version1/2/3|rain=0.8", "1/version1/0|rain=0.8"] {
            #expect(Soundprint(stored: junk) == nil,
                    "\(junk) must not parse into labels — it would be wrong data, not missing data")
        }
    }
}

// MARK: - Codex review findings (2026-08-09)

/// Each of these pins a defect an external review found. Several are cases where my
/// own reasoning was self-contradictory, so they are worth keeping executable.
@Suite(.serialized)
@MainActor
struct CodexReviewGuardTests {

    private func facts(sounds: [String] = ["rain"], note: String? = nil,
                       place: String? = nil) -> SoundSummaryWriter.Facts {
        SoundSummaryWriter.Facts(soundPhrases: sounds, note: note, placeName: place,
                                 elapsedPhrase: "eight months ago")
    }

    // MARK: The rain/train bug, reintroduced in a new place

    /// This project already fixed exactly this for search: the phrase for `train`
    /// contains `rain`. The fact-anchor check brought it back with
    /// `localizedStandardContains`, so a sentence about a train satisfied an anchor
    /// of rain and would have been shown as a description of a rainy morning.
    @Test func anAnchorMustNotMatchInsideALongerWord() {
        #expect(!SoundSummaryWriter.mentionsAGivenFact(facts(sounds: ["rain"]),
                                                       in: "A train passed through the evening."))
        #expect(SoundSummaryWriter.mentionsAGivenFact(facts(sounds: ["rain"]),
                                                      in: "Rain on the window, eight months ago."))
    }

    /// The boundary rule cannot apply to scripts without spaces — it would degrade to
    /// "must start the sentence" and switch the feature off for ja/zh.
    @Test func cjkAnchorsMatchAnywhereInTheSentence() {
        #expect(SoundSummaryWriter.mentionsAGivenFact(facts(sounds: ["雨"]),
                                                      in: "今朝は雨でした。"))
        #expect(!SoundSummaryWriter.mentionsAGivenFact(facts(sounds: ["雨"]),
                                                       in: "静かな朝でした。"))
    }

    // MARK: Note-only capsules must still be grounded

    /// The first version returned `true` when there were no sound or place anchors,
    /// which meant a note-only capsule had no factual check at all — and a test
    /// locked that in.
    @Test func aNoteOnlyCapsuleStillRequiresGrounding() {
        let noteOnly = facts(sounds: [], note: "the storm broke")
        #expect(!SoundSummaryWriter.mentionsAGivenFact(noteOnly, in: "You watched fireworks together."))
        #expect(SoundSummaryWriter.mentionsAGivenFact(noteOnly, in: "The storm you wrote about, eight months ago."))
    }

    // MARK: The response's own language

    /// The gate proves the model *can* speak the language and the brief *asks* it to.
    /// Neither checks what came back, and the place anchor is satisfied by a CJK
    /// place name sitting inside English prose.
    @Test func englishProseIsRejectedWhenTheFactsAreJapanese() {
        let japanese = facts(sounds: ["雨"], note: "朝の音", place: "東京")
        #expect(!SoundSummaryWriter.looksLikeTheSameScript(as: japanese,
                                                           text: "A rainy afternoon in 東京."))
        #expect(SoundSummaryWriter.looksLikeTheSameScript(as: japanese,
                                                          text: "東京の雨の朝、八か月前。"))
        // English facts are unaffected — the check only fires when the facts are CJK.
        #expect(SoundSummaryWriter.looksLikeTheSameScript(as: facts(sounds: ["rain"]),
                                                          text: "A rainy afternoon."))
    }

    // MARK: Re-judging labelled results, not only empty ones

    /// The floor exists *because* measured `waterfall` labels at 0.30–0.38 were wrong
    /// about quiet rooms. A capsule carrying one from gate 1 must not keep saying
    /// "a waterfall" forever.
    @Test func aLabelTheCurrentFloorWouldRejectIsReopened() {
        let (outcome, stored) = SoundprintRemediation.rejudge("1/version1|waterfall=0.35")
        #expect(outcome == .reopened)
        #expect(stored == nil)
    }

    /// One that still stands is re-stamped rather than re-analysed — vetted without
    /// re-reading the audio, and it leaves the candidate set so passes converge.
    @Test func aLabelThatStillStandsIsRestampedNotReanalysed() throws {
        let (outcome, stored) = SoundprintRemediation.rejudge("1/version1|rain=0.91")
        #expect(outcome == .revalidated)
        let reparsed = try #require(Soundprint(stored: try #require(stored)))
        #expect(reparsed.gate == Soundprint.gateVersion)
        #expect(reparsed.identifiers == ["rain"])
    }

    /// A mixed result keeps what survives rather than throwing the capsule away.
    @Test func aMixedResultKeepsOnlyWhatStillClearsTheGates() throws {
        let (outcome, stored) = SoundprintRemediation.rejudge("1/version1|rain=0.91;waterfall=0.35")
        #expect(outcome == .revalidated)
        let reparsed = try #require(Soundprint(stored: try #require(stored)))
        #expect(reparsed.identifiers == ["rain"], "the false waterfall is dropped, the real rain kept")
    }

    @Test func anEmptyVerdictFromAnOlderGateIsAlwaysReopened() {
        #expect(SoundprintRemediation.rejudge("1/version1|").outcome == .reopened)
    }

    @Test func aCurrentGenerationValueIsLeftAlone() {
        let current = Soundprint(classifier: "version1",
                                 labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)]).stored
        let (outcome, stored) = SoundprintRemediation.rejudge(current)
        #expect(outcome == .revalidated)
        #expect(stored == current)
    }
}

// MARK: - The vocabulary expansion (M15 §11M)

/// The 22 labels added in §11M, and the principles that decided them. Each of these
/// is a claim about what Soundpost is willing to say, so each gets an assertion
/// rather than living only in a commit message.
struct VocabularyExpansionTests {

    @Test func theAddedLabelsAreAllNamedAndTranslatable() {
        let added = ["thunder", "wind_chime", "pigeon_dove_coo", "duck_quack", "rooster_crow",
                     "cow_moo", "sheep_bleat", "horse_clip_clop", "cello", "flute", "saxophone",
                     "trumpet", "harmonica", "accordion", "harp", "ukulele", "orchestra",
                     "choir_singing", "bicycle_bell", "train_whistle", "sewing_machine", "typewriter"]
        for identifier in added {
            #expect(SoundVocabulary.isAllowed(identifier), "\(identifier) should be named")
            let phrase = SoundVocabulary.displayName(for: identifier)
            #expect(phrase?.isEmpty == false, "\(identifier) has no localized phrase")
        }
    }

    /// The absence of sound is not a sound. "Your memory was silence" is the plainest
    /// possible version of telling someone their memory was something it wasn't, and
    /// the gates already say *stay quiet* rather than name the nothing — so this is a
    /// refusal, not merely an omission. Left unset it could be added back by someone
    /// reading the list as "sounds we have not got to yet".
    @Test func theAbsenceOfSoundIsRefusedNotMerelyUnnamed() {
        #expect(SoundVocabulary.denied.contains("silence"))
        #expect(!SoundVocabulary.isAllowed("silence"))
    }

    /// Microphone buffeting describes our equipment, not the room someone recorded.
    @Test func aRecordingArtefactIsNotAMemory() {
        #expect(SoundVocabulary.denied.contains("wind_noise_microphone"))
    }

    /// The distress rule is about the animals in someone's life too — a dog whimpering
    /// is the same kind of caption as a person crying.
    @Test func animalDistressIsRefusedOnTheSameTermsAsHumanDistress() {
        for identifier in ["dog_growl", "dog_whimper", "dog_howl", "coyote_howl", "lion_roar"] {
            #expect(SoundVocabulary.denied.contains(identifier), "\(identifier) should be refused")
            #expect(!SoundVocabulary.isAllowed(identifier))
        }
    }

    /// `snicker` describes a *judgement about people* rather than a sound.
    @Test func judgementsAboutPeopleAreRefused() {
        #expect(SoundVocabulary.denied.contains("snicker"))
    }

    /// `door_slam` was refused in §11M and is named again (§11O): the refusal rested
    /// on "far likelier to be an argument than a keepsake", which is a conclusion
    /// about the person in the room — the thing §1.2 forbids. Named neutrally.
    @Test func aSoundIsNotRefusedForWhatWeImagineCausedIt() {
        #expect(SoundVocabulary.isAllowed("door_slam"))
        #expect(!SoundVocabulary.denied.contains("door_slam"))
    }

    /// Taxonomy parents stay out: `bird`, `dog`, `cat`, `water`, `fire`, `engine` are
    /// umbrella nodes over labels already named more precisely, and naming both would
    /// put two phrases on one capsule for the same sound.
    @Test func umbrellaCategoriesAreNotNamedAlongsideTheirChildren() {
        for parent in ["bird", "dog", "cat", "water", "fire", "engine", "drum", "truck"] {
            #expect(!SoundVocabulary.isAllowed(parent),
                    "\(parent) is a parent category — its specific children are what get named")
        }
    }

    /// Sports labels name an activity *inferred from* sound rather than the sound
    /// itself, which is the §1.2 line: describe the room, do not conclude about the
    /// person in it.
    @Test func activitiesInferredFromSoundAreNotNamed() {
        for activity in ["playing_tennis", "playing_hockey", "playing_squash",
                         "playing_volleyball", "playing_badminton", "playing_table_tennis"] {
            #expect(!SoundVocabulary.isAllowed(activity))
        }
    }
}

// MARK: - Measured, not assumed (M15 §11N)

/// The batch §11M held back for being "acoustically fragile", then measured: 80 quiet
/// rooms (low-passed tone and broadband hiss, rms 0.003–0.020) against the real
/// classifier. **Zero of the 42 fired.** `waterfall`, carried as a control, fired
/// 8/80 at a peak of 0.38 — reproducing its earlier measurement and proving the probe
/// could see a false positive when there was one to see.
struct MeasuredVocabularyTests {

    @Test func theMeasuredSafeCandidatesAreNamed() {
        for identifier in ["liquid_dripping", "liquid_trickle_dribble", "mechanical_fan",
                           "hair_dryer", "blender", "microwave_oven", "printer", "door_bell",
                           "drawer_open_close", "keys_jangling", "glass_clink", "coin_dropping",
                           "zipper", "scissors", "crumpling_crinkling", "chopping_wood",
                           "knock", "writing"] {
            #expect(SoundVocabulary.isAllowed(identifier), "\(identifier) measured clean, should be named")
            #expect(SoundVocabulary.displayName(for: identifier)?.isEmpty == false)
        }
    }

    /// `waterfall` remains the only label with a raised floor, because it remains the
    /// only one measured to need it. Adding more by intuition is what §11C forbids.
    @Test func onlyMeasuredLabelsCarryARaisedFloor() {
        #expect(SoundVocabulary.elevatedConfidenceFloors.keys.sorted() == ["waterfall"])
        for identifier in ["liquid_dripping", "mechanical_fan", "knock"] {
            #expect(SoundVocabulary.confidenceFloor(for: identifier,
                                                    default: SoundprintService.confidenceFloor)
                    == SoundprintService.confidenceFloor,
                    "\(identifier) measured clean — it must not carry an invented floor")
        }
    }
}
