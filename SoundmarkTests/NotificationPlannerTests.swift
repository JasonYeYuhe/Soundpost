import Testing
import Foundation
@testable import Soundmark

/// Tests for the 64-nearest notification scheduling policy (docs/PROJECT.md §1e.1).
struct NotificationPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func planned(_ offset: TimeInterval) -> PlannedNotification {
        PlannedNotification(capsuleID: UUID(), fireDate: now.addingTimeInterval(offset), timeZoneID: nil)
    }

    @Test func systemLimitIs64() {
        #expect(NotificationPlanner.systemPendingLimit == 64)
    }

    @Test func excludesPastAndPresentDue() {
        let result = NotificationPlanner.plan(sealed: [planned(-100), planned(0), planned(100)], now: now)
        #expect(result.count == 1)
        #expect(result.first?.fireDate == now.addingTimeInterval(100))
    }

    @Test func sortsNearestFirst() {
        let result = NotificationPlanner.plan(sealed: [planned(300), planned(100), planned(200)], now: now)
        #expect(result.map(\.fireDate) == [100, 200, 300].map { now.addingTimeInterval($0) })
    }

    @Test func capsAtLimitKeepingNearest() {
        let items = (1...100).map { planned(TimeInterval($0) * 10) }
        let result = NotificationPlanner.plan(sealed: items, now: now)
        #expect(result.count == 64)
        #expect(result.first?.fireDate == now.addingTimeInterval(10))
        #expect(result.last?.fireDate == now.addingTimeInterval(640))
    }

    @Test func respectsCustomLimit() {
        let items = (1...10).map { planned(TimeInterval($0) * 10) }
        #expect(NotificationPlanner.plan(sealed: items, now: now, limit: 3).count == 3)
    }

    @Test func emptyInputYieldsEmptyPlan() {
        #expect(NotificationPlanner.plan(sealed: [], now: now).isEmpty)
    }

    @Test func preservesTimeZoneID() {
        let item = PlannedNotification(capsuleID: UUID(), fireDate: now.addingTimeInterval(100), timeZoneID: "Asia/Tokyo")
        #expect(NotificationPlanner.plan(sealed: [item], now: now).first?.timeZoneID == "Asia/Tokyo")
    }
}
