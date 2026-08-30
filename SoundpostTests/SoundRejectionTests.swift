import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M18 §4A / S2 — the rejection row, and the resolution that is deliberately **not**
/// a copy of `ListeningConsent`'s.
///
/// The row shape is the same and the logic is not, which is the whole finding all
/// three reviewers arrived at from different angles. `ListeningConsent` answers one
/// global question, so its `winner()` takes the max over the whole table; copying
/// that here would let one rejection anywhere in the library decide the answer for
/// every label on every capsule. Everything is scoped to `(capsuleID, identifier)`,
/// and every test below is written so that a version scoped to the *table* fails it.
@MainActor
@Suite(.serialized)
struct SoundRejectionTests {

    /// A store nobody else shares. These tests write rows and resolve over the whole
    /// table, so a row leaking in from another suite is not noise — it is a different
    /// answer.
    private func store() throws -> ModelContext {
        try TestSupport.isolatedStore().context
    }

    private let capsuleA = UUID()
    private let capsuleB = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }
    /// A `now` comfortably after every dated row below, so nothing is clamped unless
    /// a test means it to be.
    private var now: Date { at(10_000) }

    @discardableResult
    private func row(_ context: ModelContext, _ capsule: UUID, _ identifier: String,
                     _ rejected: Bool, _ when: Date) -> SoundRejection {
        let row = SoundRejection(capsuleID: capsule, identifier: identifier,
                                 rejected: rejected, changedAt: when)
        context.insert(row)
        return row
    }

    private func index(_ context: ModelContext) throws -> RejectionIndex {
        try SoundRejectionStore.index(in: context, now: now)
    }

    // MARK: Per-key resolution — the finding that changed the design

    /// The load-bearing one. A newer answer supersedes an older one **for the same
    /// key**, and a table-wide winner would make the newest row anywhere decide for
    /// everything.
    @Test func aNewerAnswerSupersedesAnOlderOneForTheSameKeyAndOnlyThatKey() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        row(context, capsuleA, "rain", false, at(200))     // undo, newer — wins
        row(context, capsuleA, "wind", true, at(50))       // older, different label
        row(context, capsuleB, "rain", true, at(10))       // older, different capsule
        try context.save()

        let index = try index(context)
        #expect(!index.isRejected("rain", for: capsuleA), "the newer undo wins for this key")
        #expect(index.isRejected("wind", for: capsuleA),
                "a newer answer about rain says nothing about wind")
        #expect(index.isRejected("rain", for: capsuleB),
                "and nothing about the same label on a different capsule")
    }

    /// The same fact from the other side: an older answer never overturns a newer one.
    @Test func anOlderAnswerDoesNotOverturnANewerOne() throws {
        let context = try store()
        row(context, capsuleA, "rain", false, at(500))
        row(context, capsuleA, "rain", true, at(100))
        try context.save()
        #expect(!(try index(context)).isRejected("rain", for: capsuleA))
    }

    /// A mis-tap has to be recoverable, so `rejected == false` is a real answer rather
    /// than an absence — and it has to be able to win.
    @Test func anUndoWins() throws {
        let context = try store()
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsuleA,
                                    in: context, now: at(100))
        #expect((try index(context)).isRejected("rain", for: capsuleA))

        try SoundRejectionStore.set(false, identifier: "rain", forCapsule: capsuleA,
                                    in: context, now: at(200))
        #expect(!(try index(context)).isRejected("rain", for: capsuleA))
    }

    // MARK: Clocks

    /// A device whose clock runs fast writes an answer dated into the future, and
    /// every correctly dated answer after it would lose.
    ///
    /// The scenario has to be the one where clamping actually decides something, or
    /// the test passes either way: device A's clock is five minutes fast and it
    /// records "show it"; at true 12:02 the person rejects the label on device B.
    /// Unclamped, A is simply newer and wins. Clamped, the two tie — and the
    /// tie-break takes the answer that says stop.
    @Test func aFutureDatedRowIsClampedRatherThanObeyed() throws {
        let context = try store()
        let trueNow = at(1_000)
        row(context, capsuleA, "rain", false, at(1_300))   // fast clock, dated ahead
        row(context, capsuleA, "rain", true, trueNow)      // honest, made now
        try context.save()

        #expect(try SoundRejectionStore.index(in: context, now: trueNow)
            .isRejected("rain", for: capsuleA))
        #expect(SoundRejectionStore.effectiveDate(at(1_300), now: trueNow) == trueNow)
        #expect(SoundRejectionStore.effectiveDate(at(900), now: trueNow) == at(900))
    }

    /// When two answers cannot be ordered, take the one that says stop. Here "stop"
    /// means "do not show it" — the same rule the consent tie-break has, pointed at
    /// the thing this table decides.
    @Test func anUnorderableTieResolvesToRejected() throws {
        let context = try store()
        row(context, capsuleA, "rain", false, at(100))
        row(context, capsuleA, "rain", true, at(100))      // identical timestamp
        try context.save()
        #expect((try index(context)).isRejected("rain", for: capsuleA))
    }

    /// Clamping only at read time is momentary: once the local clock passes the
    /// future date, the answer that lost while clamped wins by itself and the label
    /// the person dismissed comes back on its own. Settlement makes the early answer
    /// permanent instead of inventing a new ordering.
    @Test func aDisagreeingFutureDatedKeyIsSettledToARejection() throws {
        let context = try store()
        row(context, capsuleA, "rain", false, at(20_000))  // fast clock, says show it
        row(context, capsuleA, "rain", true, at(9_000))    // honest, says hide it
        row(context, capsuleA, "wind", false, at(50))      // untouched: no future row
        try context.save()

        #expect(try SoundRejectionStore.settleFutureDatedAnswers(in: context, now: now) == 1)

        let rows = try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context)
        #expect(rows.count == 1, "the unorderable pair is replaced, not added to")
        #expect(rows.first?.rejected == true)
        #expect(rows.first?.changedAt == now)
        // And the clock catching up cannot undo it — there is nothing left dated ahead.
        #expect(try SoundRejectionStore.index(in: context, now: at(30_000))
                .isRejected("rain", for: capsuleA))
        // A different label's history is untouched. Consent settles the whole table;
        // this must not.
        #expect(try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "wind"), in: context).count == 1)
    }

    /// Answers that agree have nothing to arbitrate — the date is simply brought back
    /// to the present so it cannot sit in the future indefinitely.
    ///
    /// The rows say **not** rejected on purpose: settlement's disagreement branch
    /// writes a rejection, so a version that took that branch for every future-dated
    /// key would satisfy a test built out of `rejected: true` rows without ever
    /// keeping a value.
    @Test func anUncontestedFutureAnswerKeepsItsValueAndLosesItsFutureDate() throws {
        let context = try store()
        row(context, capsuleA, "rain", false, at(20_000))
        row(context, capsuleA, "rain", false, at(100))
        try context.save()

        #expect(try SoundRejectionStore.settleFutureDatedAnswers(in: context, now: now) == 1)
        let rows = try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context)
        #expect(rows.allSatisfy { !$0.rejected }, "an uncontested answer keeps its value")
        #expect(rows.allSatisfy { $0.changedAt <= now }, "and loses its future date")
        #expect(!(try index(context)).isRejected("rain", for: capsuleA))
    }

    @Test func honestlyDatedAnswersAreNotTouched() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        row(context, capsuleB, "wind", false, at(200))
        try context.save()
        #expect(try SoundRejectionStore.settleFutureDatedAnswers(in: context, now: now) == 0)
    }

    // MARK: Writing

    /// Nothing is ever edited in place: once a row has synced, two devices editing it
    /// are editing the same CKRecord and CloudKit resolves that with its own
    /// last-writer-wins before `winner` ever runs.
    @Test func anAnswerNeverEditsAnExistingRow() throws {
        let context = try store()
        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsuleA,
                                    in: context, now: at(100))
        let first = try #require(try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context).first)
        let firstID = first.id

        try SoundRejectionStore.set(false, identifier: "rain", forCapsule: capsuleA,
                                    in: context, now: at(200))
        let rows = try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context)
        #expect(rows.count == 1, "the superseded row is removed, not updated")
        #expect(rows.first?.id != firstID, "and the survivor is the new row, not the edited old one")
        #expect(rows.first?.rejected == false)
    }

    /// Compaction, and the reason it has to be per key: toggling one chip must not
    /// grow the table without bound, and must not touch another label's history.
    @Test func rowsDoNotAccumulateUnderRapidToggling() throws {
        let context = try store()
        row(context, capsuleA, "wind", true, at(10))
        try context.save()

        for step in 1...20 {
            try SoundRejectionStore.set(step.isMultiple(of: 2), identifier: "rain",
                                        forCapsule: capsuleA, in: context, now: at(Double(step) * 10))
        }
        let rain = try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context)
        #expect(rain.count == 1, "twenty toggles left \(rain.count) rows")
        #expect(rain.first?.rejected == true, "step 20 was an even step, so: rejected")
        // The other label kept its own history, untouched by twenty writes next to it.
        #expect(try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "wind"), in: context).count == 1)
    }

    /// A newer answer from another device is a *newer* row, and compaction never
    /// touches one — otherwise a slow local write would delete an answer made after it.
    @Test func compactionNeverRemovesAnAnswerNewerThanTheOneBeingWritten() throws {
        let context = try store()
        row(context, capsuleA, "rain", false, at(5_000))   // arrived from elsewhere, newer
        try context.save()

        try SoundRejectionStore.set(true, identifier: "rain", forCapsule: capsuleA,
                                    in: context, now: at(1_000))
        let rows = try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context)
        #expect(rows.count == 2)
        #expect(!(try index(context)).isRejected("rain", for: capsuleA),
                "the newer answer still wins")
    }

    // MARK: The failure path `ListeningConsent` gets wrong

    /// `ListeningConsentStore.set` deletes superseded rows and inserts the answer in
    /// one save, and on failure removes only the *new* row — leaving pending deletes
    /// on a shared context for the next unrelated save to commit. Here the answer is
    /// stored first and nothing is removed until it is durable, so a failed write
    /// leaves the table exactly as it was.
    @Test func aFailedSaveLeavesTheTableExactlyAsItWas() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        try context.save()
        let before = try context.fetch(FetchDescriptor<SoundRejection>())
            .map { "\($0.id)|\($0.identifier)|\($0.rejected)|\($0.changedAt)" }.sorted()

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try SoundRejectionStore.set(false, identifier: "rain", forCapsule: capsuleA,
                                        in: context, now: at(200),
                                        save: { _ in throw Boom() })
        }

        let after = try context.fetch(FetchDescriptor<SoundRejection>())
            .map { "\($0.id)|\($0.identifier)|\($0.rejected)|\($0.changedAt)" }.sorted()
        #expect(after == before, "the failed answer was left behind in the table")
        // And nothing is left pending for a later, unrelated save to commit.
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SoundRejection>())
                .map { "\($0.id)|\($0.identifier)|\($0.rejected)|\($0.changedAt)" }.sorted() == before)
        #expect((try index(context)).isRejected("rain", for: capsuleA),
                "the answer that WAS stored still stands")
    }

    /// A compaction that fails cannot lose an answer — it runs after the answer is
    /// durable — and it must not leave its deletes pending either.
    @Test func aFailedCompactionKeepsTheAnswerAndRestoresWhatItTriedToRemove() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        try context.save()

        struct Boom: Error {}
        var saves = 0
        // The first save (the answer) succeeds; the second (the compaction) throws.
        try SoundRejectionStore.set(false, identifier: "rain", forCapsule: capsuleA,
                                    in: context, now: at(200),
                                    save: { context in
                                        saves += 1
                                        if saves > 1 { throw Boom() }
                                        try context.save()
                                    })
        #expect(saves == 2)

        try context.save()
        let rows = try SoundRejectionStore.rows(
            for: SoundRejection.Key(capsuleID: capsuleA, identifier: "rain"), in: context)
        #expect(rows.count == 2, "the superseded row was restored rather than left pending-delete")
        #expect(!(try index(context)).isRejected("rain", for: capsuleA),
                "and the answer that was durably stored still wins")
    }

    // MARK: Removal

    @Test func removingACapsulesRejectionsLeavesEveryOtherCapsuleAlone() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        row(context, capsuleA, "wind", true, at(100))
        row(context, capsuleB, "rain", true, at(100))
        try context.save()

        #expect(try SoundRejectionStore.removeAll(forCapsule: capsuleA, in: context) == 2)
        try context.save()
        let index = try index(context)
        #expect(index.rejectedIdentifiers(for: capsuleA).isEmpty)
        #expect(index.isRejected("rain", for: capsuleB))
    }

    @Test func erasingRemovesEverything() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        row(context, capsuleB, "wind", true, at(100))
        try context.save()

        #expect(try SoundRejectionStore.eraseAll(in: context) == 2)
        #expect((try index(context)).isEmpty)
        #expect(try SoundRejectionStore.eraseAll(in: context) == 0, "and it is idempotent")
    }

    // MARK: The index

    /// One scoped fetch, not one per capsule (§4B) — and an empty request must fetch
    /// nothing rather than everything.
    @Test func theScopedIndexCoversExactlyTheCapsulesAskedFor() throws {
        let context = try store()
        row(context, capsuleA, "rain", true, at(100))
        row(context, capsuleB, "wind", true, at(100))
        try context.save()

        let scoped = try SoundRejectionStore.index(forCapsules: [capsuleA], in: context, now: now)
        #expect(scoped.isRejected("rain", for: capsuleA))
        #expect(!scoped.isRejected("wind", for: capsuleB))
        #expect(scoped.capsuleIDs == [capsuleA])

        #expect(try SoundRejectionStore.index(forCapsules: [], in: context, now: now).isEmpty,
                "asking about no capsules must not answer about all of them")
    }

    /// An undo is an answer to the store and a non-event to a screen: what a render
    /// site needs is the set of labels to leave out, and `false` is not one of them.
    @Test func theIndexCarriesRejectionsOnlyNotUndos() throws {
        let context = try store()
        row(context, capsuleA, "rain", false, at(100))
        try context.save()
        #expect((try index(context)).isEmpty)
        #expect((try index(context)).rejectedIdentifiers(for: capsuleA).isEmpty)
    }

    @Test func theEmptyIndexRejectsNothing() {
        #expect(RejectionIndex.none.isEmpty)
        #expect(!RejectionIndex.none.isRejected("rain", for: capsuleA))
        #expect(RejectionIndex.none.rejectedIdentifiers(for: capsuleA).isEmpty)
    }

    // MARK: The record's shape, which is what makes it survivable

    /// CloudKit forbids unique constraints and non-defaulted properties, and a schema
    /// that breaks either is caught at store load — where `makeProductionContainer`
    /// catches it and quietly drops to a local store.
    @Test func theRecordIsShapedTheWayCloudKitNeeds() throws {
        let entity = try #require(
            SoundpostModelContainer.productionSchema.entities.first { $0.name == "SoundRejection" })
        #expect(Set(entity.attributes.map(\.name))
            .isSuperset(of: ["id", "capsuleID", "identifier", "rejected", "changedAt"]))
        #expect(entity.uniquenessConstraints.isEmpty)
        #expect(entity.relationships.isEmpty,
                "the capsule join is a plain UUID — a relationship would put a field on CD_Capsule")
    }
}
