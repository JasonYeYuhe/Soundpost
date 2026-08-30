import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M18 §4B/§4C / S4 — **every surface that showed the label stops showing it.**
///
/// The plan's first draft claimed one seam and therefore free inheritance. Codex
/// disproved it by reading the code: `SoundprintDisplay` serves the card and the
/// detail screen, while `GalleryFilter` (twice — the facet and free-text search are
/// separate paths), `CapsuleBulkExporter`, `NotificationCopy.Digest.lead` and
/// `CaptureViewModel` all called `Soundprint.showable*` directly, and the draft's own
/// step list named five of them and missed the reveal.
///
/// So the zero-argument display APIs are gone and the compiler produced the
/// inventory. **These tests exist because "it inherits" is a claim, not a fact** —
/// one per surface, each written so that a version of the seam without the filter
/// fails it.
@MainActor
@Suite(.serialized)
struct HonouringRejectionsTests {

    private func store() throws -> CapsuleStore { try TestSupport.isolatedStore() }

    @discardableResult
    private func capsule(in store: CapsuleStore,
                         note: String? = nil,
                         labels: [(String, Double)] = [("rain", 0.91)]) throws -> Capsule {
        let capsule = store.create()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = note
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: labels.map { Soundprint.Label(identifier: $0.0, confidence: $0.1) }
        ).stored
        try store.save()
        return capsule
    }

    private func reject(_ identifier: String, on capsule: Capsule, in store: CapsuleStore) throws {
        try SoundRejectionStore.set(true, identifier: identifier, forCapsule: capsule.id,
                                    in: store.context)
    }

    private func index(_ store: CapsuleStore) throws -> RejectionIndex {
        try SoundRejectionStore.index(in: store.context)
    }

    private var rainPhrase: String { SoundVocabulary.displayName(for: "rain") ?? "rain" }

    // MARK: The card

    @Test func theCardStopsSayingIt() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        #expect(SoundprintDisplay.sentence(for: capsule, on: .card, rejecting: .none,
                                           listening: true) != nil)
        try reject("rain", on: capsule, in: store)
        #expect(SoundprintDisplay.sentence(for: capsule, on: .card,
                                           rejecting: try index(store), listening: true) == nil)
    }

    // MARK: The detail chips

    @Test func theDetailChipsStopOfferingIt() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91), ("wind_rustling_leaves", 0.62)])
        try reject("rain", on: capsule, in: store)
        let chips = SoundprintDisplay.heard(for: capsule, on: .detail,
                                            rejecting: try index(store), listening: true)
        #expect(chips.map(\.identifier) == ["wind_rustling_leaves"])
    }

    // MARK: Free-text search

    /// §5's "never drop S4 after S3": a rejection someone can make that search still
    /// ignores is worse than no rejection at all.
    @Test func searchStopsFindingItByThatPhrase() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        #expect(GalleryFilter.apply([capsule], .init(searchText: rainPhrase),
                                    rejecting: .none, listening: true).count == 1)
        try reject("rain", on: capsule, in: store)
        #expect(GalleryFilter.apply([capsule], .init(searchText: rainPhrase),
                                    rejecting: try index(store), listening: true).isEmpty)
    }

    // MARK: The sound facet — a SEPARATE path through the same file

    /// `soundFacetMatches` and `soundMatches` are two call sites, which is exactly why
    /// the parameter has no default: fixing one and believing the other inherited is
    /// the mistake this milestone is built to make impossible.
    @Test func theSoundFacetStopsMatchingIt() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        #expect(GalleryFilter.apply([capsule], .init(sounds: ["rain"]),
                                    rejecting: .none, listening: true).count == 1)
        try reject("rain", on: capsule, in: store)
        #expect(GalleryFilter.apply([capsule], .init(sounds: ["rain"]),
                                    rejecting: try index(store), listening: true).isEmpty)
    }

    // MARK: The export

    /// The export is the copy of their data someone keeps, so a label they told the
    /// app was wrong must not be written into it — that is the one place the app can
    /// never take an assertion back from.
    @Test func theExportLeavesItOut() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91), ("wind_rustling_leaves", 0.62)])
        try reject("rain", on: capsule, in: store)

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "M18-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try CapsuleBulkExporter.writeBundle(in: store.context, container: store.context.container,
                                            to: folder, listening: true,
                                            rejecting: try index(store))

        let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: data)
        let entry = try #require(manifest.capsules.first { $0.id == capsule.id.uuidString })
        #expect(entry.soundsHeard?.contains(rainPhrase) == false,
                "the dismissed phrase was written into the file they keep")
        #expect(entry.soundsHeard?.isEmpty == false, "and the label they did not dismiss survived")
    }

    // MARK: The lock screen

    /// A body is baked in at schedule time, on the one surface where the reader
    /// cannot ask a follow-up question.
    @Test func theLockScreenLeadStopsUsingIt() throws {
        let soundprint = Soundprint(classifier: "version1",
                                    labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)])
        let before = NotificationCopy.Digest(createdAt: .now, note: nil, placeName: nil,
                                             mood: nil, soundprint: soundprint, rejected: .none)
        #expect(before.lead == .heard(rainPhrase))

        let after = NotificationCopy.Digest(createdAt: .now, note: nil, placeName: nil,
                                            mood: nil, soundprint: soundprint,
                                            rejected: RejectedSounds(["rain"]))
        #expect(after.lead == nil, "the copy falls back to generic rather than to a dismissed phrase")
    }

    /// **A body already on the lock screen is replaced, not left there** (§4C).
    ///
    /// A request's body is rendered and baked at schedule time, and `reconcile` skips
    /// any identifier it has already scheduled — so a correction that only changed
    /// what *future* copy would say would leave the dismissed phrase firing on its
    /// seal date, which can be years away. M16 §S1 folded a fingerprint of the
    /// **rendered** copy into the identifier for exactly this, which is what makes the
    /// detail screen's plain `notifications.sync(...)` after a correction sufficient.
    /// This asserts the join rather than trusting it.
    @Test func aCorrectionChangesTheScheduledRequestsIdentity() {
        let soundprint = Soundprint(classifier: "version1",
                                    labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)])
        let item = PlannedNotification(capsuleID: UUID(),
                                       fireDate: Date(timeIntervalSince1970: 2_000_000_000),
                                       timeZoneID: nil, kind: .seal)
        func identifier(rejected: RejectedSounds) -> String {
            let digest = NotificationCopy.Digest(createdAt: .now, note: nil, placeName: nil,
                                                 mood: nil, soundprint: soundprint,
                                                 rejected: rejected)
            let copy = NotificationCopy.make(for: item, digest: digest, personalized: true)
            return NotificationScheduler.identifier(
                for: item,
                contentFingerprint: NotificationScheduler.contentFingerprint(title: copy.title,
                                                                             body: copy.body))
        }
        #expect(identifier(rejected: .none) != identifier(rejected: RejectedSounds(["rain"])),
                "the pending request would have been left in place with the dismissed phrase in it")
    }

    /// A second label still leads — the correction removes one guess, not the feature.
    @Test func aSecondLabelStillLeadsWhenTheFirstIsDismissed() {
        let soundprint = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.91),
                     Soundprint.Label(identifier: "wind_rustling_leaves", confidence: 0.62)])
        let digest = NotificationCopy.Digest(createdAt: .now, note: nil, placeName: nil,
                                             mood: nil, soundprint: soundprint,
                                             rejected: RejectedSounds(["rain"]))
        #expect(digest.lead == .heard(SoundVocabulary.displayName(for: "wind_rustling_leaves") ?? ""))
    }

    // MARK: The reveal

    /// The reveal reaches the seam through `SoundprintDisplay` rather than calling
    /// `showablePhrases` itself — S0 moved it there while removing the sounds from
    /// the generated prose. It is the surface M17's own inventory missed, so it gets
    /// its own assertion rather than being folded into "the detail screen".
    @Test func theRevealsAttributedLineStopsNamingIt() throws {
        let store = try store()
        let capsule = try capsule(in: store, note: "the storm broke")
        #expect(SoundprintDisplay.sentence(for: capsule, on: .detail, rejecting: .none,
                                           listening: true) != nil)
        try reject("rain", on: capsule, in: store)
        #expect(SoundprintDisplay.sentence(for: capsule, on: .detail,
                                           rejecting: try index(store), listening: true) == nil)
    }

    /// And the generated prose cannot name it either, because after §4D it is never
    /// given a sound at all — the note and the place are the only facts that reach the
    /// model. This is why §4C's "cancel a reveal generation in flight" has nothing
    /// left to be about: the summary carries no classifier guess to go stale.
    @Test func theGeneratedSummaryCannotNameItBecauseItIsNeverGivenOne() throws {
        let store = try store()
        let capsule = try capsule(in: store, note: "the storm broke")
        let prompt = SoundSummaryWriter.prompt(
            for: SoundSummaryWriter.facts(for: capsule, elapsedPhrase: "8 months ago"))
        #expect(!prompt.localizedCaseInsensitiveContains(rainPhrase))
        #expect(!prompt.localizedCaseInsensitiveContains("rain"))
    }

    // MARK: The negatives — what must NOT honour it (§4C)

    /// **The backfill and the remediation decide what the CLASSIFIER heard; a
    /// rejection is what the PERSON said about it.** Filtering storage by rejections
    /// would mean a reopened capsule silently loses the row's subject, re-analysis
    /// would have nothing to be rejected against, and an undo could never restore a
    /// label the store no longer held. All three reviewers agreed on this separation;
    /// it is the same one that keeps `hasNoLabels` and `showablePhrases` apart.
    @Test func theStoredSoundprintIsUntouchedByACorrection() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        let before = capsule.soundprintRaw
        try reject("rain", on: capsule, in: store)
        #expect(capsule.soundprintRaw == before, "a correction is display policy, not storage")
        #expect(Soundprint(stored: capsule.soundprintRaw)?.contains("rain") == true)
        // Which is what makes the undo possible at all: the label is still there to
        // come back.
        try SoundRejectionStore.set(false, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail,
                                          rejecting: try index(store),
                                          listening: true) == [rainPhrase])
    }

    /// The remediation re-judges a stored verdict against today's gates. A rejection
    /// is not a gate, and a re-judged capsule must keep the label its owner dismissed
    /// — otherwise the dismissal would quietly become a deletion.
    @Test func theRemediationDoesNotConsultCorrections() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        capsule.soundprintRaw = "1/version1|rain=0.91"      // a gate-1 verdict
        try store.save()
        try reject("rain", on: capsule, in: store)

        _ = SoundprintRemediation.drain(in: store.context, isEnabled: true)
        #expect(Soundprint(stored: capsule.soundprintRaw)?.contains("rain") == true,
                "re-judging a verdict is about the thresholds, not about what its owner said")
    }

    /// The capture sheet is the one honest `.none`: a rejection is keyed to a capsule
    /// id, and this capsule is inserted on save, so there is nothing to look up — not
    /// a lookup that has been skipped.
    ///
    /// Asserted with a soundprint actually present. A version of this test on an empty
    /// view model would read "nothing in, nothing out", which is true of a correct
    /// implementation and of one that filtered everything away.
    @Test func theCaptureSheetHasNothingToApplyAndStillSuggests() {
        let model = CaptureViewModel()
        #expect(model.suggestedPhrases.isEmpty, "nothing classified yet")

        model.setSoundprintForTesting(Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)]))
        #expect(model.suggestedPhrases == [rainPhrase],
                "an unsaved capsule cannot have corrections, so the suggestion stands")
    }

    // MARK: Consent withdrawal (§4F)

    /// **The one product call in M18 the owner may want to overturn.** The Settings
    /// footer promises, in three languages, that turning listening off erases what it
    /// has already heard "everywhere". A rejection row records that the classifier
    /// proposed a particular label for a particular capsule, so keeping it would make
    /// shipped copy untrue. The cost: an off/on cycle forgets every correction.
    @Test func withdrawingConsentErasesCorrectionsToo() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        try reject("rain", on: capsule, in: store)

        let erased = try SoundprintEraser.eraseAll(in: store.context)
        #expect(erased.soundprints == 1)
        #expect(erased.rejections == 1)
        #expect(try index(store).isEmpty)
        #expect(capsule.soundprintRaw == nil)
    }

    /// A survivor would be worse than useless: the labels come back from the backfill
    /// and a stale correction would hide one of them for a reason nobody can see.
    @Test func nothingCorrectionShapedSurvivesAWithdrawal() throws {
        let store = try store()
        let a = try capsule(in: store)
        let b = try capsule(in: store, labels: [("wind_rustling_leaves", 0.71)])
        try reject("rain", on: a, in: store)
        try SoundRejectionStore.set(false, identifier: "wind_rustling_leaves",
                                    forCapsule: b.id, in: store.context)

        _ = try SoundprintEraser.eraseAll(in: store.context)
        #expect(try store.context.fetch(FetchDescriptor<SoundRejection>()).isEmpty,
                "undos are corrections too — leaving them behind leaves the table half-erased")
    }
}
