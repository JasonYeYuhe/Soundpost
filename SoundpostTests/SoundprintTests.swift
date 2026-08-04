import Testing
import Foundation
import SoundAnalysis
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
        #expect(print.stored == "1/version1|rain=0.82;wind=0.41")

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
        #expect(empty.stored == "1/version1|")
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
    @Test func theVocabularyIsCuratedNotExhaustive() {
        let count = SoundVocabulary.displayNames.count
        #expect(count >= 40 && count <= 60, "\(count) labels — §4D targets a curated 40–60")
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
    /// user has to tap. Nothing in the capture flow writes either from a guess.
    @Test func aSoundprintNeverAppliesItself() async {
        let vm = viewModel()
        #expect(vm.note.isEmpty)
        #expect(vm.mood == nil)
        // Even after a classification lands, the fields the user owns stay untouched.
        #expect(vm.soundprint == nil)
        #expect(vm.note.isEmpty)
        #expect(vm.mood == nil)
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

    @Test func cjkPhrasesMatchFromTheStart() {
        // No word boundaries in ja/zh, so matching is prefix-shaped — documented.
        #expect(GalleryFilter.matches(phrase: "车流声", query: "车流"))
        #expect(GalleryFilter.matches(phrase: "鳥のさえずり", query: "鳥"))
        #expect(!GalleryFilter.matches(phrase: "车流声", query: "流声"))
    }
}

// MARK: - Consent + the resurface moment (M15 §4I / S5)

/// `.serialized` because these mutate one shared `UserDefaults` key: run in
/// parallel, one test's save/restore races another's read.
@Suite(.serialized)
struct SoundConsentTests {

    private func withListening(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let key = SoundAnalysisPreferences.enabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        SoundAnalysisPreferences.isEnabled = enabled
        try body()
    }

    /// Listening is on unless the user says otherwise — and that has to be explicit,
    /// because `bool(forKey:)` returns false for an unset key.
    @Test func listeningDefaultsToOn() {
        let key = SoundAnalysisPreferences.enabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(SoundAnalysisPreferences.isEnabled)
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
/// The suite shares one in-memory container with every other suite, and these tests
/// are `async` — so unlike the synchronous `@MainActor` suites they genuinely
/// interleave, and any assertion about the store *as a whole* is a race.
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
        let store = try TestSupport.freshStore()
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
        let store = try TestSupport.freshStore()
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

    /// A user who turned listening off must not have their back catalogue quietly
    /// analysed instead — consent is checked in the backfill too, not only capture.
    @Test func itRespectsWithdrawnConsent() async throws {
        let clip = try realClip()
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let store = try TestSupport.freshStore()
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
        let store = try TestSupport.freshStore()
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

    // MARK: Output validation — the part that protects the memory

    @Test func itStripsTheQuotesModelsLikeToAdd() {
        #expect(SoundSummaryWriter.validated("\"Rain on the window.\"") == "Rain on the window.")
        #expect(SoundSummaryWriter.validated("“Rain on the window.”") == "Rain on the window.")
    }

    @Test func itRejectsARefusalOrAPreamble() {
        for raw in ["I can't help with that.", "I'm sorry, but I cannot.",
                    "Sure, here's a sentence: rain.", "Here is your sentence.",
                    "As an AI language model, I..."] {
            #expect(SoundSummaryWriter.validated(raw) == nil, "\(raw.debugDescription) should be rejected")
        }
    }

    @Test func itRejectsAnythingThatRanOn() {
        #expect(SoundSummaryWriter.validated(String(repeating: "a", count: 500)) == nil)
        #expect(SoundSummaryWriter.validated("First thought.\n\nSecond thought.") == nil)
        #expect(SoundSummaryWriter.validated("   ") == nil)
        #expect(SoundSummaryWriter.validated("") == nil)
    }

    @Test func itAcceptsTheSentenceWeAskedFor() {
        let good = "A rainy afternoon at home, eight months ago."
        #expect(SoundSummaryWriter.validated(good) == good)
    }

    // MARK: The prompt only ever carries what the app already shows

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
