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

    /// What this capsule may show on `surface`, highest confidence first — each phrase
    /// with the identifier behind it, because the detail screen's chips are also
    /// gallery facets (§S3) and a facet must match on the stable identifier.
    ///
    /// Empty means "show nothing at all" — no header, no icon, no container, which is
    /// what keeps a ghost impossible (§4C).
    /// - Parameter rejecting: what this person has said was wrong (M18 §4A).
    ///   **No default.** A defaulted `.none` here is how a surface comes to keep
    ///   showing a label somebody dismissed — the same drift that let seven consumers
    ///   of `Soundprint.showable*` disagree about the vocabulary and the floor. A
    ///   caller with genuinely nothing to apply writes `rejecting: .none` and says
    ///   why.
    static func heard(
        for capsule: Capsule,
        on surface: Surface,
        rejecting: RejectionIndex,
        now: Date = .now,
        listening: Bool = SoundAnalysisPreferences.mayReveal
    ) -> [Soundprint.Showable] {
        guard listening else { return [] }
        guard capsule.isContentVisible(now: now) else { return [] }
        if surface == .card, hasNote(capsule) { return [] }
        return Soundprint(stored: capsule.soundprintRaw)?
            .showable(rejecting: rejecting.sounds(for: capsule.id)) ?? []
    }

    /// Which of this capsule's *stored* labels the person has dismissed — the
    /// question the "show them again" affordance is driven by (§S3).
    ///
    /// Deliberately **not** the phrases. Naming a dismissed label back to the reader
    /// would put the guess on the screen it was removed from, under a different
    /// heading; for someone who dismissed `crying_sobbing` that is worse than not
    /// having offered the correction at all. So the way back says only that there is
    /// one, and the labels themselves are gone.
    ///
    /// Only labels this capsule actually holds and could otherwise show count: a
    /// rejection whose label has since left the vocabulary, or dropped below today's
    /// floor, is nothing to restore.
    static func dismissedIdentifiers(
        for capsule: Capsule,
        rejecting: RejectionIndex,
        now: Date = .now,
        listening: Bool = SoundAnalysisPreferences.mayReveal
    ) -> Set<String> {
        guard listening, capsule.isContentVisible(now: now) else { return [] }
        // Asked with `.none` on purpose: the question is which of the labels this
        // capsule *could* show have been dismissed, so the rejections are the answer
        // being intersected rather than a filter to apply first.
        let stored = Set(Soundprint(stored: capsule.soundprintRaw)?
            .showableIdentifiers(rejecting: .none) ?? [])
        return stored.intersection(rejecting.rejectedIdentifiers(for: capsule.id))
    }

    /// Just the phrases, for a surface that renders a sentence rather than chips.
    static func phrases(
        for capsule: Capsule,
        on surface: Surface,
        rejecting: RejectionIndex,
        now: Date = .now,
        listening: Bool = SoundAnalysisPreferences.mayReveal
    ) -> [String] {
        heard(for: capsule, on: surface, rejecting: rejecting,
              now: now, listening: listening).map(\.phrase)
    }

    /// Trimmed, because `NotificationCopy.Digest.lead` trims before deciding a note
    /// counts and the two must not disagree about what "  " is.
    private static func hasNote(_ capsule: Capsule) -> Bool {
        guard let note = capsule.note?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !note.isEmpty
    }

    /// The attributed sentence for one capsule on one surface — every §4A rule and
    /// the copy, in a single call.
    ///
    /// Two surfaces render this line rather than chips: the gallery card, and, from
    /// M18 §4D, the resurface reveal. Neither should be assembling
    /// `sentence(for: phrases(for:on:))` by hand, because that is two decisions a
    /// screen can get half right — and the reveal is the screen that had no
    /// attribution at all until now.
    static func sentence(
        for capsule: Capsule,
        on surface: Surface,
        rejecting: RejectionIndex,
        now: Date = .now,
        listening: Bool = SoundAnalysisPreferences.mayReveal
    ) -> String? {
        sentence(for: phrases(for: capsule, on: surface, rejecting: rejecting,
                              now: now, listening: listening))
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
