import Foundation

/// The user's chosen **surprise-echo window** — how far out a new capsule's echo
/// may land (M14 §4D/§4E).
///
/// This store is deliberately **entitlement-blind**: it only remembers what the
/// user picked. Whether that preference is *honoured* is `ProGate`'s decision, made
/// at capture-start via `ProGate.echoWindow(preferred:)`.
///
/// That split is the whole point of the milestone. An echo window is not like a
/// custom mood colour: a colour is a *rendered preference* and so keeps applying
/// after a lapse, whereas this only ever seeds a **new** capture — so a lapsed user
/// quietly returns to the default 7–30 days for their next recording, while every
/// echo already set on an existing capsule is left exactly as it is. Keeping the
/// preference stored (rather than erasing it on lapse) means resubscribing restores
/// their choice instead of silently losing it.
///
/// Backed by the app's own UserDefaults (PrivacyInfo CA92.1) — no new data, no
/// backend, no Required-Reason API.
enum EchoPreferences {
    static let lowerKey = "echo.window.lowerDays"
    static let upperKey = "echo.window.upperDays"

    /// The stored window, or `nil` when the user has never chosen one.
    ///
    /// Reads defensively: a half-written or nonsensical pair reads as "never chosen"
    /// so a corrupted preference can only ever fall back to the default, never
    /// produce an echo that fires today.
    static var storedWindow: ClosedRange<Int>? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: lowerKey) != nil,
                  defaults.object(forKey: upperKey) != nil else { return nil }
            let lower = defaults.integer(forKey: lowerKey)
            let upper = defaults.integer(forKey: upperKey)
            guard lower >= ProGate.echoWindowBounds.lowerBound, upper >= lower else { return nil }
            return ProGate.clampEchoWindow(lower...upper)
        }
        set {
            let defaults = UserDefaults.standard
            guard let newValue else {
                defaults.removeObject(forKey: lowerKey)
                defaults.removeObject(forKey: upperKey)
                return
            }
            let clamped = ProGate.clampEchoWindow(newValue)
            defaults.set(clamped.lowerBound, forKey: lowerKey)
            defaults.set(clamped.upperBound, forKey: upperKey)
        }
    }

    /// The window a new capture should actually use, given the entitlement now.
    static func effectiveWindow(gate: ProGate) -> ClosedRange<Int> {
        gate.echoWindow(preferred: storedWindow)
    }
}
