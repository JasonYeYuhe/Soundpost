import Foundation

/// The one place that decides *when in the day* a seal or echo fires (M12 §S2).
///
/// The seal/echo pickers choose a *day* (`.date`-only), so without normalization
/// the stored fire instant inherits whatever time-of-day the capture happened —
/// a 2:47 AM recording resurfaces at 2:47 AM months later. That breaks "the
/// resurface moment": a memory should arrive at a humane hour. So every write
/// path runs the chosen day through `normalize`, pinning it to 09:00 local in the
/// intended zone (the capsule's `sealTimeZoneID` for seals, the device zone for
/// echoes). The stored value stays a wall-clock instant + IANA zone, so the M10
/// delivery contract (`SupabaseDeliveryBackend.wallClockString`) and the local
/// `NotificationScheduler.trigger` are unaffected — only the *input* is corrected.
enum SealClock {
    /// The humane local hour a sealed/echoing capsule resurfaces (09:00).
    static let humaneHour = 9

    /// The instant of `humaneHour:00:00` on the same calendar day as `date`,
    /// measured in `timeZone`. Idempotent: a date already at the humane hour maps
    /// to itself, so it is safe to apply repeatedly (write paths + the one-shot
    /// launch normalization). Falls back to the input if the calendar can't form
    /// the instant (it always can for gregorian + a valid zone).
    static func normalize(_ date: Date, in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            bySettingHour: humaneHour, minute: 0, second: 0, of: date
        ) ?? date
    }
}
