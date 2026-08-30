import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M16 §S2: fixing what you wrote.
///
/// The milestone exists because a wrong word is permanent today — including a word
/// the *machine* put there, since accepting a sound suggestion appends its phrase to
/// the user's own line (`CaptureView.acceptSuggestion`). These tests pin what an
/// edit may change, what it must never touch, and what happens when the write fails.
@Suite(.serialized)
@MainActor
struct CapsuleEditTests {
    /// Its own container. `freshStore()` is a container-wide `delete(model:)` on the
    /// one every suite shares, and Swift Testing runs suites in parallel — so a
    /// synchronous suite that inserts sealed capsules can be observed mid-flight by
    /// another suite's `await`. Adding this suite is what finally made that fire
    /// (see the sibling conversions in this commit).
    private func makeStore() throws -> CapsuleStore {
        try TestSupport.isolatedStore()
    }

    @discardableResult
    private func capture(_ store: CapsuleStore) throws -> Capsule {
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "clip.m4a", durationSeconds: 9, waveformSamples: [0.2])
        capsule.note = "Rain on the window"
        capsule.mood = .calm
        capsule.place = Place(latitude: 35.7148, longitude: 139.7753, name: "Uenokoen 1-2-3")
        try store.save()
        return capsule
    }

    // MARK: Round trips

    @Test func everyEditableFieldRoundTrips() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let echo = Date(timeIntervalSinceNow: 10 * 86_400)

        try store.update(capsule, note: "Rain on the kitchen window", mood: .nostalgic,
                         place: .rename("Ueno Park"), echoAt: echo)

        #expect(capsule.note == "Rain on the kitchen window")
        #expect(capsule.mood == .nostalgic)
        #expect(capsule.place?.name == "Ueno Park")
        #expect(capsule.echoAt == SealClock.normalize(echo))

        // And it is the *store* that changed, not just this object in memory.
        let reread = try #require(try store.all().first)
        #expect(reread.note == "Rain on the kitchen window")
        #expect(reread.place?.name == "Ueno Park")
    }

    /// The same rule the capture flow applies (`CaptureViewModel.save`), so an edit
    /// and a capture write the same value for the same typing.
    @Test func blankTextBecomesNothingRatherThanAnEmptyString() throws {
        let store = try makeStore()
        let capsule = try capture(store)

        try store.update(capsule, note: "   ", mood: nil, place: .rename("  "), echoAt: nil)

        #expect(capsule.note == nil)
        #expect(capsule.mood == nil)
        #expect(capsule.place?.name == nil)
        #expect(capsule.place != nil)   // a blank name is not a removed place
    }

    /// An echo picked at edit time gets the humane hour every other reminder gets,
    /// so a correction cannot make a capsule ring back at 02:47 (M12 §S2).
    @Test func anEditedEchoIsNormalisedToAHumaneHour() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let awkward = Date(timeIntervalSinceNow: 5 * 86_400)

        try store.update(capsule, note: nil, mood: nil, place: .remove, echoAt: awkward)

        let hour = Calendar.current.component(.hour, from: try #require(capsule.echoAt))
        #expect(hour == 9)
    }

    // MARK: What an edit may never do

    /// A capsule is *when it happened*. Every path, including the ones that change
    /// everything else.
    @Test func createdAtNeverMoves() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let created = capsule.createdAt

        try store.update(capsule, note: "one", mood: .joyful, place: .rename("here"), echoAt: nil)
        #expect(capsule.createdAt == created)
        try store.update(capsule, note: nil, mood: nil, place: .remove,
                         echoAt: Date(timeIntervalSinceNow: 86_400 * 3))
        #expect(capsule.createdAt == created)
        #expect(try store.all().first?.createdAt == created)
    }

    /// Where you were is a record, not a field a later edit can invent — so a rename
    /// keeps the coordinates, and nothing can add a place to a capsule that has none.
    @Test func coordinatesAreNeverRewrittenAndAPlaceIsNeverInvented() throws {
        let store = try makeStore()
        let capsule = try capture(store)

        try store.update(capsule, note: nil, mood: nil, place: .rename("Ueno Park"), echoAt: nil)
        #expect(capsule.place?.latitude == 35.7148)
        #expect(capsule.place?.longitude == 139.7753)

        try store.update(capsule, note: nil, mood: nil, place: .remove, echoAt: nil)
        #expect(capsule.place == nil)

        // Naming a place that is not there does not create one.
        try store.update(capsule, note: nil, mood: nil, place: .rename("Somewhere else"), echoAt: nil)
        #expect(capsule.place == nil)
    }

    /// §4B. A sealed capsule's note is hidden from its owner by design; an edit that
    /// went through would be a back door around the seal, and a sheet showing the
    /// note in a text field would be the seal simply not working.
    @Test func aSealedNotDueCapsuleCannotBeContentEdited() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        try store.seal(capsule, until: Date(timeIntervalSinceNow: 400 * 86_400))
        try store.save()

        #expect(throws: CapsuleEditError.contentHidden) {
            try store.update(capsule, note: "sneaking a look", mood: .anxious,
                             place: .remove, echoAt: nil)
        }
        #expect(capsule.note == "Rain on the window")   // untouched
        #expect(capsule.mood == .calm)
        #expect(capsule.place != nil)
    }

    @Test func aDraftCannotBeEdited() throws {
        let store = try makeStore()
        let capsule = store.create()
        #expect(throws: CapsuleEditError.contentHidden) {
            try store.update(capsule, note: "x", mood: nil, place: .remove, echoAt: nil)
        }
    }

    /// Once the seal's date has passed, the words are the user's again.
    @Test func aSealPastItsDateCanBeEdited() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        try store.seal(capsule, until: Date(timeIntervalSinceNow: 400 * 86_400))
        try store.save()

        try store.update(capsule, note: "corrected", mood: nil, place: .remove, echoAt: nil,
                         now: Date(timeIntervalSinceNow: 401 * 86_400))
        #expect(capsule.note == "corrected")
    }

    // MARK: A failed write must leave nothing half-applied (§4D)

    /// `rollback()` does not restore already-materialised objects — this project has
    /// learned that twice. Without the by-hand restore the capsule would keep the new
    /// values in memory while the store still held the old ones, and the next
    /// unrelated save would commit an edit this one had already reported as failed.
    @Test func aFailedCommitLeavesTheCapsuleExactlyAsItWas() throws {
        struct Boom: Error {}
        let store = try makeStore()
        let capsule = try capture(store)
        let echo = Date(timeIntervalSinceNow: 4 * 86_400)
        store.setEcho(capsule, at: echo)
        try store.save()

        #expect(throws: Boom.self) {
            try store.update(capsule, note: "a correction that will not land",
                             mood: .anxious, place: .remove, echoAt: nil,
                             commit: { throw Boom() })
        }

        #expect(capsule.note == "Rain on the window")
        #expect(capsule.mood == .calm)
        #expect(capsule.place?.name == "Uenokoen 1-2-3")
        #expect(capsule.echoAt == SealClock.normalize(echo))

        // The decisive one: a later, unrelated save must not carry the failed edit
        // into the store behind the user's back.
        try store.save()
        let reread = try #require(try store.all().first)
        #expect(reread.note == "Rain on the window")
        #expect(reread.place?.name == "Uenokoen 1-2-3")
    }

    // MARK: The edit reaches the lock screen (§4C, the S1 mechanism)

    /// Editing the note changes the identity of the pending reminder, which is the
    /// only thing that makes `reconcile` rebuild its body instead of skipping a
    /// request it has already scheduled. Without this the old sentence would keep
    /// firing — for as long as the seal.
    @Test func editingTheNoteChangesTheScheduledRequestsIdentity() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let fire = Date(timeIntervalSinceNow: 9 * 86_400)

        let before = Self.scheduledIdentifier(for: capsule, firingAt: fire)
        try store.update(capsule, note: "Rain on the kitchen window", mood: capsule.mood,
                         place: .rename(capsule.place?.name), echoAt: nil)
        let after = Self.scheduledIdentifier(for: capsule, firingAt: fire)

        #expect(before != after)
    }

    /// The other direction, and it is a property of fingerprinting the *rendered
    /// copy* rather than a list of fields: mood never reaches a notification body, so
    /// changing it re-issues nothing.
    @Test func editingSomethingTheCopyNeverRendersReissuesNothing() throws {
        let store = try makeStore()
        let capsule = try capture(store)
        let fire = Date(timeIntervalSinceNow: 9 * 86_400)

        let before = Self.scheduledIdentifier(for: capsule, firingAt: fire)
        try store.update(capsule, note: capsule.note, mood: .anxious,
                         place: .rename(capsule.place?.name), echoAt: nil)
        let after = Self.scheduledIdentifier(for: capsule, firingAt: fire)

        #expect(capsule.mood == .anxious)
        #expect(before == after)
    }

    /// Exactly what `NotificationCoordinator.sync` builds for one capsule, with
    /// lock-screen previews on — the case where the user's own words are quoted.
    private static func scheduledIdentifier(for capsule: Capsule, firingAt fire: Date) -> String {
        let item = PlannedNotification(capsuleID: capsule.id, fireDate: fire,
                                       timeZoneID: nil, kind: .echo)
        let digest = NotificationCopy.Digest(
            createdAt: capsule.createdAt,
            note: capsule.note,
            placeName: capsule.place?.name,
            mood: capsule.mood,
            soundprint: Soundprint(stored: capsule.soundprintRaw)
        , rejected: .none)
        let copy = NotificationCopy.make(for: item, digest: digest, personalized: true)
        return NotificationScheduler.identifier(
            for: item,
            contentVersion: NotificationPreferences.contentVersion(personalized: true, listening: true),
            contentFingerprint: NotificationScheduler.contentFingerprint(title: copy.title, body: copy.body)
        )
    }
}
