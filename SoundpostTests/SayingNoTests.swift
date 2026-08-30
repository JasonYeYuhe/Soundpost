import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M18 §S3 — saying no, and taking it back.
///
/// **This suite claims no UI coverage.** There is no UI-test target in this project,
/// so what is asserted here is the policy the detail screen reads and the store call
/// it makes; that the chips carry a context menu, and how it looks, was checked by
/// hand in the simulator. That split is deliberate rather than a gap being papered
/// over: `SoundprintDisplay` and `CapsuleStore.delete` exist as functions precisely
/// so the decisions are somewhere a test can reach, instead of inside a view body
/// where the reveal's sounds line sat unexamined for two milestones (§4B).
@MainActor
@Suite(.serialized)
struct SayingNoTests {

    private func store() throws -> CapsuleStore { try TestSupport.isolatedStore() }

    @discardableResult
    private func capsule(in store: CapsuleStore,
                         note: String? = nil,
                         labels: [(String, Double)] = [("rain", 0.91),
                                                       ("wind_rustling_leaves", 0.62)]) throws -> Capsule {
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

    private func index(_ store: CapsuleStore) throws -> RejectionIndex {
        try SoundRejectionStore.index(in: store.context)
    }

    private var rainPhrase: String { SoundVocabulary.displayName(for: "rain") ?? "rain" }
    private var windPhrase: String {
        SoundVocabulary.displayName(for: "wind_rustling_leaves") ?? "wind"
    }

    // MARK: The policy the detail screen reads

    /// The whole point, as a pure function: a dismissed label stops being offered,
    /// and the others are untouched.
    @Test func aDismissedLabelStopsBeingShownAndTheOthersRemain() throws {
        let store = try store()
        let capsule = try capsule(in: store)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none,
                                          listening: true) == [rainPhrase, windPhrase])

        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail,
                                          rejecting: try index(store),
                                          listening: true) == [windPhrase])
    }

    /// The card honours it too, though it offers no way to make one — the correction
    /// is made on the detail screen and obeyed everywhere (§4C).
    @Test func theCardHonoursACorrectionItCannotMake() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91)])
        #expect(SoundprintDisplay.sentence(for: capsule, on: .card, rejecting: .none,
                                           listening: true) != nil)

        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.sentence(for: capsule, on: .card,
                                           rejecting: try index(store),
                                           listening: true) == nil,
                "a card whose only label was dismissed says nothing at all")
    }

    /// Taking it back. `rejected: false` is an answer, not an absence, so the label
    /// returns rather than the row merely vanishing.
    @Test func takingItBackShowsTheLabelAgain() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context, now: .now.addingTimeInterval(-60))
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail,
                                          rejecting: try index(store), listening: true).isEmpty)

        try SoundRejectionStore.set(false, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail,
                                          rejecting: try index(store),
                                          listening: true) == [rainPhrase])
    }

    /// A correction on one capsule is about that capsule. The same sound on another
    /// is a different memory and a different guess.
    @Test func aCorrectionOnOneCapsuleDoesNotApplyToAnother() throws {
        let store = try store()
        let mine = try capsule(in: store, labels: [("rain", 0.91)])
        let other = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: mine.id,
                                    in: store.context)
        let index = try index(store)
        #expect(SoundprintDisplay.phrases(for: mine, on: .detail, rejecting: index,
                                          listening: true).isEmpty)
        #expect(SoundprintDisplay.phrases(for: other, on: .detail, rejecting: index,
                                          listening: true) == [rainPhrase])
    }

    // MARK: What the way back is driven by

    /// The affordance appears only when there is something to restore, and it counts
    /// only labels this capsule actually holds — a rejection for a label the
    /// vocabulary no longer names is nothing to offer back.
    @Test func theWayBackAppearsOnlyWhenThisCapsuleHasSomethingDismissed() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91)])
        #expect(SoundprintDisplay.dismissedIdentifiers(for: capsule, rejecting: .none,
                                                       listening: true).isEmpty)

        // A rejection for a label this capsule does not carry offers nothing back.
        try SoundRejectionStore.set(true, identifier: "train", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.dismissedIdentifiers(for: capsule,
                                                       rejecting: try index(store),
                                                       listening: true).isEmpty)

        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.dismissedIdentifiers(for: capsule,
                                                       rejecting: try index(store),
                                                       listening: true) == ["rain"])
    }

    /// A capsule whose *only* label was dismissed has nothing left to show — and is
    /// exactly the capsule whose owner most needs the way back, so the affordance
    /// cannot be nested inside "there are chips to draw".
    @Test func theWayBackSurvivesTheLastLabelBeingDismissed() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        let index = try index(store)
        #expect(SoundprintDisplay.heard(for: capsule, on: .detail, rejecting: index,
                                        listening: true).isEmpty)
        #expect(!SoundprintDisplay.dismissedIdentifiers(for: capsule, rejecting: index,
                                                        listening: true).isEmpty)
    }

    /// With listening off there is nothing to correct and nothing to restore — the
    /// labels are not on screen to be wrong about, and the erase is on its way.
    @Test func nothingIsOfferedBackWithListeningOff() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        #expect(SoundprintDisplay.dismissedIdentifiers(for: capsule,
                                                       rejecting: try index(store),
                                                       listening: false).isEmpty)
    }

    /// A sealed-not-due capsule's sound is as hidden as its words, so it offers
    /// neither a correction nor a restore — either would say it has a sound at all.
    @Test func aSealedNotDueCapsuleOffersNothingEitherWay() throws {
        let store = try store()
        let capsule = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsule.id,
                                    in: store.context)
        capsule.sealUntil = Date.now.addingTimeInterval(86_400)
        try capsule.transition(to: .sealed)
        try store.save()

        let index = try index(store)
        #expect(SoundprintDisplay.heard(for: capsule, on: .detail, rejecting: index,
                                        listening: true).isEmpty)
        #expect(SoundprintDisplay.dismissedIdentifiers(for: capsule, rejecting: index,
                                                       listening: true).isEmpty)
    }

    // MARK: Deletion (§4F)

    /// A rejection carries a `capsuleID`, not a relationship — a required one is
    /// CloudKit-illegal and an optional one would put a field on `CD_Capsule` — so
    /// nothing cascades, and without this the corrections would sit in the user's
    /// iCloud forever.
    @Test func deletingACapsuleTakesItsRejectionsWithIt() throws {
        let store = try store()
        let doomed = try capsule(in: store, labels: [("rain", 0.91)])
        let kept = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: doomed.id,
                                    in: store.context)
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: kept.id,
                                    in: store.context)
        let doomedID = doomed.id

        try store.delete(doomed)
        try store.save()

        let remaining = try store.context.fetch(FetchDescriptor<SoundRejection>())
        #expect(!remaining.contains { $0.capsuleID == doomedID })
        #expect(remaining.contains { $0.capsuleID == kept.id },
                "another capsule's corrections are not this delete's business")
    }

    /// The capsule and its corrections leave in the same save, or neither does. The
    /// removal is staged rather than committed, which is what makes that true.
    @Test func thePruningIsStagedInTheSameTransactionAsTheDelete() throws {
        let store = try store()
        let doomed = try capsule(in: store, labels: [("rain", 0.91)])
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: doomed.id,
                                    in: store.context)
        let doomedID = doomed.id

        try store.delete(doomed)
        // Not saved yet: the delete and the pruning are both pending, together.
        store.context.rollback()
        #expect(try store.context.fetch(FetchDescriptor<SoundRejection>())
            .contains { $0.capsuleID == doomedID },
                "the pruning committed on its own, without the capsule it belongs to")
        #expect(try store.all().contains { $0.id == doomedID })
    }
}
