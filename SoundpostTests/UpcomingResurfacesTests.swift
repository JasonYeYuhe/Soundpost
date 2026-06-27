import Testing
import Foundation
@testable import Soundpost

/// The "next to resurface" anticipation data (§S8): nearest upcoming seals/echoes,
/// metadata-only, including server-owned seals (unlike the notification planner).
@Suite(.serialized)
@MainActor
struct UpcomingResurfacesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    private func sealed(_ offset: TimeInterval, synced: Bool = false) -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try? c.transition(to: .recording); try? c.transition(to: .captured)
        c.sealUntil = now.addingTimeInterval(offset)
        c.sealTimeZoneID = "Asia/Tokyo"
        try? c.transition(to: .sealed)
        if synced { c.serverJobSyncedAt = now }
        return c
    }

    private func echo(_ offset: TimeInterval) -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-day))
        try? c.transition(to: .recording); try? c.transition(to: .captured)
        c.echoAt = now.addingTimeInterval(offset)
        return c
    }

    @Test func returnsNearestFutureFirstAcrossKinds() {
        let items = UpcomingResurfaces.nearest(
            [sealed(50 * day), echo(2 * day), sealed(10 * day)], now: now)
        #expect(items.map(\.fireDate) == [now.addingTimeInterval(2 * day),
                                          now.addingTimeInterval(10 * day),
                                          now.addingTimeInterval(50 * day)])
        #expect(items.first?.kind == .echo)
    }

    @Test func excludesPastAndNonCandidates() {
        let pastSeal = sealed(-day)
        let pastEcho = echo(-day)
        let captured = Capsule(createdAt: now); try? captured.transition(to: .recording); try? captured.transition(to: .captured)
        #expect(UpcomingResurfaces.nearest([pastSeal, pastEcho, captured], now: now).isEmpty)
    }

    @Test func includesServerOwnedSeals() {
        // The strip shows anticipation regardless of who fires the notification —
        // a server-owned seal (which the notification planner drops) still appears.
        let owned = sealed(30 * day, synced: true)
        #expect(NotificationPlanner.plan(capsules: [owned], now: now).isEmpty) // planner drops it
        let items = UpcomingResurfaces.nearest([owned], now: now)
        #expect(items.count == 1 && items.first?.kind == .seal)
    }

    @Test func respectsTheLimit() {
        let many = (1...10).map { sealed(Double($0) * day) }
        #expect(UpcomingResurfaces.nearest(many, now: now, limit: 3).count == 3)
    }
}
