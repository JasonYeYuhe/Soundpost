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

    /// Two offline devices can each create a record. A later local write collapses
    /// them, so rows do not accumulate.
    @Test func writingCollapsesDuplicateRecords() throws {
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

    @Test func adoptingAGrantLeavesCapsulesAlone() throws {
        try withMirror(false) { store in
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
