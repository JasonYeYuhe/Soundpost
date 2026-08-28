import Foundation

/// Builds the title/body for a resurface or echo notification (M12 §S3/§4A).
///
/// Pure + localized, so the personalized-vs-generic decision is unit-testable in
/// isolation. Metadata only — it reads the one-line, place name, mood, and
/// created date, and **never** touches `audioData`. When `personalized` is on
/// (opt-in, default off — see `NotificationPreferences`) the body leads with the
/// user's own words; otherwise it stays the calm generic copy. If personalized is
/// on but the capsule has no note/place to lead with, it falls back to generic so
/// we never render an empty quote.
enum NotificationCopy {
    /// The metadata a notification needs about a capsule — never its audio.
    struct Digest: Equatable {
        let createdAt: Date
        let note: String?
        let placeName: String?
        let mood: Mood?
        /// What the on-device classifier heard, if anything (M15 §S5).
        var soundprint: Soundprint?

        /// Whose words the lead is, because the two are set differently.
        ///
        /// A note or a place goes in **quotation marks** — it is what the person wrote
        /// or tagged. A classifier label must not: «"rain" — tap to listen.» presents a
        /// machine's guess as the user's own sentence, on a lock screen, which is §4A
        /// rule 1 failing in the one place the user cannot ask a follow-up question.
        /// M17 codified that rule and left this surface alone; found by Codex in the
        /// M17 review.
        enum Lead: Equatable {
            /// The one line they wrote, or the place they chose to tag.
            case ownWords(String)
            /// What the classifier heard. Attributed, never quoted.
            case heard(String)

            var text: String {
                switch self {
                case .ownWords(let value), .heard(let value): value
                }
            }
        }

        /// The lead phrase for personalized copy: the user's one-line, else the
        /// place, else what it sounded like. Trimmed; nil when all are empty.
        ///
        /// The soundprint is deliberately **last**. The user's own words always win;
        /// a guess only ever fills the gap where the copy would otherwise have been
        /// generic. And because `lead` is consulted only when `personalized` is on,
        /// a sound label can never reach a lock screen the user opted out of.
        var lead: Lead? {
            if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                return .ownWords(note)
            }
            if let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                return .ownWords(place)
            }
            // The first *showable* phrase, not the first stored identifier. Asking
            // for `identifiers.first` and then looking it up meant a top label that
            // had left the vocabulary — or one below a floor that has since risen —
            // returned nil here and dropped the copy to generic, even when the
            // capsule had a perfectly good second label (M17 §4C).
            if let phrase = soundprint?.showablePhrases().first {
                return .heard(phrase)
            }
            return nil
        }
    }

    static func make(
        for item: PlannedNotification,
        digest: Digest?,
        personalized: Bool
    ) -> (title: String, body: String) {
        switch item.kind {
        case .seal:
            let title = String(localized: "A capsule has resurfaced")
            switch digest?.lead {
            case .ownWords(let words) where personalized:
                return (title, String(localized: "“\(words)” — tap to listen."))
            case .heard(let phrase) where personalized:
                // Attributed, and unquoted. The quotation marks are what made this a
                // claim about the user's own memory rather than about the recording.
                return (title, String(localized: "Soundpost heard \(phrase) — tap to listen."))
            default:
                return (title, String(localized: "Open Soundpost to hear this moment again."))
            }

        case .echo:
            let title = String(localized: "An echo from your past")
            let days = elapsedDays(from: digest?.createdAt ?? item.fireDate, to: item.fireDate)
            switch digest?.lead {
            case .ownWords(let words) where personalized:
                return (title, String(localized: "“\(words)” — \(days) days ago. Listen back."))
            case .heard(let phrase) where personalized:
                return (title, String(localized: "Soundpost heard \(phrase) — \(days) days ago. Listen back."))
            default:
                return (title, String(localized: "\(days) days ago, you captured this sound. Listen back."))
            }
        }
    }

    private static func elapsedDays(from start: Date, to end: Date) -> Int {
        max(1, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1)
    }
}
