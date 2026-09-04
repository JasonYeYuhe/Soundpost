import Foundation

/// **What this day sounded like in an earlier year** (M19 §4D).
///
/// A quiet strip in the gallery, present when there is something to show and absent
/// otherwise. Deliberately **not a notification**, for two reasons and the second is
/// the load-bearing one:
///
/// 1. A daily "here's your memory" push is an engagement loop wearing a keepsake's
///    clothes. This app has no counters and no streaks on purpose.
/// 2. **iOS keeps 64 pending requests and drops the rest silently.** Seals and echoes
///    already compete for exactly that window. A seal is a promise someone made to
///    themselves on a date they chose; an almanac entry is a nicety. A nicety that can
///    evict a promise is a defect, and with a large enough library it would.
///
/// So nothing in this file touches `UNUserNotificationCenter`, `NotificationPlanner`
/// or `NotificationScheduler`, and two tests keep it that way:
/// `theAlmanacNamesNoNotificationAPI` reads this file, and
/// `theAlmanacCannotEvictASealFromTheBudget` fills the 64 slots with seals and
/// requires the plan to be unchanged by a library full of anniversaries.
enum Almanac {

    /// One earlier year's capsule for today's date.
    struct Entry: Identifiable, Equatable {
        let capsule: Capsule
        /// Whole years, exact: month and day are equal by construction, so this is a
        /// subtraction rather than an estimate.
        let yearsAgo: Int
        var id: UUID { capsule.id }
    }

    /// The capsules created on **the same calendar day in an earlier year**.
    ///
    /// ### Why not "365 days ago"
    ///
    /// Because it is wrong across a leap year, and wrong in the direction that shows
    /// the user a date that is not the anniversary they would name. The rule is the
    /// same month and day in a strictly earlier year, read in the device's own
    /// calendar and time zone — the same honesty `SealClock` and
    /// `ResurfaceView.elapsedPhrase` already keep.
    ///
    /// A consequence worth stating rather than working around: **29 February matches
    /// only in leap years.** A capsule recorded on a leap day has an anniversary every
    /// four years, which is what that date means. Nudging it to the 28th to have
    /// something to show would be inventing a date the person did not record on.
    ///
    /// ### Why nothing is a fine answer
    ///
    /// For a young library most days match nothing, and the strip is then absent. The
    /// version that starts lying is the one that widens to "11 months ago" so it has
    /// something to render.
    ///
    /// - Parameter now: the day being asked about. Injected rather than read, so a
    ///   test can stand on a leap day without waiting four years.
    /// - Parameter limit: the strip is one horizontal row; three is what "Coming up"
    ///   shows and there is no reason for this to differ.
    /// - Returns: nearest year first — last year before five years ago, because the
    ///   nearer memory is the one the day is most likely to be about.
    static func entries(
        among capsules: [Capsule],
        now: Date = .now,
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> [Entry] {
        let today = calendar.dateComponents([.month, .day], from: now)
        guard let month = today.month, let day = today.day else { return [] }
        let matches = capsules.compactMap { capsule -> Entry? in
            let onDay = calendar.dateComponents([.month, .day], from: capsule.createdAt)
            guard onDay.month == month, onDay.day == day else { return nil }
            // **Never `madeYear < thisYear`, and never `thisYear - madeYear`.**
            //
            // `DateComponents.year` is the year *within an era*, and the Japanese
            // calendar — selectable in iOS Settings, in this app's second language —
            // has eras. A capsule from Heisei 30 read in Reiwa 8 gives `30 < 8`, which
            // is false, so the anniversary vanishes; and the subtraction gives −22.
            // Worse, the failure moves: on the day a new era begins, every Reiwa
            // recording disappears from the strip at once, because `year` becomes
            // larger than `thisYear` for all of them.
            //
            // `compare(toGranularity:)` and `dateComponents(from:to:)` work on the
            // dates themselves, so they are right in every calendar the user can pick.
            //
            // Both ends anchored to the same time of day, because
            // `dateComponents(from:to:)` counts whole years by the **clock**, not the
            // date: a capsule made at 20:00 two years ago, read at noon, is two years
            // minus eight hours and comes back as 1. The month and day are already
            // equal here, so once the time of day is identical the difference is exact.
            //
            // **Noon, not `startOfDay`.** Midnight does not exist everywhere on every
            // day: where DST begins at midnight the clocks go from 23:59:59 to
            // 01:00:00, and `startOfDay` returns 01:00 for that date. Chile does this
            // today, Brazil did until 2019. A capsule recorded on such a day anchors to
            // 01:00 while an ordinary anniversary anchors to 00:00 — a year *minus* an
            // hour, which truncates to zero, and the `yearsAgo > 0` guard below then
            // drops the anniversary entirely. Noon exists in every zone on every day.
            //
            // The `?? capsule.createdAt` fallbacks are unreachable for noon and are
            // there because `date(bySettingHour:)` is optional, not because a zone
            // without a midday is expected.
            let made = calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                     of: capsule.createdAt) ?? capsule.createdAt
            let today = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
            guard calendar.compare(made, to: today, toGranularity: .year) == .orderedAscending,
                  let yearsAgo = calendar.dateComponents([.year], from: made, to: today).year,
                  yearsAgo > 0 else { return nil }
            // A sealed-not-due capsule never appears. Its sound is as hidden as its
            // words, and an anniversary is not an exception to that — it would be the
            // one surface that tells you what is inside a capsule you asked to wait
            // for (`isContentVisible`, the rule the card body, search and playback
            // already share).
            guard capsule.isContentVisible(now: now) else { return nil }
            return Entry(capsule: capsule, yearsAgo: yearsAgo)
        }
        return Array(
            matches
                .sorted {
                    if $0.yearsAgo != $1.yearsAgo { return $0.yearsAgo < $1.yearsAgo }
                    // Stable within a year: newest first, as the gallery orders.
                    return $0.capsule.createdAt > $1.capsule.createdAt
                }
                .prefix(max(0, limit))
        )
    }

    /// The one line an almanac card shows under its year.
    ///
    /// **The precedence is the gallery card's, not a new one.** The user's own words
    /// come first; the machine's guess fills a silence and never competes with them.
    /// That rule lives in `SoundprintDisplay.Surface.card`, which returns nothing when
    /// a note exists, so asking it and falling back to the note is the same decision
    /// the card makes rather than a second copy of it.
    ///
    /// Consent, standing, visibility and corrections all come for free with that call
    /// — which is the reason this is a function here rather than an `if let note`
    /// inside a `ViewBuilder`. A strip that assembled its own line would be the eighth
    /// consumer of `Soundprint` to drift from the other seven, and this one renders on
    /// the home screen of the app.
    ///
    /// Returns the two cases separately rather than a `String` because they are not
    /// the same kind of sentence and must not be styled as one: a note is something a
    /// person wrote, and a heard line is a machine's guess that says so in its own
    /// words. Collapsing them here would move that distinction into a view body, which
    /// is where §4A rule 1 gets lost.
    static func line(
        for entry: Entry,
        rejecting: RejectionIndex,
        now: Date = .now,
        listening: Bool = SoundAnalysisPreferences.mayReveal
    ) -> Line? {
        if let note = entry.capsule.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            return .note(note)
        }
        return SoundprintDisplay.sentence(for: entry.capsule, on: .card, rejecting: rejecting,
                                          now: now, listening: listening).map(Line.heard)
    }

    /// What an almanac card has to say, and who is saying it.
    enum Line: Equatable {
        /// The person's own words.
        case note(String)
        /// Soundpost's guess, already carrying its attribution in the copy.
        case heard(String)
    }
}
