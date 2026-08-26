import Foundation

/// Which phrases a capsule may show, and where (M17 §4A).
///
/// This milestone puts a machine's guess onto a person's own keepsake, permanently,
/// in their own gallery. Rule 1 — *never tell someone their memory was something it
/// wasn't* — is the whole reason the plan's per-label correction was cut (§4B): a
/// rejection stored in the mutable, synced `soundprintRaw` string would be lost to
/// CloudKit's record-level last-writer-wins, exactly as the account-wide consent row
/// was (`ListeningConsentStore.set`). With correction deferred to M18, **these rules
/// are the only protection there is.** They are not styling, and they live here — a
/// pure function of a capsule, a surface, a clock and a consent flag — rather than
/// scattered across two view bodies where each surface would drift from the other.
///
/// Four gates, in order, and each one has already been argued somewhere else in this
/// codebase:
///
/// 1. **Consent.** The same gate search threads (`GalleryFilter.apply(listening:)`)
///    and for the same reason: the erase that normally removes these labels can lag
///    or fail, and the app ships user-facing copy about that. A rendering path that
///    skipped it would put the sound Soundpost heard on screen on a device where the
///    user turned listening off.
/// 2. **Visibility.** `isContentVisible(now:)`, the rule the card body, the search
///    index and M16's playback control already share. A sealed-not-due capsule's
///    sound is as hidden as its words.
/// 3. **The user's own words come first.** On a card the guess appears *only* when
///    there is no note: it fills a silence, it never competes. This is
///    `NotificationCopy.Digest.lead`'s precedence (note → place → soundprint) applied
///    to a second surface — an already-reviewed rule, reused rather than reinvented.
/// 4. **Showable, not merely stored** (§4C): in the vocabulary, and clearing today's
///    floor.
///
/// **Where this is deliberately not consulted:** the share card, the exported video,
/// and the user's note. `ShareCardView` takes a whole `Capsule`, so nothing structural
/// stops a future edit reading `soundprintRaw` there — `SoundprintNeverLeavesTheApp`
/// in the test suite is what stands in for that missing structure.
enum SoundprintDisplay {

    /// Where the phrases are being asked for. The surfaces differ in exactly one
    /// respect — whether the guess may appear beside the user's own line — so this is
    /// an enum of two rather than a `showsWhenNoteExists` flag that a caller could
    /// pass the wrong way round.
    enum Surface: Equatable {
        /// The detail screen. One capsule, room for a labelled section, and the guess
        /// sits *below* the note rather than beside it — so a note does not suppress
        /// it.
        case detail
        /// A gallery card. One line of room, in the place the note would occupy, so
        /// the guess appears only when there is no note to displace.
        case card
    }

    /// The phrases this capsule may show on `surface`, highest confidence first.
    /// Empty means "show nothing at all" — including no header, no icon and no
    /// container, which is what keeps a ghost impossible (§4C).
    static func phrases(
        for capsule: Capsule,
        on surface: Surface,
        now: Date = .now,
        listening: Bool = SoundAnalysisPreferences.isEnabled
    ) -> [String] {
        guard listening else { return [] }
        guard capsule.isContentVisible(now: now) else { return [] }
        if surface == .card, hasNote(capsule) { return [] }
        return Soundprint(stored: capsule.soundprintRaw)?.showablePhrases() ?? []
    }

    /// Trimmed, because `NotificationCopy.Digest.lead` trims before deciding a note
    /// counts and the two must not disagree about what "  " is.
    private static func hasNote(_ capsule: Capsule) -> Bool {
        guard let note = capsule.note?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !note.isEmpty
    }

    /// The attributed sentence: "Soundpost heard rain and leaves in the wind".
    ///
    /// **The attribution is in the copy, never in the layout.** A bare noun sitting
    /// where a caption goes reads as something the person wrote about their own
    /// memory; a sentence naming Soundpost reads as what it is, a guess by a machine.
    /// That is §4A rule 1, and it is the reason this returns a sentence rather than a
    /// list for the caller to arrange.
    ///
    /// It is also the accessibility label for a single phrase on the detail screen:
    /// VoiceOver can focus one chip out of its header's context, and a chip that
    /// announced only "rain" would have lost the attribution the sighted layout keeps.
    static func sentence(for phrases: [String]) -> String? {
        guard !phrases.isEmpty else { return nil }
        // `.list(type: .and)` rather than a hand-joined string: the conjunction and
        // the separators are the reader's, not English's — "rain and wind",
        // 「雨と風に揺れる葉」, “雨和风吹树叶”.
        return String(localized: "Soundpost heard \(phrases.formatted(.list(type: .and)))")
    }
}
