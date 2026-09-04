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
    /// Two halves, because neither is enough alone. The plan over a library **full of
    /// anniversaries** contains only seals and echoes — a behavioural check that an
    /// almanac entry never becomes a request. And `Almanac.swift` names no
    /// notification API at all, which is the structural half: a plan can only be
    /// checked for what it contains, and a `UNUserNotificationCenter.add` called
    /// directly from a strip would never appear in one.
    @Test func theAlmanacTakesNoNotificationSlots() throws {
        let context = try store()
        for year in 2015...2025 {
            for offset in 0..<8 {
                try capsule(date(year, 6, 15, hour: offset + 1), note: "\(year)-\(offset)", in: context)
            }
        }
        try context.save()
        let all = try context.fetch(FetchDescriptor<Capsule>())
        let today = date(2026, 6, 15)

        #expect(!Almanac.entries(among: all, now: today, calendar: calendar).isEmpty,
                "no anniversaries, so this proves nothing about what they cost")
        let plan = NotificationPlanner.plan(capsules: all, now: today)
        #expect(plan.allSatisfy { $0.kind == .seal || $0.kind == .echo },
                "the plan gained a kind that is not a promise the user made")
        #expect(plan.count <= NotificationPlanner.systemPendingLimit)
        // 88 capsules, every one an anniversary, none of them sealed or echoing:
        // the plan is empty and the almanac cost exactly nothing.
        #expect(all.count == 88 && plan.isEmpty)

        let raw = try #require(try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Soundpost/Services/Almanac.swift"),
            encoding: .utf8))
        // **Comments stripped first.** The guard is about what the file *does*, and
        // `Almanac`'s own doc comment explains at length which notification APIs it
        // deliberately does not touch — naming every one of them. Scanning the raw
        // text made the file fail for saying why it is correct, which is a guard that
        // punishes the documentation this project runs on.
        let code = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("static func entries"), "the comment stripper ate the code")
        for forbidden in ["UNUserNotification", "UNNotification", "NotificationPlanner",
                          "NotificationScheduler", "NotificationCoordinator"] {
            #expect(!code.contains(forbidden), """
                Almanac.swift names `\(forbidden)` in code. The almanac is a strip in \
                the gallery precisely so that it cannot compete with seals for the 64 \
                pending requests iOS allows.
                """)
        }
    }
}
