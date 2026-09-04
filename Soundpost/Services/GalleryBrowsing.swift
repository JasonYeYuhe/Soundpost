import Foundation
import SwiftUI

/// Pure, **metadata-only** gallery filtering + search (M12 §S6/§4D). Reads note,
/// place name, mood, state and dates — NEVER `audioData` (the M9 gallery-memory
/// rule: faulting the blob per row would blow up memory).
///
/// Search is **visibility-aware** (§4D P1): a sealed-not-due capsule's note and
/// place are hidden on its card, so matching them would leak hidden words. They
/// are searched only for content-visible capsules; mood (shown even on locked
/// cards) is the always-searchable, non-sensitive field.
enum GalleryFilter {
    struct Criteria: Equatable {
        var searchText: String = ""
        var moods: Set<Mood> = []
        /// Restrict to the time-capsule lineage (sealed → resurfaced → opened).
        var sealedOnly: Bool = false
        /// Classifier identifiers a capsule must have been heard as — "show me the
        /// others that sounded like this" (M17 §S3).
        ///
        /// **A facet, not the search box.** Free text also matches notes and places,
        /// so searching "rain" surfaces a capsule whose note says rain and whose sound
        /// was a train. This says what it means, and it costs one field on a value
        /// type plus a set lookup inside the single walk `apply` already does.
        ///
        /// Identifiers rather than phrases: a phrase would tie the filter to the
        /// device's current language and would have to go through the word-boundary
        /// rules free-text search needs, which are exactly the fuzziness a facet must
        /// not have. Matches **any** of them; today the UI sets at most one, because
        /// the chip is the one the user tapped.
        var sounds: Set<String> = []

        var isActive: Bool {
            describesASearch || !moods.isEmpty || sealedOnly || !sounds.isEmpty
        }

        /// Whether the user actually asked a question in words.
        ///
        /// The gallery's empty state used to be `ContentUnavailableView.search(text:)`
        /// unconditionally, so a mood filter or a sound facet with nothing under it
        /// answered "no results for" a search nobody had run — and with an empty query
        /// it rendered a bare "No Results", naming no cause and offering no way out
        /// (M17 §S4). A filter with nothing under it is a filter that wants removing.
        ///
        /// A query alongside filters still counts: the words are the user's own and
        /// are part of what they asked.
        var describesASearch: Bool {
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `listening` is threaded rather than read inside `soundMatches`, for two
    /// reasons: this type documents itself as pure and metadata-only, and a
    /// `UserDefaults` read down there would be one hit per capsule per keystroke over
    /// the whole library. Every other M15 gate uses the same defaulted-parameter seam.
    ///
    /// - Parameter rejecting: what each capsule's owner has said was wrong (M18 §4A),
    ///   resolved once by the gallery and threaded for exactly the reasons above — a
    ///   store read down in `soundMatches` would be a fetch per capsule per keystroke.
    ///   **No default**, unlike `listening:`: search and the sound facet are two
    ///   separate paths through this file, and a default is how one of them comes to
    ///   be missed while the other is fixed (§4B).
    static func apply(_ capsules: [Capsule], _ criteria: Criteria,
                      rejecting: RejectionIndex, now: Date = .now,
                      listening: Bool = SoundAnalysisPreferences.mayReveal) -> [Capsule] {
        let query = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return capsules.filter {
            matches($0, criteria, query: query, rejecting: rejecting.sounds(for: $0.id),
                    now: now, listening: listening)
        }
    }

    static func matches(_ capsule: Capsule, _ criteria: Criteria, query: String,
                        rejecting: RejectedSounds, now: Date,
                        listening: Bool = SoundAnalysisPreferences.mayReveal) -> Bool {
        if !criteria.moods.isEmpty {
            guard let mood = capsule.mood, criteria.moods.contains(mood) else { return false }
        }
        if criteria.sealedOnly && !isSealedLineage(capsule) { return false }
        if !criteria.sounds.isEmpty && !soundFacetMatches(capsule, criteria.sounds,
                                                          rejecting: rejecting,
                                                          now: now, listening: listening) {
            return false
        }
        guard !query.isEmpty else { return true }
        return searchMatches(capsule, query: query, rejecting: rejecting,
                             now: now, listening: listening)
    }

    static func isSealedLineage(_ capsule: Capsule) -> Bool {
        switch capsule.state {
        case .sealed, .resurfaced, .opened: return true
        case .draft, .recording, .captured: return false
        }
    }

    static func searchMatches(_ capsule: Capsule, query: String, rejecting: RejectedSounds,
                              now: Date,
                              listening: Bool = SoundAnalysisPreferences.mayReveal) -> Bool {
        // Hidden words — only when the capsule's content is visible (§4D P1).
        if capsule.isContentVisible(now: now) {
            if capsule.note?.localizedCaseInsensitiveContains(query) == true { return true }
            if capsule.place?.name?.localizedCaseInsensitiveContains(query) == true { return true }
            // What the capsule *sounded* like is content too (M15 §S4): a sealed
            // capsule's sound is as hidden as its note, so this sits INSIDE the
            // visibility check. Searching "rain" must never reveal that an unopened
            // capsule is a rainy one.
            // Guarded on consent, not only on the erase having run. The erase is
            // what normally removes these, but it can lag — a merge arriving while
            // the app is backgrounded, or the erase itself failing, both of which the
            // app has shipped copy for. Until it catches up, an unguarded search would
            // surface a capsule *by the sound Soundpost heard* on a device where the
            // user has turned listening off, which is the promise in the Settings
            // footer, not a detail.
            //
            // And a label its owner has dismissed is not something to find them by.
            // M18 §5 names this as the surface that must never be dropped after the
            // correction ships: a rejection someone can make that search still ignores
            // is worse than no rejection at all — they said no, and the app went on
            // using it to answer questions about their own library.
            if listening, soundMatches(capsule, query: query, rejecting: rejecting) { return true }
        }
        // Non-sensitive, always searchable (mood label shows even on locked cards).
        if capsule.mood?.label.localizedCaseInsensitiveContains(query) == true { return true }
        return false
    }

    /// Whether this capsule was heard as any of `sounds`.
    ///
    /// Gated exactly as sound *search* is, and for the same two reasons rather than by
    /// analogy: consent, because the erase that removes these labels can lag or fail
    /// and the app ships copy about it; and visibility, because a sealed-not-due
    /// capsule's sound is as hidden as its note — a facet that returned one would
    /// reveal that an unopened capsule is a rainy one, which is the leak M15 §S4
    /// closed for the search box.
    ///
    /// Matched against **showable** identifiers, so a facet can never surface a
    /// capsule by a label the app declined to name (§4C).
    static func soundFacetMatches(_ capsule: Capsule, _ sounds: Set<String>,
                                  rejecting: RejectedSounds,
                                  now: Date, listening: Bool) -> Bool {
        guard listening, capsule.isContentVisible(now: now) else { return false }
        guard let soundprint = Soundprint(stored: capsule.soundprintRaw) else { return false }
        return soundprint.showableIdentifiers(rejecting: rejecting).contains { sounds.contains($0) }
    }

    /// Match a query against a capsule's soundprint.
    ///
    /// The query is matched against the **localized phrase** we actually showed the
    /// user ("birdsong"), not the raw classifier identifier (`bird_chirp_tweet`) —
    /// searching for what you were told is the only thing that makes sense, and it
    /// means search works in Japanese and Chinese without a second index.
    ///
    /// Identifier comparison is exact-token by construction: we look up each stored
    /// identifier's phrase rather than substring-matching the stored blob, so a
    /// search for "rain" can never hit a capsule labelled `train` (M15 §4E).
    static func soundMatches(_ capsule: Capsule, query: String,
                             rejecting: RejectedSounds) -> Bool {
        // The phrases this capsule could actually be *shown* by. Search and display
        // must agree: finding a capsule by a label it was never told about — one
        // below today's floor — is finding something on evidence the app withheld
        // (M17 §4C).
        guard let soundprint = Soundprint(stored: capsule.soundprintRaw) else { return false }
        return soundprint.showablePhrases(rejecting: rejecting)
            .contains { matches(phrase: $0, query: query) }
    }

    /// Match a query against a shown phrase, requiring the match to **begin a word**.
    ///
    /// A plain `contains` reintroduces at the copy level exactly the false positive
    /// that exact-token identifier matching prevents: the phrase for `train` is
    /// "a train", which *contains* "rain". Searching for rain would then surface every
    /// capsule of a passing train — wrong answers about someone's own memories.
    ///
    /// **The boundary rule applies to scripts that have boundaries.** It used to apply
    /// to everything, and the honest note here said so: in Japanese and Chinese it
    /// degraded to "prefix of the phrase", so さえずり found nothing against
    /// 鳥のさえずり and 流声 found nothing against 车流声. That is not a stricter rule
    /// for those languages, it is a broken one — on the feature 1.6.0 leads with.
    ///
    /// The trade it was protecting against does not exist there. `rain`/`train` is an
    /// orthographic accident of Latin script: a train is not a kind of rain. Checked
    /// against the actual shipped vocabulary, every containment among the 52 Japanese
    /// phrases is **morphological, and semantically right**:
    ///
    ///     雨 ⊂ 雨だれ, 雷雨     風 ⊂ 風に揺れる葉     猫 ⊂ 猫がのどを鳴らす音
    ///     虫 ⊂ 虫の音          笑い声 ⊂ 赤ちゃんの笑い声
    ///
    /// Searching 雨 and finding thunderstorms is the right answer, not a wrong one.
    /// So an ideographic query matches anywhere; a Latin one still has to begin a word.
    static func matches(phrase: String, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        if ScriptHeuristics.containsCJK(query) {
            return phrase.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var searchRange = phrase.startIndex..<phrase.endIndex
        while let found = phrase.range(of: query,
                                       options: [.caseInsensitive, .diacriticInsensitive],
                                       range: searchRange) {
            if found.lowerBound == phrase.startIndex { return true }
            let preceding = phrase[phrase.index(before: found.lowerBound)]
            if !preceding.isLetter && !preceding.isNumber { return true }
            guard found.lowerBound < phrase.endIndex else { break }
            searchRange = phrase.index(after: found.lowerBound)..<phrase.endIndex
        }
        return false
    }
}

/// **One gallery render's worth of work, done once** (M19 §4B).
///
/// The gallery needs three things from a body pass: the resolved rejections, the
/// filtered capsules, and those capsules bucketed into sections. Each is derived from
/// the one before it, and `ContentView` used to expose them as three computed
/// properties — which is how they came to be recomputed four times per pass and, in
/// the case of the index, **once per card**:
///
///     private var rejectionIndex: RejectionIndex { .index(among: rejections) }
///     private var displayed: [Capsule] { GalleryFilter.apply(capsules, …) }
///     …
///     if displayed.isEmpty { … }                                   // 1
///     ForEach(GallerySection.grouped(displayed)) { group in        // 2
///         ForEach(group.capsules) { capsule in
///             CapsuleCard(capsule: capsule, rejecting: rejectionIndex)   // per card
///     …
///     .animation(.spring, value: displayed.count)                  // 3
///
/// Nothing there is obviously wrong to read, which is the point: a computed property
/// looks like a stored one at every use site, and SwiftUI evaluates each use. M18 §4B
/// argued at length that resolution must happen "once, in the gallery, not per card",
/// M19 §4B promised a count to prove it, and in between the code did the opposite for
/// two milestones without a single test noticing — the fetch counters could not see
/// it, because a `@Query`-backed gallery performs no fetches at all.
///
/// So the pass is a value with stored properties. Held once and read as often as the
/// body likes, it cannot be recomputed by being read; and a call site that wanted the
/// per-card cost back would have to build a second pass inside the loop, which is
/// visible in a way `rejecting: rejectionIndex` was not.
struct GalleryPass {
    /// Resolved once. Handed to every card, every detail sheet and the filter itself.
    let rejecting: RejectionIndex
    /// The capsules that survived the criteria, newest-first as they arrived.
    let capsules: [Capsule]
    /// Those capsules bucketed for display.
    let sections: [(section: GallerySection, capsules: [Capsule])]
    /// This day's entries from earlier years (M19 §4D), or empty when a filter is
    /// active and the strip is not shown. Same terms as `upcoming` below.
    let almanac: [Almanac.Entry]
    /// The anticipation strip's items, or empty when a filter is active and the strip
    /// is not shown.
    ///
    /// Here for the same reason the index is: `upcoming` was a computed property read
    /// twice per body pass — once for `!upcoming.isEmpty` and once by the `ForEach`
    /// that renders it — and each read walked and sorted the whole library. Computing
    /// it under the same condition that decides whether it is shown means the
    /// filtered case pays nothing, which the computed property also did not manage:
    /// `!filterCriteria.isActive && !upcoming.isEmpty` evaluates left to right, so it
    /// was free while filtering and doubled while not.
    let upcoming: [PlannedNotification]

    var isEmpty: Bool { capsules.isEmpty }
    var count: Int { capsules.count }

    /// - Parameter rejections: the gallery's `@Query` rows, unresolved. Taken as rows
    ///   rather than as a `RejectionIndex` so that resolving them is *this* type's
    ///   job and happens exactly once — a caller that could pass an index could also
    ///   build one per card, which is the mistake being removed.
    static func make(
        capsules: [Capsule],
        rejections: [SoundRejection],
        criteria: GalleryFilter.Criteria,
        now: Date = .now,
        /// Threaded rather than left to `.current` inside `Almanac.entries`, for the
        /// reason that file spells out: what "the same day last year" means depends on
        /// the calendar, and a test that cannot choose one is testing the runner's
        /// locale.
        calendar: Calendar = .current,
        listening: Bool = SoundAnalysisPreferences.mayReveal
    ) -> GalleryPass {
        // An empty library resolves nothing. The gallery is not shown at all in that
        // case, and a person who has deleted every capsule can still have rejection
        // rows: walking them to build an index nothing will read is work the computed
        // properties this replaced did not do, because they sat in the `else` branch.
        guard !capsules.isEmpty else {
            return GalleryPass(rejecting: .none, capsules: [], sections: [],
                               almanac: [], upcoming: [])
        }
        let rejecting = SoundRejectionStore.index(among: rejections, now: now)
        let shown = GalleryFilter.apply(capsules, criteria, rejecting: rejecting,
                                        now: now, listening: listening)
        return GalleryPass(rejecting: rejecting, capsules: shown,
                           sections: GallerySection.grouped(shown, now: now),
                           // Both strips are computed under the condition that decides
                           // whether they render, so a filtered gallery pays for
                           // neither. `Almanac.entries` walks the whole library once.
                           almanac: criteria.isActive ? []
                                                      : Almanac.entries(among: capsules, now: now,
                                                                        calendar: calendar),
                           upcoming: criteria.isActive ? []
                                                       : UpcomingResurfaces.nearest(capsules, now: now))
    }
}

/// The gallery footer's "N capsules, M on this device" figure.
///
/// Extracted from `ContentView` for the same reason `sealSignature` was: it is an O(N)
/// walk evaluated on every gallery pass — `storageFooter` is a direct child of the
/// `LazyVStack`, not a lazily-built row — and a private computed property is not
/// something a test can put a number on. It is cheap (a `reduce` over stored doubles,
/// no allocation per element), and §4B-iii records the number rather than asserting
/// anything about how it feels.
enum GalleryStorage {
    /// The library's approximate size on disk, in bytes. 8 kB/s is the recorder's
    /// bitrate; this is a footer, not an accounting.
    static func byteCount(_ capsules: [Capsule]) -> Int64 {
        capsules.reduce(Int64(0)) { $0 + Int64($1.durationSeconds * 8_000) }
    }
}

/// Date-bucketed gallery sections (M12 §S6): "This month / Earlier this year /
/// Older". Grouping is over `createdAt` only (metadata), preserving input order
/// within a bucket (the gallery feeds capsules newest-first).
enum GallerySection: Int, CaseIterable, Identifiable {
    case thisMonth
    case earlierThisYear
    case older

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .thisMonth: "This month"
        case .earlierThisYear: "Earlier this year"
        case .older: "Older"
        }
    }

    static func section(for date: Date, now: Date = .now, calendar: Calendar = .current) -> GallerySection {
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return .earlierThisYear }
        return .older
    }

    /// Group capsules into ordered, non-empty sections, preserving order within each.
    static func grouped(
        _ capsules: [Capsule],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [(section: GallerySection, capsules: [Capsule])] {
        var buckets: [GallerySection: [Capsule]] = [:]
        for capsule in capsules {
            buckets[section(for: capsule.createdAt, now: now, calendar: calendar), default: []].append(capsule)
        }
        return allCases.compactMap { section in
            buckets[section].map { (section, $0) }
        }
    }
}
