import Testing
import Foundation
import UserNotifications
@testable import Soundpost

/// M17 §S4 — the honesty sweep. Small things the app was saying that were not true.
///
/// Each of these is a place where the app asserted something about itself rather than
/// about a memory, which is why they are gathered rather than scattered: a dated
/// reminder it had been forbidden to send, a seal that was over before it began, a
/// notification tap that did nothing, and an empty state that answered a question
/// nobody asked.

// MARK: - A promise the OS has already refused

@MainActor
struct ReminderPromiseTests {

    /// Only an outright denial is a state where the app knows, before saying
    /// anything, that nothing will arrive. `.notDetermined` still gets the promise —
    /// sealing asks for permission as part of the flow, so warning about a refusal
    /// that has not happened would be its own small untruth.
    @Test func onlyADenialWithdrawsThePromise() async {
        let coordinator = NotificationCoordinator()

        coordinator.setAuthorizationForTesting(.denied)
        #expect(!coordinator.canPromiseAReminder)

        for granted in [UNAuthorizationStatus.authorized, .provisional, .ephemeral, .notDetermined] {
            coordinator.setAuthorizationForTesting(granted)
            #expect(coordinator.canPromiseAReminder, "\(granted) is not a refusal")
        }
    }

    /// Unread, the app promises. Anything else would mean a fresh install's first seal
    /// sheet apologised for a permission nobody had been asked for yet.
    @Test func anUnreadStatusStillPromises() {
        let coordinator = NotificationCoordinator()
        #expect(coordinator.authorizationStatus == nil)
        #expect(coordinator.canPromiseAReminder)
    }
}

// MARK: - A seal that was over before it began

@MainActor
struct SealInstantTests {

    private var timeZone: TimeZone { TimeZone(identifier: "Asia/Tokyo") ?? .current }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = day
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)!
    }

    /// The defect: `seal` normalized to 09:00 unconditionally, so sealing "until
    /// today" at six in the evening stored nine o'clock *this morning* — a capsule due
    /// the instant it was sealed.
    @Test func sealingForTodayDoesNotStoreThisMorning() throws {
        let evening = at(18)
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "a.m4a", audioData: nil,
                               durationSeconds: 3, waveformSamples: [0.2])

        // What the picker actually produces for "today": the current instant nudged
        // forward, since the sheet's range starts at `now + 60`.
        let chosen = evening.addingTimeInterval(60)
        try store.seal(capsule, until: chosen, timeZone: timeZone, now: evening)

        let sealed = try #require(capsule.sealUntil)
        #expect(sealed == chosen, "the chosen instant stands")
        #expect(sealed > SealClock.normalize(evening, in: timeZone),
                "and specifically it is not nine o'clock this morning, which is what was stored")
        #expect(!capsule.isDueToResurface(now: evening),
                "so the seal is not already over at the moment it is made")
    }

    /// And the humane hour is still applied whenever it is genuinely ahead, which is
    /// every seal a user can actually make through the picker.
    @Test func aFutureSealStillLandsAtTheHumaneHour() throws {
        let evening = at(18)
        let nextWeek = at(23, day: 22)
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "a.m4a", audioData: nil,
                               durationSeconds: 3, waveformSamples: [0.2])

        try store.seal(capsule, until: nextWeek, timeZone: timeZone, now: evening)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: try #require(capsule.sealUntil))
        #expect(hour == SealClock.humaneHour)
    }

    /// The rule as a pure function, in both directions.
    @Test func onlyNormalizationIsPreventedFromMovingAnInstantBackwards() {
        let evening = at(18)
        // 09:00 today has passed: the chosen instant stands.
        #expect(CapsuleStore.humaneInstant(for: evening, in: timeZone, now: evening) == evening)
        // 09:00 tomorrow has not: normalization applies.
        let tomorrow = at(23, day: 16)
        let normalized = CapsuleStore.humaneInstant(for: tomorrow, in: timeZone, now: evening)
        #expect(normalized == SealClock.normalize(tomorrow, in: timeZone))
        #expect(normalized < tomorrow, "and it really did move it")
    }

    /// A caller's own past date is left alone: this guard is about normalization
    /// creating a past instant, not about second-guessing the caller.
    @Test func aDateAlreadyInThePastIsNotRewritten() {
        let evening = at(18)
        let lastWeek = at(14, day: 8)
        #expect(CapsuleStore.humaneInstant(for: lastWeek, in: timeZone, now: evening) == lastWeek)
    }

    /// The echo path shares the guard, because a store method that silently converts a
    /// caller's future instant into a past one is wrong whether or not a screen
    /// currently asks it to.
    @Test func anEchoForTodayIsNotMovedIntoThisMorning() throws {
        let evening = at(18)
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        store.setEcho(capsule, at: evening, now: evening)
        #expect(try #require(capsule.echoAt) >= evening)
    }
}

// MARK: - The empty state that answered a question nobody asked

@MainActor
struct FilterEmptyStateTests {

    /// The gallery shows a *search* empty state only when there is a query. The rule
    /// lives in one place so the view and this test cannot disagree about it.
    @Test func onlyAQueryMakesItASearchResult() {
        #expect(!GalleryFilter.Criteria(moods: [.calm]).describesASearch)
        #expect(!GalleryFilter.Criteria(sounds: ["rain"]).describesASearch)
        #expect(!GalleryFilter.Criteria(searchText: "   ").describesASearch,
                "whitespace is not a question")
        #expect(GalleryFilter.Criteria(searchText: "rain").describesASearch)
        #expect(GalleryFilter.Criteria(searchText: "rain", moods: [.calm]).describesASearch,
                "the words are the user's own and are part of what they asked")
    }

    /// A filter with nothing under it is still an *active* filter — which is what
    /// makes "Clear filters" the right offer, and what would make it wrong to render
    /// nothing at all.
    @Test func anEmptyResultFromAFilterIsStillAnActiveFilter() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.mood = .calm

        let criteria = GalleryFilter.Criteria(moods: [.joyful])
        #expect(GalleryFilter.apply([capsule], criteria).isEmpty)
        #expect(criteria.isActive)
        #expect(!criteria.describesASearch)
    }
}

// MARK: - Which "Coming up" cards lead anywhere

@MainActor
struct UpcomingCardTapTests {

    private func sealed(daysAhead: Double) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.sealUntil = Date.now.addingTimeInterval(daysAhead * 86_400)
        // Set, and not left nil: a reconstruction test is vacuous on a field whose
        // expected value is the default. Found by control mutation — zeroing
        // `timeZoneID` in `UpcomingResurfaces` kept this green.
        capsule.sealTimeZoneID = "Asia/Tokyo"
        try capsule.transition(to: .sealed)
        return capsule
    }

    private func echoing(daysAhead: Double) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.echoAt = Date.now.addingTimeInterval(daysAhead * 86_400)
        return capsule
    }

    /// An echo names a capsule whose content is already visible, so opening it is
    /// simply the thing the card is about. A seal's capsule is hidden until its date —
    /// tapping it could only ever arrive at the locked screen, which is an invitation
    /// to be told no.
    @Test func anEchoLeadsSomewhereAndASealDoesNot() throws {
        let seal = try sealed(daysAhead: 180)
        let echo = try echoing(daysAhead: 7)
        let upcoming = UpcomingResurfaces.nearest([seal, echo])

        #expect(upcoming.count == 2)
        for item in upcoming {
            let capsule = try #require([seal, echo].first { $0.id == item.capsuleID })
            switch item.kind {
            case .echo:
                #expect(capsule.isContentVisible(), "so there is something to open")
            case .seal:
                #expect(!capsule.isContentVisible(), "which is why its card stays inert")
            }
        }
    }

    /// The strip stays content-free whatever a card does: a countdown and a kind,
    /// never a note or a place (§4F).
    @Test func theStripCarriesNoContent() throws {
        let seal = try sealed(daysAhead: 180)
        seal.note = "a note to open on my birthday"
        let item = try #require(UpcomingResurfaces.nearest([seal]).first)
        #expect(item.capsuleID == seal.id)
        // `PlannedNotification` has no field a note could travel in — the guarantee is
        // structural, and this is what would notice if a field were ever added.
        #expect(item == PlannedNotification(capsuleID: seal.id, fireDate: item.fireDate,
                                            timeZoneID: seal.sealTimeZoneID, kind: .seal))
    }
}
