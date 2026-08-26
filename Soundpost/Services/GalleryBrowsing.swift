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

        var isActive: Bool {
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !moods.isEmpty
                || sealedOnly
        }
    }

    /// `listening` is threaded rather than read inside `soundMatches`, for two
    /// reasons: this type documents itself as pure and metadata-only, and a
    /// `UserDefaults` read down there would be one hit per capsule per keystroke over
    /// the whole library. Every other M15 gate uses the same defaulted-parameter seam.
    static func apply(_ capsules: [Capsule], _ criteria: Criteria, now: Date = .now,
                      listening: Bool = SoundAnalysisPreferences.isEnabled) -> [Capsule] {
        let query = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return capsules.filter { matches($0, criteria, query: query, now: now, listening: listening) }
    }

    static func matches(_ capsule: Capsule, _ criteria: Criteria, query: String, now: Date,
                        listening: Bool = SoundAnalysisPreferences.isEnabled) -> Bool {
        if !criteria.moods.isEmpty {
            guard let mood = capsule.mood, criteria.moods.contains(mood) else { return false }
        }
        if criteria.sealedOnly && !isSealedLineage(capsule) { return false }
        guard !query.isEmpty else { return true }
        return searchMatches(capsule, query: query, now: now, listening: listening)
    }

    static func isSealedLineage(_ capsule: Capsule) -> Bool {
        switch capsule.state {
        case .sealed, .resurfaced, .opened: return true
        case .draft, .recording, .captured: return false
        }
    }

    static func searchMatches(_ capsule: Capsule, query: String, now: Date,
                              listening: Bool = SoundAnalysisPreferences.isEnabled) -> Bool {
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
            if listening, soundMatches(capsule, query: query) { return true }
        }
        // Non-sensitive, always searchable (mood label shows even on locked cards).
        if capsule.mood?.label.localizedCaseInsensitiveContains(query) == true { return true }
        return false
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
    static func soundMatches(_ capsule: Capsule, query: String) -> Bool {
        // The phrases this capsule could actually be *shown* by. Search and display
        // must agree: finding a capsule by a label it was never told about — one
        // below today's floor — is finding something on evidence the app withheld
        // (M17 §4C).
        guard let soundprint = Soundprint(stored: capsule.soundprintRaw) else { return false }
        return soundprint.showablePhrases().contains { matches(phrase: $0, query: query) }
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
