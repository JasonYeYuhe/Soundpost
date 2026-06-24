import Foundation

/// Pure, testable mapping from "is the user Pro right now?" to concrete feature
/// limits (M11 §4C).
///
/// Views read a `ProGate` (never `StoreService.isPro` directly), so that:
///  1. the gating rules are unit-testable without StoreKit, and
///  2. there is exactly one audited place that answers "what does Pro change?".
///
/// **A `ProGate` only ever describes what a *new* Pro action may do.** It is never
/// consulted to revoke, hide, or invalidate already-created content — that
/// structural lapse-safety (M11 §1.2/§4D) is why a lapsed annual can never lock a
/// memory: nothing re-reads `isPro` over stored capsules, applied themes, or
/// exported files. The gate caps only the *start* of a new recording / export /
/// theme choice.
struct ProGate: Equatable, Sendable {
    let isPro: Bool

    init(isPro: Bool) {
        self.isPro = isPro
    }

    /// Free clips cap at 60s; Pro extends to 5 minutes. Read **at record-start**
    /// (M11 §4D): a clip recorded while Pro stays fully playable forever, even if
    /// Pro later lapses — this cap governs only the next recording.
    var maxRecordingDuration: TimeInterval { isPro ? 300 : 60 }

    /// Whether the export / share affordance is offered. Gating guards only
    /// *starting* an export; an already-exported file is the user's to keep.
    var canExport: Bool { isPro }

    /// Card themes the user may *choose*. Free keeps the base `.classic` look; Pro
    /// unlocks the full pack. An already-applied theme keeps rendering after a
    /// lapse because `CapsuleCard` renders the stored preference, never `isPro`
    /// (M11 §2B(c)/§4D).
    var availableThemes: [Theme] { isPro ? Theme.allCases : [.classic] }

    /// Whether `theme` may be selected under the current entitlement.
    func canUse(_ theme: Theme) -> Bool { availableThemes.contains(theme) }
}
