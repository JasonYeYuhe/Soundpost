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

    // MARK: - M14 micro-levers
    //
    // These two are deliberately of OPPOSITE kinds, and keeping them adjacent is
    // the point — the contrast is the thing that is easy to get wrong (M14 §4D):
    //
    //  • a custom mood colour is a RENDERED PREFERENCE. It is lapse-safe: the
    //    palette keeps rendering forever because drawing reads the stored colours,
    //    never `isPro`. The gate below governs only the *editor*.
    //  • a custom echo window is a SEED FOR NEW CAPTURES. It is NOT lapse-safe in
    //    the same way: like `maxRecordingDuration` it is read at capture-start, so
    //    a lapsed user's *next* capture returns to the default window while every
    //    echo already scheduled on an existing capsule is untouched.

    /// Whether the user may *choose* custom mood colours. Never consulted when
    /// drawing — see `MoodPalette`.
    var canCustomiseMoodColours: Bool { isPro }

    /// The default surprise-echo window: a random day 7–30 days out (M8.5).
    static let defaultEchoWindow: ClosedRange<Int> = 7...30

    /// Bounds a custom window must stay inside: never today (which would defeat the
    /// surprise) and never so far out that it is really a seal.
    static let echoWindowBounds: ClosedRange<Int> = 1...365

    /// The window a **new** capture should draw its echo date from.
    ///
    /// Read at capture-start. A free or lapsed user always gets the default, whatever
    /// they may have stored while Pro — that is the deliberate asymmetry with the
    /// colour palette above.
    func echoWindow(preferred: ClosedRange<Int>?) -> ClosedRange<Int> {
        guard isPro, let preferred else { return Self.defaultEchoWindow }
        return Self.clampEchoWindow(preferred)
    }

    /// Pull a stored window into `echoWindowBounds`, keeping lower ≤ upper.
    static func clampEchoWindow(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
        let lower = min(max(range.lowerBound, echoWindowBounds.lowerBound), echoWindowBounds.upperBound)
        let upper = min(max(range.upperBound, lower), echoWindowBounds.upperBound)
        return lower...upper
    }
}
