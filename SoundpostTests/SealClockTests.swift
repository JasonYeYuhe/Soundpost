import Testing
import Foundation
@testable import Soundpost

/// The humane-hour normalization at the heart of §S2: a chosen *day* becomes a
/// 09:00-local instant in the intended zone, deterministically and idempotently.
@Suite
struct SealClockTests {
    private func comps(_ date: Date, in tz: TimeZone) -> DateComponents {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    @Test func normalizesToNineLocalKeepingTheDay() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tokyo
        let picked = cal.date(from: DateComponents(year: 2030, month: 3, day: 14, hour: 2, minute: 47))!
        let c = comps(SealClock.normalize(picked, in: tokyo), in: tokyo)
        #expect(c.year == 2030 && c.month == 3 && c.day == 14)
        #expect(c.hour == 9 && c.minute == 0 && c.second == 0)
    }

    @Test func isIdempotent() {
        let tz = TimeZone(identifier: "Europe/London")!
        let once = SealClock.normalize(Date(timeIntervalSince1970: 2_000_000_000), in: tz)
        let twice = SealClock.normalize(once, in: tz)
        #expect(once == twice)
    }

    @Test func respectsTheIntendedZoneNotTheDeviceZone() {
        // Same instant, two zones → two distinct 09:00-local instants.
        let instant = Date(timeIntervalSince1970: 2_000_000_000)
        let tokyo = SealClock.normalize(instant, in: TimeZone(identifier: "Asia/Tokyo")!)
        let la = SealClock.normalize(instant, in: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(tokyo != la)
        #expect(comps(tokyo, in: TimeZone(identifier: "Asia/Tokyo")!).hour == 9)
        #expect(comps(la, in: TimeZone(identifier: "America/Los_Angeles")!).hour == 9)
    }

    @Test func picksTheCalendarDayInTheGivenZoneAcrossMidnight() {
        // 23:33 UTC on a given day is still the *previous* day in Honolulu (UTC-10),
        // so the 09:00 instant must anchor on Honolulu's day.
        let lateUTC = Date(timeIntervalSince1970: 2_000_000_000 + 41_400)
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = honolulu
        #expect(cal.isDate(SealClock.normalize(lateUTC, in: honolulu), inSameDayAs: lateUTC))
        #expect(comps(SealClock.normalize(lateUTC, in: honolulu), in: honolulu).hour == 9)
    }
}
