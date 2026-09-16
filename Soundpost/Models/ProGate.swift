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

/// **Whether Soundpost Pro is being offered on this device at all** (1.9.0 review).
///
/// `ProGate` answers "what may this user do?". This answers the question it never
/// asked: "should this user be *shown* Pro?" — and the gap between the two is how
/// 1.9.0 was rejected.
///
/// Pro was built in M11 to ship dormant: the paywall and every entry point went out
/// in the binary, and the products were never completed in App Store Connect. So
/// `isPro` has been false for every user of every release since, and each Pro
/// affordance was a dead end — tap Export & share, meet a paywall with nothing on it
/// to buy. App Review found it under Guideline 2.1(b) ("references to subscriptions
/// … not submitted for review") and 3.1.2(c) (no Terms of Use link for a
/// subscription it could see). Both are the same fact: the app offered something it
/// did not sell.
///
/// ### The rule
///
/// A Pro affordance appears only when the user **can already use** the feature, or
/// **could actually buy** it. In this build nobody can buy it, so for everyone who
/// does not already own Pro — which is everyone — nothing appears.
///
/// ### Why a constant, and not "did the products load?"
///
/// The first version of this fix keyed on the loaded products, so the surfaces would
/// return by themselves once Pro was approved. Both halves of that were wrong:
///
/// - **Nothing returns by itself.** A first in-app purchase is only reviewed together
///   with a binary — the rejection says so ("submit the In-App Purchase products and
///   upload a new binary"). The release that launches Pro is a deliberate submission
///   either way, and it is where `isOnSaleInThisBuild` is flipped.
/// - **App Review runs in the sandbox, and it served the unsubmitted products.** Not a
///   worry — Apple's screenshot attached to the rejection shows the paywall on the
///   reviewer's iPad with "$1.99 / year" and "$7.99" and live Subscribe / Buy buttons,
///   while both products sat at `MISSING_METADATA`, never submitted
///   (`docs/evidence/1.9.0-build18-review-paywall.png`). Keying on loaded products would
///   have shipped this build into the same rejection. A build that must not offer Pro
///   cannot ask the store whether to.
///
/// Loaded products are still required on top of the constant: a paywall with nothing
/// on it is a dead end even in the release that sells Pro. And an owner keeps every
/// feature they have whatever either says, because `isPro` comes from
/// `Transaction.currentEntitlements`, not from this.
///
/// ### What it deliberately does not change
///
/// The limits. A free recording is still capped at 60 seconds, which is what the store
/// listing already says ("Capture up to a minute"). Export stays unavailable to free
/// users rather than becoming free — hiding the door is reversible, and giving the
/// feature away is not.
struct ProOffer: Equatable, Sendable {
    /// **Flip only in the release that submits the Pro products alongside its binary.**
    /// `ProOfferTests.proIsNotOnSaleInThisBuild` pins the value, so changing it is a
    /// decision two files have to agree on rather than a one-character accident.
    static let isOnSaleInThisBuild = false

    let gate: ProGate
    /// Pro is on sale in this build **and** at least one Pro product loaded from the
    /// App Store — there is something a person could actually buy.
    let isForSale: Bool

    init(gate: ProGate, productsLoaded: Bool, onSale: Bool = ProOffer.isOnSaleInThisBuild) {
        self.gate = gate
        self.isForSale = onSale && productsLoaded
    }

    /// A paywall may be opened at all. Only when there is something on it to buy: a
    /// paywall with nothing to buy is the dead end this type exists to remove.
    var mayOpenPaywall: Bool { isForSale }

    /// The Pro section in Settings — the Pro row, Restore Purchases, and the way into
    /// personalisation. An owner keeps it whether or not Pro is on sale; everyone else
    /// sees it only when it is.
    ///
    /// For an owner its row still opens `ProPaywallView`, deliberately: with Pro active
    /// that screen is the owner's hub (status and the theme picker), not a sale, so it
    /// is gated on owning Pro here rather than on `mayOpenPaywall`.
    var showsProSection: Bool { gate.isPro || isForSale }

    /// The way into "Make it yours". It lives in the Pro section, but undoing a choice
    /// is never gated (M14 §4F): someone with a colour or echo window left over from Pro
    /// they no longer have must still be able to reset it, whether or not Pro is on sale.
    func showsPersonalisation(hasChoicesToUndo: Bool) -> Bool {
        showsProSection || hasChoicesToUndo
    }

    /// The "record up to 5 minutes with Pro" upsells during capture. Only for someone
    /// who does not have it and could buy it.
    var upsellsLongerRecording: Bool { !gate.isPro && isForSale }

    /// What a free recording that ran into the 60-second cap says about it.
    ///
    /// The upsell used to be the only notice: "Reached the 60-second limit. Record up
    /// to 5 minutes with Pro." Hiding the upsell hid the first half with it, and a
    /// recording that simply stopped at 1:00 read as a broken one. The limit is a fact
    /// about the app whether or not anything is for sale, so it stays.
    func freeCapNotice(atCap: Bool) -> FreeCapNotice {
        guard atCap, !gate.isPro else { return .none }
        return isForSale ? .upsell : .limit
    }

    enum FreeCapNotice: Equatable, Sendable {
        case none
        /// "Reached the 60-second limit." — nothing to tap.
        case limit
        /// The same sentence, plus the way to five minutes.
        case upsell
    }
}
