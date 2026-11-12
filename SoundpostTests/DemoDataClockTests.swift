import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// The demo library's clock times (M23 §4G).
///
/// The 2026-09-16 store screenshots were captured at 1:36 AM, and every card in them read
/// "1:33 AM": `DemoData.seed` placed each sample at "now minus whole days", so the time of
/// day on the store page was whenever the script happened to run. Each sample now has a
/// fixed daytime time on its own day — and none may land after the moment of seeding,
/// because a recording from the future is a state the app cannot produce.
@MainActor
struct DemoDataClockTests {
    private func seeded(at now: Date) throws -> [Capsule] {
        let context = try LargeLibrary.makeStore()
        DemoData.seed(into: context, now: now)
        try context.save()
        return try context.fetch(FetchDescriptor<Capsule>())
    }

    private func today(_ hour: Int, _ minute: Int) throws -> Date {
        try #require(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now))
    }

    /// Seeded late at night, as the 1.9.0-era capture was: every card still reads as a
    /// daytime recording. (Seeded at noon, "now minus days" would pass this too — so the
    /// test seeds at 23:30.)
    @Test func everySampleWasRecordedInTheDaytime() throws {
        let now = try today(23, 30)
        let capsules = try seeded(at: now)
        #expect(capsules.count == 10)
        for capsule in capsules {
            let hour = Calendar.current.component(.hour, from: capsule.createdAt)
            #expect((7...19).contains(hour), "a demo capsule recorded at \(hour):xx")
            #expect(capsule.createdAt <= now)
        }
    }

    /// Seeded before this morning's samples would have happened: they move back to just
    /// before `now` rather than into the future, and the sealed one is still the newest.
    @Test func nothingIsRecordedAfterTheMomentOfSeeding() throws {
        let now = try today(1, 30)
        let capsules = try seeded(at: now)
        #expect(capsules.allSatisfy { $0.createdAt < now })
        let newest = try #require(capsules.max { $0.createdAt < $1.createdAt })
        #expect(newest.sealUntil != nil, "the sealed capsule no longer sorts to the top")
    }
}
