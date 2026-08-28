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

    /// What to do about a notification tap that is still waiting to be honoured.
    ///
    /// **`.wait` is the whole point of this type existing.** `handleDeepLink` used to
    /// clear `pendingDeepLinkCapsuleID` whether or not it had found the capsule, so a
    /// tap that arrived before the library did was consumed and lost. M17 §S4 made the
    /// pending id drain at cold launch — which is precisely the moment CloudKit is most
    /// likely not to have delivered that capsule yet — so the fix moved the failure
    /// closer to the case it was meant to repair rather than further from it.
    ///
    /// A link is therefore kept until it is *used*. It stops being pending when the
    /// capsule arrives and is opened, or when the user opens something themselves,
    /// which is the honest reading of "they have moved on".
    enum PendingLink: Equatable {
        /// The capsule is here. Open it, and consume the link.
        case open(UUID)
        /// Not here yet. Keep the link; a later import may still deliver it.
        case wait
        /// Nothing is pending.
        case none
    }

    static func pendingLink(_ id: UUID?, among identifiers: [UUID]) -> PendingLink {
        guard let id else { return .none }
        return identifiers.contains(id) ? .open(id) : .wait
    }
}
