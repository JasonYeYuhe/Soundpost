import Testing
import Foundation
import UserNotifications
@testable import Soundpost

/// Four findings from the external review of M17 (Codex + Gemini 3.7 Flash,
/// 2026-08-27), each verified against the code before being acted on.
///
/// Three of the four are places where M17 wrote a rule and then left a surface that
/// breaks it; the first is worse than that — it is M17's own fix landing at the exact
/// moment it cannot work.

// MARK: - A notification tap that arrives before its capsule does

@MainActor
struct PendingDeepLinkTests {

    /// **The finding.** `handleDeepLink` cleared the pending id whether or not it had
    /// found the capsule. M17 §S4 then made the drain run at cold launch — which is
    /// precisely when CloudKit is least likely to have delivered that capsule — so the
    /// fix moved the loss closer to the case it was meant to repair.
    @Test func aLinkWaitsForACapsuleThatHasNotImportedYet() {
        let wanted = UUID()
        let library = [UUID(), UUID()]
        #expect(CapsuleOpenRoute.pendingLink(wanted, among: library) == .wait)
    }

    @Test func aLinkOpensACapsuleThatIsAlreadyHere() {
        let wanted = UUID()
        let library = [UUID(), wanted, UUID()]
        #expect(CapsuleOpenRoute.pendingLink(wanted, among: library) == .open(wanted))
    }

    /// The empty library is the cold-launch shape, and it must not resolve to
    /// "nothing pending" — that is the bug, restated.
    @Test func anEmptyLibraryIsWaitingNotNothing() {
        #expect(CapsuleOpenRoute.pendingLink(UUID(), among: []) == .wait)
    }

    @Test func noLinkIsNothingToDo() {
        #expect(CapsuleOpenRoute.pendingLink(nil, among: [UUID()]) == .none)
    }
}

// MARK: - Standing: the consent mirror's default lies on a fresh device

@MainActor
struct DisplayStandingTests {

    private func rainy() throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.91)]
        ).stored
        return capsule
    }

    /// **The finding.** M15 §11Q established that `isEnabled` reads `true` both for
    /// someone who wants listening on and for a device that has never been told
    /// anything — and built standing for the retrospective drains. M17 added a second
    /// way for a label to reach a person and did not extend it, so in the window
    /// between the library importing and the consent row arriving, a card could show
    /// exactly what the user had opted out of.
    ///
    /// Called WITHOUT `listening:`, deliberately — the whole fix is what that
    /// parameter now defaults to. Passing it explicitly would test the gate that
    /// already worked and say nothing about standing.
    @Test func nothingIsShownWithoutStandingEvenWhenTheMirrorSaysYes() throws {
        let capsule = try rainy()
        TestSupport.withIsolatedListeningPreference(true) {
            SoundAnalysisPreferences.hasStanding = false
            #expect(SoundprintDisplay.phrases(for: capsule, on: .detail).isEmpty,
                    "the mirror says yes — but it is a default, not an answer")
            #expect(SoundprintDisplay.phrases(for: capsule, on: .card).isEmpty)

            SoundAnalysisPreferences.hasStanding = true
            #expect(!SoundprintDisplay.phrases(for: capsule, on: .detail).isEmpty,
                    "and once it is an answer, the label shows")
        }
    }

    /// `mayReveal` is the composed rule every gate defaults to, and it needs BOTH.
    @Test func mayRevealNeedsAnAnswerAndStandingForIt() {
        TestSupport.withIsolatedListeningPreference(true) {
            SoundAnalysisPreferences.hasStanding = false
            #expect(!SoundAnalysisPreferences.mayReveal, "on, but the answer is a default")
            SoundAnalysisPreferences.hasStanding = true
            #expect(SoundAnalysisPreferences.mayReveal)
        }
        TestSupport.withIsolatedListeningPreference(false) {
            SoundAnalysisPreferences.hasStanding = true
            #expect(!SoundAnalysisPreferences.mayReveal, "a real answer, and it says no")
        }
    }

    /// Standing defaults to **false**: until the app knows, it does not show. A stale
    /// `false` costs one launch of hidden labels; a stale `true` would show a label to
    /// someone who said no.
    @Test func standingIsAbsentUntilItIsEstablished() {
        TestSupport.withIsolatedListeningPreference(true) {
            #expect(!SoundAnalysisPreferences.hasStanding)
            #expect(!SoundAnalysisPreferences.mayReveal)
        }
    }

    /// Recording here settles it immediately — the capsule just saved must be able to
    /// show its own labels on the card the user returns to, not at the next launch.
    @Test func recordingHereGrantsStanding() throws {
        try TestSupport.withIsolatedListeningPreference(true) {
            SoundAnalysisPreferences.hasStanding = false
            let store = try TestSupport.freshStore()
            let viewModel = CaptureViewModel()
            viewModel.setReviewStateForTesting(fileName: "a.m4a", duration: 3, waveform: [0.2])
            _ = try viewModel.save(using: store)
            #expect(SoundAnalysisPreferences.hasStanding)
        }
    }

    /// Search and the sound facet inherit the same rule, because they reveal a label
    /// just as a card does — finding a capsule *by its sound* says what Soundpost
    /// heard as surely as printing it.
    @Test func searchAndTheFacetAlsoRequireStanding() throws {
        let capsule = try rainy()
        TestSupport.withIsolatedListeningPreference(true) {
            SoundAnalysisPreferences.hasStanding = false
            #expect(GalleryFilter.apply([capsule], .init(searchText: "rain")).isEmpty)
            #expect(GalleryFilter.apply([capsule], .init(sounds: ["rain"])).isEmpty)

            SoundAnalysisPreferences.hasStanding = true
            #expect(GalleryFilter.apply([capsule], .init(searchText: "rain")).count == 1)
            #expect(GalleryFilter.apply([capsule], .init(sounds: ["rain"])).count == 1)
        }
    }
}

// MARK: - The lock screen put the machine's guess in quotation marks

@MainActor
struct NotificationAttributionTests {

    private func digest(note: String? = nil, place: String? = nil,
                        sound: String? = nil) -> NotificationCopy.Digest {
        NotificationCopy.Digest(
            createdAt: Date.now.addingTimeInterval(-5 * 86_400),
            note: note, placeName: place, mood: nil,
            soundprint: sound.map {
                Soundprint(classifier: "version1",
                           labels: [Soundprint.Label(identifier: $0, confidence: 0.91)])
            }
        )
    }

    private func plan(_ kind: PlannedNotification.Kind) -> PlannedNotification {
        PlannedNotification(capsuleID: UUID(), fireDate: .now, timeZoneID: nil, kind: kind)
    }

    /// **The finding.** «"rain" — tap to listen.» presents a classifier label as the
    /// user's own sentence, on a lock screen, where they cannot ask a follow-up.
    @Test func aHeardPhraseIsAttributedAndNeverQuoted() {
        let rain = try! #require(SoundVocabulary.displayName(for: "rain"))
        for kind in [PlannedNotification.Kind.seal, .echo] {
            let body = NotificationCopy.make(for: plan(kind),
                                             digest: digest(sound: "rain"),
                                             personalized: true).body
            #expect(body.contains("Soundpost"), "\(kind): the guesser is named")
            #expect(body.contains(rain))
            #expect(!body.contains("“"), "\(kind): and it is not dressed as their words")
            #expect(!body.contains("”"))
        }
    }

    /// The user's own line keeps its quotation marks — they really did write it.
    @Test func theUsersOwnWordsAreStillQuoted() {
        for kind in [PlannedNotification.Kind.seal, .echo] {
            let body = NotificationCopy.make(for: plan(kind),
                                             digest: digest(note: "the storm broke"),
                                             personalized: true).body
            #expect(body.contains("“the storm broke”"), "\(kind)")
        }
    }

    /// The lead carries whose words it is, which is what the copy branches on.
    @Test func theLeadKnowsWhoseWordsItIs() {
        #expect(digest(note: "mine").lead == .ownWords("mine"))
        #expect(digest(place: "Ueno Park").lead == .ownWords("Ueno Park"))
        let rain = try! #require(SoundVocabulary.displayName(for: "rain"))
        #expect(digest(sound: "rain").lead == .heard(rain))
        #expect(digest().lead == nil)
    }

    /// Unchanged: a guess reaches a lock screen only when the user opted into
    /// personalized previews at all.
    @Test func nothingIsAttributedWhenPreviewsAreOff() {
        let body = NotificationCopy.make(for: plan(.seal), digest: digest(sound: "rain"),
                                         personalized: false).body
        #expect(!body.contains("Soundpost heard"))
    }
}

// MARK: - A promise made on a screen that never asks

@MainActor
struct EchoPromiseTests {

    /// **The finding.** The seal sheet requests authorization as part of its flow, so
    /// `.notDetermined` there is a question about to be asked. Capture never asks —
    /// onboarding does, and onboarding has a Skip button — so the same status on the
    /// capture sheet means nothing will ever ask and the echo is scheduled into a
    /// permission the app does not hold.
    @Test func anUndecidedPermissionIsAPromiseOnlyWhereItWillBeAsked() {
        let coordinator = NotificationCoordinator()
        coordinator.setAuthorizationForTesting(.notDetermined)
        #expect(coordinator.canPromiseAReminder, "the seal sheet is about to ask")
        #expect(!coordinator.remindersWouldBeDelivered, "capture is not")
    }

    @Test func theTwoRulesAgreeEverywhereElse() {
        let coordinator = NotificationCoordinator()
        for status in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            coordinator.setAuthorizationForTesting(status)
            #expect(coordinator.canPromiseAReminder && coordinator.remindersWouldBeDelivered,
                    "\(status)")
        }
        coordinator.setAuthorizationForTesting(.denied)
        #expect(!coordinator.canPromiseAReminder && !coordinator.remindersWouldBeDelivered)
    }

    /// Unread is not the same as off, and saying otherwise would be its own false
    /// statement — in the other direction.
    @Test func anUnreadStatusPromisesOnBothRules() {
        let coordinator = NotificationCoordinator()
        #expect(coordinator.authorizationStatus == nil)
        #expect(coordinator.canPromiseAReminder)
        #expect(coordinator.remindersWouldBeDelivered)
    }
}
