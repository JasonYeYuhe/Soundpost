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

    static func apply(_ capsules: [Capsule], _ criteria: Criteria, now: Date = .now) -> [Capsule] {
        let query = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return capsules.filter { matches($0, criteria, query: query, now: now) }
    }

    static func matches(_ capsule: Capsule, _ criteria: Criteria, query: String, now: Date) -> Bool {
        if !criteria.moods.isEmpty {
            guard let mood = capsule.mood, criteria.moods.contains(mood) else { return false }
        }
        if criteria.sealedOnly && !isSealedLineage(capsule) { return false }
        guard !query.isEmpty else { return true }
        return searchMatches(capsule, query: query, now: now)
    }

    static func isSealedLineage(_ capsule: Capsule) -> Bool {
        switch capsule.state {
        case .sealed, .resurfaced, .opened: return true
        case .draft, .recording, .captured: return false
        }
    }

    static func searchMatches(_ capsule: Capsule, query: String, now: Date) -> Bool {
        // Hidden words — only when the capsule's content is visible (§4D P1).
        if capsule.isContentVisible(now: now) {
            if capsule.note?.localizedCaseInsensitiveContains(query) == true { return true }
            if capsule.place?.name?.localizedCaseInsensitiveContains(query) == true { return true }
            // What the capsule *sounded* like is content too (M15 §S4): a sealed
            // capsule's sound is as hidden as its note, so this sits INSIDE the
            // visibility check. Searching "rain" must never reveal that an unopened
            // capsule is a rainy one.
            if soundMatches(capsule, query: query) { return true }
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
        guard let soundprint = Soundprint(stored: capsule.soundprintRaw) else { return false }
        return soundprint.identifiers.contains { identifier in
            guard let phrase = SoundVocabulary.displayName(for: identifier) else { return false }
            return matches(phrase: phrase, query: query)
        }
    }

    /// Match a query against a shown phrase, requiring the match to **begin a word**.
    ///
    /// A plain `contains` reintroduces at the copy level exactly the false positive
    /// that exact-token identifier matching prevents: the phrase for `train` is
    /// "a train", which *contains* "rain". Searching for rain would then surface every
    /// capsule of a passing train — wrong answers about someone's own memories.
    ///
    /// Trade-off, stated honestly: this also means a query must start at a word, so in
    /// Japanese and Chinese — which have no spaces — matching is effectively
    /// "prefix of the phrase" rather than "anywhere inside it". Typing 车流 finds
    /// 车流声; typing 流声 does not. Predictable, and far better than confidently
    /// showing the wrong memory.
    static func matches(phrase: String, query: String) -> Bool {
        guard !query.isEmpty else { return false }
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
