import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M17 §S1 — the integrity of what Soundpost heard. No UI in any of this.
///
/// Three defects, each of which passes a green suite while being wrong:
/// a value can report it has something when nothing can be shown (§4C); the bulk
/// export reads soundprints with no reference to listening consent (§4D); and the
/// remediation pass is hard-coded to gate 1, so a gate-2 verdict can never be
/// reopened and a gate-3 bump would strand a whole generation silently.

// MARK: - §4C: stored is not the same question as showable

@MainActor
struct ShowableLabelTests {

    private func print(_ pairs: [(String, Double)]) -> Soundprint {
        Soundprint(classifier: "version1",
                   labels: pairs.map { Soundprint.Label(identifier: $0.0, confidence: $0.1) })
    }

    /// The ghost the capture sheet already drew before M17: `isEmpty` counted stored
    /// labels, the chips filtered through `displayName(for:)`, and a value holding
    /// only unnameable labels satisfied the header while rendering nothing under it.
    @Test func aValueHoldingOnlyOutOfVocabularyLabelsHasNothingToShow() {
        let hidden = print([("not_a_real_label", 0.99), ("crying_sobbing", 0.95)])
        #expect(!hidden.hasNoLabels, "the labels really are stored — that is the trap")
        #expect(hidden.showablePhrases().isEmpty, "and not one of them can be rendered")
        // `showableLabels`, separately, because it is the one `SoundprintRemediation`
        // filters on — and unlike `showablePhrases` it does not launder the answer
        // through `displayName(for:)`. Asserting only on the phrases left the
        // vocabulary half of `isShowable` unpinned, which a control mutation found:
        // deleting it kept every test green while letting a denied label be
        // re-stamped into storage.
        #expect(hidden.showableLabels().isEmpty)
    }

    /// `crying_sobbing` is on the deny-list by name, so this is not a typo case: a
    /// label the classifier genuinely returns, deliberately never shown.
    @Test func aDeniedLabelIsNeverShowable() {
        #expect(SoundVocabulary.denied.contains("crying_sobbing"))
        #expect(!Soundprint.isShowable(.init(identifier: "crying_sobbing", confidence: 0.99)))
        #expect(print([("crying_sobbing", 0.99)]).showableLabels().isEmpty)
        #expect(print([("crying_sobbing", 0.99)]).showablePhrases().isEmpty)
    }

    /// The floor case, and the one no render site honoured before M17: `waterfall` is
    /// the single measured elevated floor (0.45), and 0.35 sits inside the band that
    /// fired on quiet room tone.
    @Test func aLabelBelowItsOwnFloorHasNothingToShow() {
        let weak = print([("waterfall", 0.35)])
        #expect(!weak.hasNoLabels)
        #expect(weak.showablePhrases().isEmpty, "a 0.35 waterfall was measured on empty rooms")
        #expect(!print([("waterfall", 0.50)]).showablePhrases().isEmpty, "a confident one still shows")
    }

    @Test func anOrdinaryLabelAtTheSameConfidenceIsUnaffected() {
        #expect(print([("rain", 0.35)]).showablePhrases() == [SoundVocabulary.displayName(for: "rain")])
    }

    /// Showable labels keep confidence order, so "the first phrase" means "the most
    /// confident one Soundpost can name" everywhere it is asked for.
    @Test func showablePhrasesKeepConfidenceOrderWithTheUnshowableRemoved() {
        let mixed = print([("not_a_real_label", 0.99), ("rain", 0.80), ("wind", 0.60)])
        #expect(mixed.showablePhrases() == [
            SoundVocabulary.displayName(for: "rain"),
            SoundVocabulary.displayName(for: "wind"),
        ].compactMap { $0 })
    }

    /// The notification lead used `identifiers.first` and looked *that* up, so an
    /// unshowable top label dropped the copy to generic even when the capsule had a
    /// perfectly good second one.
    @Test func theNotificationLeadFallsToTheNextShowablePhrase() {
        let digest = NotificationCopy.Digest(
            createdAt: .now, note: nil, placeName: nil, mood: nil,
            soundprint: print([("not_a_real_label", 0.99), ("rain", 0.80)])
        )
        #expect(digest.lead == SoundVocabulary.displayName(for: "rain"))
    }

    /// Rule 1's precedence, unchanged and re-pinned here because M17 §S2 reuses it on
    /// a second surface: the user's own words always beat the machine's guess.
    @Test func theUsersOwnWordsStillBeatTheGuess() {
        let digest = NotificationCopy.Digest(
            createdAt: .now, note: "the storm broke", placeName: "Kyoto", mood: nil,
            soundprint: print([("rain", 0.95)])
        )
        #expect(digest.lead == "the storm broke")
    }

    /// The capture sheet's own header, as a value rather than a view expression:
    /// this is the ghost that was already reachable on master, and the one every new
    /// M17 §S2 surface would have inherited.
    @Test func theCaptureSheetOffersNothingWhenNothingIsShowable() async {
        let viewModel = CaptureViewModel()
        viewModel.classify = { _, _, _ in
            Soundprint(classifier: "version1",
                       labels: [Soundprint.Label(identifier: "waterfall", confidence: 0.35)])
        }
        viewModel.finishRecordingForTesting(fileName: "abc.m4a", duration: 7)
        await viewModel.awaitClassificationForTesting()

        #expect(viewModel.soundprint?.hasNoLabels == false, "a label really did land")
        #expect(viewModel.suggestedPhrases.isEmpty, "and the sheet offers no header over no chips")
    }

    @Test func theCaptureSheetOffersEveryShowablePhrase() async {
        let viewModel = CaptureViewModel()
        viewModel.classify = { _, _, _ in
            Soundprint(classifier: "version1", labels: [
                Soundprint.Label(identifier: "rain", confidence: 0.91),
                Soundprint.Label(identifier: "waterfall", confidence: 0.35),
            ])
        }
        viewModel.finishRecordingForTesting(fileName: "abc.m4a", duration: 7)
        await viewModel.awaitClassificationForTesting()

        #expect(viewModel.suggestedPhrases == [SoundVocabulary.displayName(for: "rain")].compactMap { $0 })
    }

    /// Search and display must agree. A capsule found by a label it was never told
    /// about is a result the app cannot explain.
    @Test func searchDoesNotFindACapsuleByALabelBelowItsFloor() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.soundprintRaw = print([("waterfall", 0.35)]).stored

        #expect(GalleryFilter.apply([capsule], .init(searchText: "waterfall"), listening: true).isEmpty)

        capsule.soundprintRaw = print([("waterfall", 0.50)]).stored
        #expect(GalleryFilter.apply([capsule], .init(searchText: "waterfall"), listening: true).count == 1,
                "a confident one is still findable")
    }
}

// MARK: - §4D: consent gates the export too

@Suite(.serialized)
@MainActor
struct BulkExportConsentTests {

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "bulk-consent-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func seedRainyCapsule(_ store: CapsuleStore) throws {
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "f.m4a", audioData: Data([1, 2, 3]),
                               durationSeconds: 6, waveformSamples: [0.3])
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)]
        ).stored
        try store.save()
    }

    private func manifest(from folder: URL) throws -> ExportManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            ExportManifest.self,
            from: Data(contentsOf: folder.appending(path: "manifest.json"))
        )
    }

    /// The window this exists for: the account said stop, and the erase has not landed
    /// on this device yet. An export taken now must not hand back the labels.
    @Test func anExportTakenWithListeningOffCarriesNoSoundprint() throws {
        let store = try TestSupport.freshStore()
        try seedRainyCapsule(store)
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try CapsuleBulkExporter.writeBundle(in: store.context, container: TestSupport.container,
                                            to: folder, listening: false)

        let entry = try #require(try manifest(from: folder).capsules.first)
        #expect(entry.soundsHeard == nil, "not [] — 'we are not telling you' is not 'we heard nothing'")
        #expect(entry.note == nil)
    }

    /// And it is a gate, not a removal: with listening on, the export still hands back
    /// the user's own data in a form they can read.
    @Test func anExportTakenWithListeningOnStillCarriesThePhrases() throws {
        let store = try TestSupport.freshStore()
        try seedRainyCapsule(store)
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try CapsuleBulkExporter.writeBundle(in: store.context, container: TestSupport.container,
                                            to: folder, listening: true)

        let entry = try #require(try manifest(from: folder).capsules.first)
        #expect(entry.soundsHeard == [SoundVocabulary.displayName(for: "rain")].compactMap { $0 })
    }

    /// The export goes through the same showable rule as every screen, so a label the
    /// app would not name is not exported under a name either.
    @Test func theExportOnlyCarriesPhrasesTheAppWouldShow() throws {
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "f.m4a", audioData: Data([1]),
                               durationSeconds: 6, waveformSamples: [0.3])
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "waterfall", confidence: 0.35)]
        ).stored
        try store.save()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try CapsuleBulkExporter.writeBundle(in: store.context, container: TestSupport.container,
                                            to: folder, listening: true)

        let entry = try #require(try manifest(from: folder).capsules.first)
        #expect(entry.soundsHeard == [], "analysed, and nothing it can name — which is not nil")
    }
}

// MARK: - §S1: remediation that can only repair gate 1 is not a repair mechanism

@Suite(.serialized)
@MainActor
struct RemediationGateAwarenessTests {

    private func seed(_ store: CapsuleStore, _ raw: String?) -> Capsule {
        let capsule = store.create()
        capsule.soundprintRaw = raw
        return capsule
    }

    /// Today's set is one prefix and always was. The assertion that matters is the
    /// second: at gate 3 there are two, and gate 2 is one of them.
    @Test func everyOlderGenerationIsSuperseded() {
        #expect(SoundprintRemediation.supersededPrefixes(currentGate: 2) == ["1/version1|"])
        #expect(SoundprintRemediation.supersededPrefixes(currentGate: 3)
                == ["1/version1|", "1/version1/2|"])
        #expect(SoundprintRemediation.supersededPrefixes(currentGate: 1).isEmpty)
    }

    /// The prefixes must not overlap, or a capsule is fetched twice in one batch and
    /// the budget lies about how much work is left.
    @Test func thePrefixesAreMutuallyExclusive() {
        let gateOne = "1/version1|rain=0.82"
        let gateTwo = "1/version1/2|rain=0.82"
        #expect(gateOne.hasPrefix("1/version1|"))
        #expect(!gateOne.hasPrefix("1/version1/2|"))
        #expect(gateTwo.hasPrefix("1/version1/2|"))
        #expect(!gateTwo.hasPrefix("1/version1|"))
    }

    @Test func aGateTwoEmptyVerdictIsReopenedOnceGateThreeArrives() {
        let (outcome, replacement) = SoundprintRemediation.rejudge("1/version1/2|", currentGate: 3)
        #expect(outcome == .reopened)
        #expect(replacement == nil)
    }

    @Test func aGateTwoLabelledValueIsRejudgedRatherThanIgnored() {
        let (outcome, replacement) = SoundprintRemediation.rejudge("1/version1/2|rain=0.82", currentGate: 3)
        #expect(outcome == .revalidated)
        #expect(replacement == "1/version1/3|rain=0.82",
                "re-stamped at the gate it was judged under, so it leaves the candidate set")

        // And a gate-2 label that no longer clears its floor goes back for re-analysis
        // rather than being grandfathered — the whole reason labelled values are
        // re-judged at all.
        let (weakOutcome, weakReplacement) =
            SoundprintRemediation.rejudge("1/version1/2|waterfall=0.35", currentGate: 3)
        #expect(weakOutcome == .reopened)
        #expect(weakReplacement == nil)
    }

    /// The guarantee `rejudge` used to spell out inline and now delegates to
    /// `Soundprint.isShowable`: a superseded value whose only label has left the
    /// vocabulary is **reopened**, never re-stamped carrying that label forward into
    /// the current generation where nothing would ever question it again.
    @Test func aSupersededLabelOutsideTheVocabularyIsNotGrandfatheredIn() {
        let (outcome, replacement) =
            SoundprintRemediation.rejudge("1/version1/2|crying_sobbing=0.99", currentGate: 3)
        #expect(outcome == .reopened)
        #expect(replacement == nil)

        // And it does not survive alongside a good one either.
        let (mixedOutcome, mixedReplacement) =
            SoundprintRemediation.rejudge("1/version1/2|crying_sobbing=0.99;rain=0.82", currentGate: 3)
        #expect(mixedOutcome == .revalidated)
        #expect(mixedReplacement == "1/version1/3|rain=0.82")
    }

    @Test func theCurrentGenerationsOwnVerdictIsLeftAlone() {
        let current = "1/version1/3|rain=0.82"
        #expect(SoundprintRemediation.rejudge(current, currentGate: 3) == (.revalidated, current))
    }

    /// The **join**, which is where the blindness actually lived: selecting and
    /// judging agree only if they are asked about the same generation. A pass that
    /// fetched by `legacyPrefix()` alone would find nothing here and report success.
    @Test func aGateBumpStrandsNoGenerationSilently() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            let gateOne = seed(store, "1/version1|")
            let gateTwoEmpty = seed(store, "1/version1/2|")
            let gateTwoLabelled = seed(store, "1/version1/2|rain=0.82")
            let gateThree = seed(store, "1/version1/3|rain=0.82")
            try store.save()

            let result = SoundprintRemediation.rejudgeBatch(in: store.context, currentGate: 3)

            #expect(result.touched == 3, "both older generations, and only those")
            #expect(result.reopened == 2)
            #expect(gateOne.soundprintRaw == nil)
            #expect(gateTwoEmpty.soundprintRaw == nil, "the generation the old fetch could not see")
            #expect(gateTwoLabelled.soundprintRaw == "1/version1/3|rain=0.82")
            #expect(gateThree.soundprintRaw == "1/version1/3|rain=0.82", "untouched")
        }
    }

    /// Draining across two superseded generations must still converge — the reason
    /// this selects per-generation prefixes instead of "anything that is not current",
    /// which would also match a newer build's values and spin forever.
    @Test func drainingConvergesAcrossTwoSupersededGenerations() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            let store = try TestSupport.isolatedStore()
            for _ in 0..<3 { _ = seed(store, "1/version1|") }
            for _ in 0..<3 { _ = seed(store, "1/version1/2|") }
            _ = seed(store, "1/version1/9|rain=0.82")   // a newer build's value, syncing down
            try store.save()

            #expect(SoundprintRemediation.drain(in: store.context, batchSize: 2, currentGate: 3) == 6)
            #expect(SoundprintRemediation.drain(in: store.context, batchSize: 2, currentGate: 3) == 0,
                    "converged: nothing superseded is left")

            let future = try store.context.fetch(FetchDescriptor<Capsule>())
                .compactMap(\.soundprintRaw)
                .filter { $0.hasPrefix("1/version1/9|") }
            #expect(future.count == 1, "a value from a newer gate is not this pass's business")
        }
    }
}
