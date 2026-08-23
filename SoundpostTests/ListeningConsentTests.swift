import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// Account-wide listening consent (M15 §4I, revised).
///
/// The bug these exist for: the switch was a per-device `UserDefaults` flag while
/// its effect — erasing every stored soundprint — went through the CloudKit-mirrored
/// store and so applied everywhere. A second device with listening still on would
/// backfill the just-cleared capsules and sync the labels home, and search found
/// them again on the device where the user had turned it off.
///
/// Each test owns both its store *and* its preference storage. `.serialized` was the
/// first attempt and is not enough: it orders a suite's tests against each other and
/// says nothing about other suites, and `SoundConsentTests` and
/// `SoundprintBackfillTests` drive the same `UserDefaults` key in parallel. So the
/// contention is removed rather than ordered — see
/// `TestSupport.withIsolatedListeningPreference`.
@MainActor
struct ListeningConsentTests {

    private func withMirror(_ initial: Bool, _ body: (CapsuleStore) throws -> Void) throws {
        try TestSupport.withIsolatedListeningPreference(initial) {
            try body(try TestSupport.isolatedStore())
        }
    }

    private func record(_ store: CapsuleStore, enabled: Bool, at date: Date) {
        store.context.insert(ListeningConsent(enabled: enabled, changedAt: date))
    }

    // MARK: Resolution

    /// No record means nobody has ever touched the switch. Deliberately not seeded
    /// at launch — every device would race to create one, and a seeded row carries
    /// no user intent worth preserving.
    @Test func withNoRecordItFallsBackToTheDeviceDefault() throws {
        try withMirror(true) { store in
            let effective = try ListeningConsentStore.resolve(in: store.context)
            #expect(effective)
        }
        try withMirror(false) { store in
            let effective = try ListeningConsentStore.resolve(in: store.context)
            #expect(!effective)
        }
    }

    @Test func theMostRecentAnswerWins() throws {
        try withMirror(true) { store in
            let old = Date(timeIntervalSince1970: 1_000)
            record(store, enabled: true, at: old)
            record(store, enabled: false, at: old.addingTimeInterval(60))
            try store.save()
            let effective = try ListeningConsentStore.resolve(in: store.context)
            #expect(!effective, "the later 'off' must beat the earlier 'on'")
        }
    }

    /// And in the other direction — this is not an off-latch, it is last-writer-wins.
    @Test func turningItBackOnLaterAlsoWins() throws {
        try withMirror(false) { store in
            let old = Date(timeIntervalSince1970: 1_000)
            record(store, enabled: false, at: old)
            record(store, enabled: true, at: old.addingTimeInterval(60))
            try store.save()
            let effective = try ListeningConsentStore.resolve(in: store.context)
            #expect(effective)
        }
    }

    /// Clocks differ between devices. When two answers claim the same instant we
    /// cannot tell which came last, so the privacy-preserving one is honoured.
    @Test func aTieGoesToOff() throws {
        try withMirror(true) { store in
            let sameInstant = Date(timeIntervalSince1970: 5_000)
            record(store, enabled: true, at: sameInstant)
            record(store, enabled: false, at: sameInstant)
            try store.save()
            let effective = try ListeningConsentStore.resolve(in: store.context)
            #expect(!effective)
        }
    }

    // MARK: Writing

    @Test func settingItWritesTheRecordAndTheMirror() throws {
        try withMirror(true) { store in
            try ListeningConsentStore.set(false, in: store.context)
            #expect(!SoundAnalysisPreferences.isEnabled, "the local mirror follows immediately")
            let winner = try ListeningConsentStore.winner(in: store.context)
            #expect(winner?.enabled == false)
        }
    }

    /// A new answer supersedes everything older, so rows do not accumulate.
    @Test func writingSupersedesOlderRecords() throws {
        try withMirror(true) { store in
            record(store, enabled: true, at: Date(timeIntervalSince1970: 1_000))
            record(store, enabled: false, at: Date(timeIntervalSince1970: 2_000))
            try store.save()

            try ListeningConsentStore.set(true, in: store.context)

            let all = try store.context.fetch(FetchDescriptor<ListeningConsent>())
            #expect(all.count == 1)
            #expect(all.first?.enabled == true)
        }
    }

    /// An answer is a new row, never an edit to an existing one.
    ///
    /// This is the property that keeps the whole ordering scheme meaningful. If both
    /// devices edited one shared row, CloudKit would resolve the conflict itself and
    /// `winner()` would only ever see the survivor — a stale "on" exported after a
    /// newer "off" would win, and the withdrawal would vanish before any of the code
    /// above got to compare timestamps.
    @Test func anAnswerNeverEditsAnExistingRecord() throws {
        try withMirror(true) { store in
            let existing = ListeningConsent(enabled: true, changedAt: Date(timeIntervalSince1970: 1_000))
            store.context.insert(existing)
            try store.save()
            let existingID = existing.id

            // Dated *after* the existing row, so nothing here is superseded.
            try ListeningConsentStore.set(false, in: store.context, now: Date(timeIntervalSince1970: 500))

            let all = try store.context.fetch(FetchDescriptor<ListeningConsent>())
            #expect(all.count == 2, "the new answer is its own row")
            let untouched = all.first { $0.id == existingID }
            #expect(untouched?.enabled == true, "the earlier answer is left exactly as it was")
            #expect(untouched?.changedAt == Date(timeIntervalSince1970: 1_000))
        }
    }

    // MARK: Adopting another device's answer

    /// The failure this whole change exists to prevent: the withdrawal was made
    /// elsewhere, and it arrives here as a merged record.
    @Test func adoptingAWithdrawalErasesWhatThisDeviceHeard() throws {
        try withMirror(true) { store in
            let capsule = store.create()
            capsule.soundprintRaw = Soundprint(
                classifier: "version1",
                labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)]).stored
            record(store, enabled: false, at: Date(timeIntervalSince1970: 9_000))
            try store.save()

            let effective = try ListeningConsentStore.applyToDevice(in: store.context)

            #expect(!effective)
            #expect(!SoundAnalysisPreferences.isEnabled, "the mirror every gate reads must follow")
            #expect(capsule.soundprintRaw == nil, "labels that arrived here are cleared too")
        }
    }

    /// Erasing on *every* merge, not only on the transition: an erase and its
    /// consent record can arrive in either order, and a backfill batch can land
    /// between them. The invariant is "consent off ⇒ nothing stored here".
    @Test func itStaysErasedWhenLabelsArriveAfterTheWithdrawal() throws {
        try withMirror(true) { store in
            record(store, enabled: false, at: Date(timeIntervalSince1970: 9_000))
            try store.save()
            _ = try ListeningConsentStore.applyToDevice(in: store.context)

            // A straggler merges in from a device that had not yet caught up.
            let late = store.create()
            late.soundprintRaw = Soundprint(
                classifier: "version1",
                labels: [Soundprint.Label(identifier: "ocean", confidence: 0.8)]).stored
            try store.save()

            _ = try ListeningConsentStore.applyToDevice(in: store.context)
            #expect(late.soundprintRaw == nil)
        }
    }

    /// A local opt-out carried across at upgrade **outranks an older dated grant**,
    /// and that direction is deliberate.
    ///
    /// At first upgrade the two answers cannot be ordered: the local mirror has no
    /// timestamp, so "I turned it off here" and "I turned it on there" are
    /// indistinguishable in time. The two ways to be wrong are not symmetric —
    /// forcing OFF wrongly costs the user one flick of a switch, while forcing ON
    /// wrongly resumes analysing audio somebody opted out of. §1.2 picks the first.
    @Test func aLocalOptOutOutranksAnOlderGrantAtUpgrade() throws {
        try withMirror(false) { store in
            let capsule = store.create()
            capsule.soundprintRaw = Soundprint(
                classifier: "version1",
                labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)]).stored
            record(store, enabled: true, at: Date(timeIntervalSince1970: 9_000))
            try store.save()

            let effective = try ListeningConsentStore.applyToDevice(in: store.context)

            #expect(!effective)
            #expect(capsule.soundprintRaw == nil, "the carried-over opt-out erases here too")
        }
    }

    /// And it happens once. A second pass must not keep re-asserting the same
    /// opt-out over answers made since.
    @Test func theCarriedOverOptOutIsAssertedOnlyOnce() throws {
        try withMirror(false) { store in
            _ = try ListeningConsentStore.applyToDevice(in: store.context)
            #expect(!SoundAnalysisPreferences.isEnabled)

            // The user turns it back on, here or anywhere.
            try ListeningConsentStore.set(true, in: store.context)
            #expect(SoundAnalysisPreferences.isEnabled)

            // A later merge must leave that alone rather than re-adopting.
            let effective = try ListeningConsentStore.applyToDevice(in: store.context)
            #expect(effective)
            #expect(SoundAnalysisPreferences.isEnabled)
        }
    }

    // MARK: A clock that runs fast

    /// The flip that settling exists to stop.
    ///
    /// Device A's clock is five minutes fast, so its grant is dated ahead of real
    /// time; device B withdraws two minutes later by an honest clock. Read-time
    /// clamping gets this right only until A's timestamp stops being in the future —
    /// after that the grant genuinely looks newer and listening turns itself back on
    /// with nobody touching the switch.
    @Test func aFastClocksGrantCannotUndoALaterWithdrawal() throws {
        try withMirror(true) { store in
            let now = Date(timeIntervalSince1970: 100_000)
            record(store, enabled: true, at: now.addingTimeInterval(300))
            record(store, enabled: false, at: now.addingTimeInterval(120))
            try store.save()

            // While the grant is still in the future the clamp already handles it.
            #expect(try ListeningConsentStore.winner(in: store.context, now: now)?.enabled == false)

            #expect(try ListeningConsentStore.settleFutureDatedAnswers(in: store.context, now: now))

            // An hour on, the grant is comfortably in the past — and must still lose.
            let later = now.addingTimeInterval(3_600)
            #expect(
                try ListeningConsentStore.winner(in: store.context, now: later)?.enabled == false,
                "a withdrawal must not be undone by a clock that was merely fast"
            )
        }
    }

    /// Nothing to arbitrate when every answer agrees: the value is kept and only the
    /// date comes back to the present, so it cannot sit a year ahead indefinitely.
    @Test func anUncontestedFutureAnswerKeepsItsValueAndLosesItsFutureDate() throws {
        try withMirror(true) { store in
            let now = Date(timeIntervalSince1970: 100_000)
            record(store, enabled: true, at: now.addingTimeInterval(86_400 * 365))
            try store.save()

            #expect(try ListeningConsentStore.settleFutureDatedAnswers(in: store.context, now: now))

            let all = try store.context.fetch(FetchDescriptor<ListeningConsent>())
            #expect(all.count == 1)
            #expect(all.first?.enabled == true, "an uncontested answer keeps what it says")
            #expect(all.first?.changedAt == now)
        }
    }

    /// And honestly dated answers are left completely alone — this must not quietly
    /// become an off-latch for everyone whose devices merely disagree.
    @Test func honestlyDatedAnswersAreNotTouched() throws {
        try withMirror(true) { store in
            let now = Date(timeIntervalSince1970: 100_000)
            record(store, enabled: false, at: now.addingTimeInterval(-600))
            record(store, enabled: true, at: now.addingTimeInterval(-300))
            try store.save()

            #expect(try !ListeningConsentStore.settleFutureDatedAnswers(in: store.context, now: now))

            let all = try store.context.fetch(FetchDescriptor<ListeningConsent>())
            #expect(all.count == 2, "no collapsing, no rewriting")
            #expect(
                try ListeningConsentStore.winner(in: store.context, now: now)?.enabled == true,
                "ordinary last-writer-wins is untouched"
            )
        }
    }

    /// With the mirror already on there is nothing to carry across, and a grant must
    /// never erase.
    @Test func adoptingAGrantLeavesCapsulesAlone() throws {
        try withMirror(true) { store in
            let capsule = store.create()
            let heard = Soundprint(
                classifier: "version1",
                labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)]).stored
            capsule.soundprintRaw = heard
            record(store, enabled: true, at: Date(timeIntervalSince1970: 9_000))
            try store.save()

            let effective = try ListeningConsentStore.applyToDevice(in: store.context)
            #expect(effective)
            #expect(SoundAnalysisPreferences.isEnabled)
            #expect(capsule.soundprintRaw == heard, "a grant must never erase")
        }
    }
}
