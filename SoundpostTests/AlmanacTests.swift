import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M19 §4D / S3 — the acoustic almanac.
@Suite(.serialized)
struct AlmanacTests {

    /// A fixed calendar, because "the same calendar day" is a question about a
    /// calendar and the answer changes with the device's. UTC so a machine in Tokyo
    /// and one in London agree about which day a date falls on.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// A capsule that is content-visible, with an optional soundprint.
    @discardableResult
    private func capsule(_ createdAt: Date, note: String? = nil,
                         identifiers: [String] = [], in context: ModelContext) throws -> Capsule {
        let capsule = Capsule(createdAt: createdAt)
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = note
        if !identifiers.isEmpty {
            capsule.soundprintRaw = Soundprint(
                classifier: "version1",
                labels: identifiers.map { Soundprint.Label(identifier: $0, confidence: 0.9) }
            ).stored
        }
        context.insert(capsule)
        return capsule
    }

    private func store() throws -> ModelContext {
        try LargeLibrary.makeStore()
    }

    // MARK: What "a year ago today" means

    /// **The rule is the same calendar day, not a fixed number of days.**
    ///
    /// The two answers separate whenever a leap day falls *between* them, and the date
    /// has to be chosen to make that true — a first draft of this test used March, and
    /// 730 days before 2026-03-01 is exactly 2024-03-01, because Feb 29 2024 falls
    /// before both. January is where it shows: 2024-01-15 to 2026-01-15 spans the leap
    /// day, so it is 731 days, and 730 days back lands on the 16th. An almanac built
    /// on day arithmetic would show a capsule from the wrong day and call it an
    /// anniversary.
    @Test func anAnniversaryIsACalendarDayAndNotAFixedNumberOfDays() throws {
        let context = try store()
        let today = date(2026, 1, 15)
        let onTheDay = try capsule(date(2024, 1, 15), note: "the right one", in: context)
        // Exactly 730 days before today — the answer day arithmetic would give.
        let byDayCount = try capsule(today.addingTimeInterval(-730 * 86_400),
                                     note: "the wrong one", in: context)
        try context.save()

        // The premise, asserted before the behaviour: the two capsules really are
        // different days. Without this the test would pass over an implementation that
        // matched both, and over a fixture where they had collapsed to the same date.
        #expect(calendar.dateComponents([.month, .day], from: byDayCount.createdAt).day == 16)

        let entries = Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                      now: today, calendar: calendar)
        #expect(entries.map(\.capsule.id) == [onTheDay.id])
        #expect(entries.first?.yearsAgo == 2)
    }

    /// A leap-day capsule has an anniversary every four years, because that is what
    /// 29 February means. Nudging it to the 28th to have something to show would be
    /// inventing a date the person did not record on.
    @Test func aLeapDayCapsuleMatchesOnlyInLeapYears() throws {
        let context = try store()
        try capsule(date(2024, 2, 29), note: "leap", in: context)
        try context.save()
        let all = try context.fetch(FetchDescriptor<Capsule>())

        for near in [date(2025, 2, 28), date(2025, 3, 1), date(2026, 2, 28), date(2027, 3, 1)] {
            #expect(Almanac.entries(among: all, now: near, calendar: calendar).isEmpty,
                    "a near miss was offered as an anniversary")
        }
        let leapYear = Almanac.entries(among: all, now: date(2028, 2, 29), calendar: calendar)
        #expect(leapYear.count == 1)
        #expect(leapYear.first?.yearsAgo == 4)
    }

    /// Today is not an earlier year. A capsule recorded this morning is not an
    /// anniversary of itself.
    @Test func todayIsNotAnAnniversary() throws {
        let context = try store()
        try capsule(date(2026, 3, 1, hour: 9), note: "this morning", in: context)
        try context.save()
        #expect(Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                now: date(2026, 3, 1, hour: 21), calendar: calendar).isEmpty)
    }

    /// Nothing matching is a fine answer, and the common one for a young library.
    @Test func nothingMatchingIsAnEmptyResultAndNotANearMiss() throws {
        let context = try store()
        for day in [28, 27, 2, 3] { try capsule(date(2025, 2, day), in: context) }
        try capsule(date(2025, 3, 1), note: "one day out", in: context)
        try context.save()
        #expect(Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                now: date(2026, 2, 26), calendar: calendar).isEmpty)
    }

    @Test func entriesAreNearestYearFirstAndCapped() throws {
        let context = try store()
        for year in [2019, 2020, 2021, 2022, 2023] {
            try capsule(date(year, 6, 15), note: "\(year)", in: context)
        }
        try context.save()
        let entries = Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                      now: date(2026, 6, 15), calendar: calendar)
        #expect(entries.map(\.yearsAgo) == [3, 4, 5], "nearest year first, capped at three")
        #expect(Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                now: date(2026, 6, 15), calendar: calendar, limit: 0).isEmpty)
    }

    // MARK: The rules it inherits

    /// **A sealed-not-due capsule never appears.** An anniversary is not an exception
    /// to the rule that a sealed capsule's content is hidden — it would be the one
    /// surface that tells you what is inside a capsule you asked to wait for.
    @Test func aSealedCapsuleThatIsNotDueNeverAppears() throws {
        let context = try store()
        let sealed = Capsule(createdAt: date(2024, 7, 4))
        try sealed.transition(to: .recording)
        try sealed.transition(to: .captured)
        sealed.sealUntil = date(2030, 1, 1)
        sealed.sealTimeZoneID = "UTC"
        try sealed.transition(to: .sealed)
        context.insert(sealed)
        try context.save()
        let all = try context.fetch(FetchDescriptor<Capsule>())

        #expect(Almanac.entries(among: all, now: date(2026, 7, 4), calendar: calendar).isEmpty,
                "a sealed capsule's anniversary revealed it before its date")
        // And it does appear once it is due — so the emptiness above is the seal, not
        // the matching.
        #expect(Almanac.entries(among: all, now: date(2031, 7, 4), calendar: calendar).count == 1)
    }

    /// Consent, standing and corrections reach the strip through
    /// `SoundprintDisplay.sentence(on: .card)` rather than being re-decided here.
    @Test func theLineHonoursConsentAndCorrectionsAndPutsTheUsersWordsFirst() throws {
        let context = try store()
        try capsule(date(2024, 5, 5), identifiers: ["rain"], in: context)
        try context.save()
        let entry = try #require(Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                                 now: date(2026, 5, 5), calendar: calendar).first)

        let heard = Almanac.line(for: entry, rejecting: .none,
                                 now: date(2026, 5, 5), listening: true)
        // The premise: with everything permitting it, there IS a heard line — so the
        // three nils below are the rules working, not a capsule with nothing to say.
        #expect(heard != nil)
        if case .heard(let sentence)? = heard {
            #expect(sentence.contains("Soundpost"), "the line lost its attribution")
        } else {
            Issue.record("expected a heard line, got \(String(describing: heard))")
        }

        // Consent off: nothing heard is named.
        #expect(Almanac.line(for: entry, rejecting: .none,
                             now: date(2026, 5, 5), listening: false) == nil)

        // A correction: the one label this capsule has, dismissed.
        let rejected = RejectionIndex([entry.capsule.id: ["rain"]])
        #expect(Almanac.line(for: entry, rejecting: rejected,
                             now: date(2026, 5, 5), listening: true) == nil,
                "the strip named a label its owner had dismissed")

        // And the user's own words come first, as on a gallery card.
        entry.capsule.note = "  the porch  "
        #expect(Almanac.line(for: entry, rejecting: .none,
                             now: date(2026, 5, 5), listening: true) == .note("the porch"))
    }

    // MARK: The budget
    /// **The almanac takes no notification slots** (§4D reason 2).
    ///
    /// iOS keeps 64 pending requests and drops the rest silently, and seals and echoes
    /// already compete for that window. A seal is a promise someone made to themselves
    /// on a date they chose; an almanac entry is a nicety, and a nicety that can evict
    /// a promise is a defect.
    ///
    /// **The first version of this test was vacuous, and it is worth saying how.** It
    /// built 88 anniversary capsules — none sealed, none echoing — and asserted that
    /// the plan contained only seals and echoes and fitted in 64. The plan was the
    /// empty array. `allSatisfy` on nothing is true and `0 <= 64` is true, so both
    /// assertions passed over any implementation whatsoever, including one that put an
    /// almanac entry in every slot. The test even asserted `plan.isEmpty` itself and I
    /// did not read what that meant. A check that iterates an artefact cannot fail for
    /// what is missing from the artefact — the sentence this milestone has now written
    /// four times, in the test guarding its headline constraint.
    ///
    /// So the shape is a **baseline comparison at a full budget**: 70 sealed capsules,
    /// which the planner already caps to 64, and then the anniversaries added on top.
    /// If an almanac entry could take a slot, the second plan would differ — a
    /// different capsule, a different fire date, or the same 64 in a different order.
    /// Equality over the whole array is the assertion, not a count.
    @Test func theAlmanacCannotEvictASealFromTheBudget() throws {
        let context = try store()
        let today = date(2026, 6, 15)

        // 70 sealed capsules, all due in the future — more than the 64 iOS allows, so
        // the budget is genuinely full and eviction is a thing that could happen.
        var sealedIDs: [UUID] = []
        for index in 0..<70 {
            let capsule = Capsule(createdAt: date(2026, 1, 1, hour: 1))
            try capsule.transition(to: .recording)
            try capsule.transition(to: .captured)
            capsule.sealUntil = today.addingTimeInterval(Double(index + 1) * 86_400)
            capsule.sealTimeZoneID = "UTC"
            try capsule.transition(to: .sealed)
            context.insert(capsule)
            sealedIDs.append(capsule.id)
        }
        try context.save()
        let sealedOnly = try context.fetch(FetchDescriptor<Capsule>())
        let baseline = NotificationPlanner.plan(capsules: sealedOnly, now: today)

        // The premise: the budget is full. Without this the comparison below would
        // hold trivially for a library that never came close to the limit.
        #expect(baseline.count == NotificationPlanner.systemPendingLimit,
                "the budget is not full, so nothing could be evicted from it")
        #expect(baseline.allSatisfy { $0.kind == .seal })

        // Now 88 anniversaries of today, in eleven earlier years.
        var anniversaryIDs: Set<UUID> = []
        for year in 2015...2025 {
            for offset in 0..<8 {
                let made = try capsule(date(year, 6, 15, hour: offset + 1),
                                       note: "\(year)-\(offset)", in: context)
                anniversaryIDs.insert(made.id)
            }
        }
        try context.save()
        let everything = try context.fetch(FetchDescriptor<Capsule>())

        #expect(Almanac.entries(among: everything, now: today, calendar: calendar).count == 3,
                "no anniversaries, so this proves nothing about what they cost")

        let after = NotificationPlanner.plan(capsules: everything, now: today)
        #expect(after == baseline, """
            The plan changed when anniversaries were added to the library. 64 slots \
            were already spoken for by seals — promises someone made on dates they \
            chose — and something else took one.
            """)
        #expect(after.allSatisfy { !anniversaryIDs.contains($0.capsuleID) })
        #expect(Set(after.map(\.capsuleID)).isSubset(of: Set(sealedIDs)))
    }

    /// The structural half: a plan can only be checked for what it contains, and a
    /// `UNUserNotificationCenter.add` called straight from a strip would never appear
    /// in one.
    ///
    /// **The almanac's call sites, not only its policy.** The first version scanned
    /// `Almanac.swift` alone, which leaves the one place a notification would actually
    /// be scheduled from — the view that renders the strip — completely uncovered.
    /// `ContentView` legitimately holds a `NotificationCoordinator` from the
    /// environment and calls `sync` on scene changes, so that one name is allowed
    /// there and the other four are not; `GalleryBrowsing` names none of them and is
    /// held to the whole list.
    ///
    /// Comments are stripped first. `Almanac`'s own doc comment explains at length
    /// which notification APIs it deliberately does not touch, naming every one of
    /// them; scanning the raw text failed the file for saying why it is correct.
    ///
    /// **What this still cannot see**, said rather than implied: a notification
    /// scheduled through some future indirection that names none of these strings. No
    /// source scan closes that. What carries the weight is that the feature has no
    /// reason to schedule anything and no code path towards one — this only has to
    /// make adding a path visible.
    @Test func theAlmanacAndItsCallSitesNameNoNotificationAPI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let everything = ["UNUserNotification", "UNNotification", "UserNotifications",
                          "NotificationPlanner", "NotificationScheduler",
                          "NotificationCoordinator"]
        let files: [(path: String, forbidden: [String], proof: String)] = [
            ("Soundpost/Services/Almanac.swift", everything, "static func entries"),
            ("Soundpost/Services/GalleryBrowsing.swift", everything, "struct GalleryPass"),
            // Minus the coordinator, which this view legitimately holds for `sync`.
            ("Soundpost/ContentView.swift",
             everything.filter { $0 != "NotificationCoordinator" }, "almanacStrip"),
        ]
        for file in files {
            let raw = try #require(try? String(contentsOf: root.appending(path: file.path),
                                               encoding: .utf8),
                                   "\(file.path) is not where this guard expects it")
            let code = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(code.contains(file.proof),
                    "the comment stripper ate \(file.path), so nothing below means anything")
            for forbidden in file.forbidden {
                #expect(!code.contains(forbidden), """
                    \(file.path) names `\(forbidden)` in code. The almanac is a strip in \
                    the gallery precisely so that it cannot compete with seals for the \
                    64 pending requests iOS allows.
                    """)
            }
        }
    }

    // MARK: The calendar is the user's, not Gregorian

    /// **`DateComponents.year` is the year within an *era*.**
    ///
    /// The Japanese calendar is selectable in iOS Settings, in this app's second
    /// language. A first implementation compared `made.year < today.year` and
    /// subtracted them, which in that calendar reads Heisei 30 against Reiwa 8 as
    /// `30 < 8` — false — and drops the anniversary entirely. It is also a bug that
    /// *moves*: on the first day of a new era every Reiwa recording would vanish from
    /// the strip at once.
    @Test func anniversariesAreRightInACalendarWithEras() throws {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "UTC")!

        let context = try store()
        // 2018 is Heisei 30; 2026 is Reiwa 8. The era boundary falls between them.
        try capsule(date(2018, 6, 15), note: "Heisei", in: context)
        try capsule(date(2021, 6, 15), note: "Reiwa", in: context)
        try context.save()
        let all = try context.fetch(FetchDescriptor<Capsule>())

        // The premise: this calendar really does number years within an era, so the
        // test is not quietly running against a Gregorian one.
        #expect(japanese.dateComponents([.year], from: date(2018, 6, 15)).year == 30)
        #expect(japanese.dateComponents([.year], from: date(2026, 6, 15)).year == 8)

        let entries = Almanac.entries(among: all, now: date(2026, 6, 15), calendar: japanese)
        #expect(entries.map(\.yearsAgo) == [5, 8],
                "an era boundary swallowed an anniversary")
        // And the Gregorian answer is the same, because the question is about days.
        #expect(Almanac.entries(among: all, now: date(2026, 6, 15), calendar: calendar)
            .map(\.yearsAgo) == [5, 8])
    }

    /// **Midnight does not exist everywhere, on every day.**
    ///
    /// Where DST begins at midnight the clocks go straight from 23:59:59 to 01:00:00,
    /// and `startOfDay` returns 01:00 for that date. Chile does this today; Brazil did
    /// until 2019. Comparing an 01:00 anchor against a 00:00 one is a year minus an
    /// hour, and `dateComponents([.year], from:to:)` counts whole years by the clock —
    /// so the anniversary comes back as **zero years** and is dropped entirely by the
    /// `yearsAgo > 0` guard.
    @Test func anAnniversarySurvivesATimeZoneWhereMidnightDoesNotExist() throws {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!

        // **The direction matters, and a first draft of this test had it backwards.**
        // If the *viewing* day is the one with no midnight, its anchor is 01:00 against
        // the capsule's 00:00 — a year and an hour, which truncates to 1 and is right
        // by accident. The failing direction is the other one: the **capsule's** day
        // has no midnight, so its anchor is 01:00 against today's 00:00, which is a
        // year minus an hour and truncates to **zero**. The `yearsAgo > 0` guard then
        // drops the anniversary entirely.
        //
        // Chile starts DST on the first Sunday of September: 2023-09-03 has no
        // midnight, 2024-09-03 is an ordinary Tuesday.
        let missingMidnight = santiago.date(from: DateComponents(year: 2023, month: 9, day: 3, hour: 15))!
        let ordinaryDay = santiago.date(from: DateComponents(year: 2024, month: 9, day: 3, hour: 15))!

        // The premises: one day really has no midnight and the other really does.
        // Without both, this passes on a machine whose tz database disagrees and
        // proves nothing at all.
        #expect(santiago.component(.hour, from: santiago.startOfDay(for: missingMidnight)) == 1,
                "America/Santiago 2023-09-03 has a midnight after all — pick another date")
        #expect(santiago.component(.hour, from: santiago.startOfDay(for: ordinaryDay)) == 0)

        let context = try store()
        let capsule = Capsule(createdAt: missingMidnight)
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = "a year before a missing midnight"
        context.insert(capsule)
        try context.save()

        let entries = Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                      now: ordinaryDay, calendar: santiago)
        #expect(entries.map(\.yearsAgo) == [1],
                "the anniversary was dropped because its own day had no midnight")
    }

    /// Several capsules from the same earlier day: newest first, as the gallery
    /// orders. Unasserted ordering is ordering that changes silently.
    @Test func severalCapsulesFromOneEarlierDayComeNewestFirst() throws {
        let context = try store()
        let morning = try capsule(date(2024, 9, 9, hour: 7), note: "morning", in: context)
        let evening = try capsule(date(2024, 9, 9, hour: 20), note: "evening", in: context)
        let noon = try capsule(date(2024, 9, 9, hour: 12), note: "noon", in: context)
        try context.save()

        let entries = Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()),
                                      now: date(2026, 9, 9), calendar: calendar)
        #expect(entries.map(\.capsule.id) == [evening.id, noon.id, morning.id])
        #expect(entries.allSatisfy { $0.yearsAgo == 2 })
    }
}
