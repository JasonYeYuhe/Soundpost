import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// Gallery browsability (§S6): metadata-only filtering/search, visibility-aware so
/// a locked capsule's hidden words never leak, plus date sectioning.
@Suite(.serialized)
@MainActor
struct GalleryBrowsingTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func capsule(
        _ state: CapsuleState,
        note: String? = nil,
        place: String? = nil,
        mood: Mood? = nil,
        sealUntil: Date? = nil,
        createdAt: Date? = nil
    ) -> Capsule {
        let c = Capsule(createdAt: createdAt ?? now.addingTimeInterval(-86_400))
        try? c.transition(to: .recording)
        try? c.transition(to: .captured)
        c.note = note
        c.place = place.map { Place(latitude: 0, longitude: 0, name: $0) }
        c.mood = mood
        switch state {
        case .draft, .recording, .captured:
            break
        case .sealed:
            c.sealUntil = sealUntil ?? now.addingTimeInterval(100 * 86_400)
            try? c.transition(to: .sealed)
        case .resurfaced:
            c.sealUntil = sealUntil ?? now.addingTimeInterval(-86_400)
            try? c.transition(to: .sealed)
            try? c.transition(to: .resurfaced)
        case .opened:
            c.sealUntil = sealUntil ?? now.addingTimeInterval(-86_400)
            try? c.transition(to: .sealed)
            try? c.transition(to: .resurfaced)
            try? c.transition(to: .opened)
        }
        return c
    }

    private func search(_ text: String, _ capsules: [Capsule]) -> [Capsule] {
        GalleryFilter.apply(capsules, .init(searchText: text), now: now)
    }

    // MARK: Visibility-aware search (the §4D P1 leak guard)

    @Test func lockedCapsulesHiddenNoteNeverAppearsInSearch() {
        let locked = capsule(.sealed, note: "secret rainstorm",
                             sealUntil: now.addingTimeInterval(100 * 86_400)) // not due → hidden
        let visible = capsule(.captured, note: "secret rainstorm")
        let results = search("rainstorm", [locked, visible])
        #expect(results.contains { $0.id == visible.id })
        #expect(!results.contains { $0.id == locked.id }) // hidden note must not leak
    }

    @Test func lockedCapsulesHiddenPlaceNeverAppearsInSearch() {
        let locked = capsule(.sealed, place: "Kyoto",
                             sealUntil: now.addingTimeInterval(100 * 86_400))
        #expect(search("Kyoto", [locked]).isEmpty)
    }

    @Test func dueSealedCapsuleIsSearchableByNote() {
        // Past its date → content-visible before the flip → its note is searchable.
        let due = capsule(.sealed, note: "ocean waves", sealUntil: now.addingTimeInterval(-60))
        #expect(search("ocean", [due]).contains { $0.id == due.id })
    }

    @Test func moodLabelIsSearchableEvenForLockedCapsules() {
        // Mood shows on locked cards → it is non-sensitive and always searchable.
        let locked = capsule(.sealed, note: "hidden", mood: .calm,
                             sealUntil: now.addingTimeInterval(100 * 86_400))
        #expect(search(Mood.calm.label, [locked]).contains { $0.id == locked.id })
        #expect(search("hidden", [locked]).isEmpty) // but the note still doesn't leak
    }

    // MARK: Filters

    @Test func moodFilterKeepsOnlyMatchingMoods() {
        let calm = capsule(.captured, mood: .calm)
        let joyful = capsule(.captured, mood: .joyful)
        let none = capsule(.captured, mood: nil)
        let out = GalleryFilter.apply([calm, joyful, none], .init(moods: [.calm]), now: now)
        #expect(out.map(\.id) == [calm.id])
    }

    @Test func sealedOnlyKeepsTheTimeCapsuleLineage() {
        let captured = capsule(.captured)
        let sealed = capsule(.sealed)
        let resurfaced = capsule(.resurfaced)
        let out = GalleryFilter.apply([captured, sealed, resurfaced], .init(sealedOnly: true), now: now)
        #expect(Set(out.map(\.id)) == [sealed.id, resurfaced.id])
    }

    @Test func emptyCriteriaKeepsEverything() {
        let all = [capsule(.captured), capsule(.sealed), capsule(.resurfaced)]
        #expect(GalleryFilter.apply(all, .init(), now: now).count == 3)
        #expect(GalleryFilter.Criteria().isActive == false)
    }

    // MARK: Metadata-only (the M9 gallery-memory rule)

    @Test func filteringRunsOnABlobFreeFetchWithoutFaultingAudio() throws {
        let store = try TestSupport.freshStore()
        let blob = Data(repeating: 0xCD, count: 1_500_000)
        let c = store.create()
        try store.markRecording(c)
        try store.markCaptured(c, audioFileName: "a.m4a", audioData: blob, durationSeconds: 8, waveformSamples: [0.2])
        c.note = "thunder"; c.mood = .energized
        try store.save()

        // Fetch exactly the gallery's read set — audioData is NOT requested.
        var descriptor = FetchDescriptor<Capsule>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.createdAt, \.waveformSamples, \.mood, \.note, \.state, \.sealUntil, \.echoAt, \.place]
        let rows = try store.context.fetch(descriptor)

        // The filter produces correct results from metadata alone.
        #expect(search("thunder", rows).count == 1)
        #expect(GalleryFilter.apply(rows, .init(moods: [.energized]), now: now).count == 1)
    }

    // MARK: Date sectioning

    @Test func groupsByThisMonthEarlierThisYearAndOlder() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let ref = cal.date(from: DateComponents(year: 2030, month: 7, day: 15))!
        let thisMonth = capsule(.captured, createdAt: cal.date(from: DateComponents(year: 2030, month: 7, day: 2))!)
        let earlier = capsule(.captured, createdAt: cal.date(from: DateComponents(year: 2030, month: 3, day: 10))!)
        let older = capsule(.captured, createdAt: cal.date(from: DateComponents(year: 2029, month: 12, day: 20))!)

        let groups = GallerySection.grouped([thisMonth, earlier, older], now: ref, calendar: cal)
        #expect(groups.map(\.section) == [.thisMonth, .earlierThisYear, .older])
        #expect(groups[0].capsules.map(\.id) == [thisMonth.id])
        #expect(groups[1].capsules.map(\.id) == [earlier.id])
        #expect(groups[2].capsules.map(\.id) == [older.id])
    }

    @Test func groupingOmitsEmptySections() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let ref = cal.date(from: DateComponents(year: 2030, month: 7, day: 15))!
        let onlyOlder = capsule(.captured, createdAt: cal.date(from: DateComponents(year: 2028, month: 1, day: 1))!)
        let groups = GallerySection.grouped([onlyOlder], now: ref, calendar: cal)
        #expect(groups.map(\.section) == [.older])
    }
}
