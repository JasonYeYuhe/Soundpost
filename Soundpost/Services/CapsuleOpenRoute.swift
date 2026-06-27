import Foundation

/// Where tapping a capsule should lead (M12 §S4/§4C). Every entry point — a
/// gallery card tap and a notification deep link — routes through this one
/// decision so a due capsule always opens as the deliberate **reveal**, never a
/// plain detail screen, while everything else navigates to detail as before.
///
/// Pure, so the routing rule is unit-testable in isolation. A `.sealed` capsule
/// whose date has passed is content-visible *before* the `.resurfaced` flip, so it
/// routes to the reveal too; a sealed-not-due capsule never can.
enum CapsuleOpenRoute: Equatable {
    case reveal
    case detail

    static func route(for capsule: Capsule, now: Date = .now) -> CapsuleOpenRoute {
        if capsule.state == .resurfaced || capsule.isDueToResurface(now: now) {
            return .reveal
        }
        return .detail
    }
}
