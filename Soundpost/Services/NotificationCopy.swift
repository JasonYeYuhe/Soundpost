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

        /// The lead phrase for personalized copy: the user's one-line, else the
        /// place. Trimmed; nil when both are empty.
        var lead: String? {
            if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                return note
            }
            if let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                return place
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
            if personalized, let lead = digest?.lead {
                return (title, String(localized: "“\(lead)” — tap to listen."))
            }
            return (title, String(localized: "Open Soundpost to hear this moment again."))

        case .echo:
            let title = String(localized: "An echo from your past")
            let days = elapsedDays(from: digest?.createdAt ?? item.fireDate, to: item.fireDate)
            if personalized, let lead = digest?.lead {
                return (title, String(localized: "“\(lead)” — \(days) days ago. Listen back."))
            }
            return (title, String(localized: "\(days) days ago, you captured this sound. Listen back."))
        }
    }

    private static func elapsedDays(from start: Date, to end: Date) -> Int {
        max(1, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1)
    }
}
