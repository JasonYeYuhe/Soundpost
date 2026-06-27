import Testing
import Foundation
@testable import Soundpost

/// The single open-capsule routing decision (§S4): a due/resurfaced capsule opens
/// as the reveal; everything else goes to detail. Crucially, a sealed-not-due
/// capsule must NEVER route to the reveal (it would expose hidden content early).
@Suite
struct CapsuleOpenRouteTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func capsule(_ state: CapsuleState, sealUntil: Date? = nil) -> Capsule {
        let c = Capsule(createdAt: now.addingTimeInterval(-100 * 86_400))
        try? c.transition(to: .recording)
        try? c.transition(to: .captured)
        switch state {
        case .draft, .recording, .captured:
            break
        case .sealed:
            c.sealUntil = sealUntil
            c.sealTimeZoneID = "Asia/Tokyo"
            try? c.transition(to: .sealed)
        case .resurfaced:
            c.sealUntil = sealUntil ?? now.addingTimeInterval(-86_400)
            try? c.transition(to: .sealed)
            try? c.transition(to: .resurfaced)
        case .opened:
            c.sealUntil = sealUntil ?? now.addingTimeInterval(-86_400)
            try? c.transition(to: .sealed)
            try? c.transition(to: .resurfaced)
            try? c.transition(to: .opened)
        }
        return c
    }

    @Test func dueSealedRoutesToReveal() {
        // A sealed capsule past its date is content-visible before the flip → reveal.
        let due = capsule(.sealed, sealUntil: now.addingTimeInterval(-60))
        #expect(CapsuleOpenRoute.route(for: due, now: now) == .reveal)
    }

    @Test func resurfacedRoutesToReveal() {
        #expect(CapsuleOpenRoute.route(for: capsule(.resurfaced), now: now) == .reveal)
    }

    @Test func sealedNotDueNeverRoutesToReveal() {
        // The leak guard: a still-sealed capsule must go to detail (its locked view),
        // never the reveal — which would show hidden content.
        let locked = capsule(.sealed, sealUntil: now.addingTimeInterval(100 * 86_400))
        #expect(CapsuleOpenRoute.route(for: locked, now: now) == .detail)
    }

    @Test func capturedAndOpenedRouteToDetail() {
        #expect(CapsuleOpenRoute.route(for: capsule(.captured), now: now) == .detail)
        #expect(CapsuleOpenRoute.route(for: capsule(.opened), now: now) == .detail)
    }
}
