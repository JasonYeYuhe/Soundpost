import SwiftUI
import StoreKit

/// The milestone review prompt (M12 §S5/§4G). Asks for an App Store rating only
/// after a *genuine positive moment* — the first resurface reveal the user opens —
/// and at most **once per app version**. Never on launch, never mid-capture.
///
/// Reuses the per-version cap pattern from `ggc读书:ReviewManager`, adapted to the
/// SwiftUI `RequestReviewAction`. The eligibility decision is split out (`claimPrompt`)
/// so it is unit-testable without a UI scene; presenting the system prompt is the
/// OS's call (it further rate-limits to a few per year).
@MainActor
enum ReviewPrompt {
    static let lastVersionKey = "review.lastPromptedVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Returns true at most **once per version**, marking the version as prompted
    /// the first time so the cap holds across relaunches (persisted to UserDefaults).
    static func claimPrompt(version: String) -> Bool {
        guard UserDefaults.standard.string(forKey: lastVersionKey) != version else { return false }
        UserDefaults.standard.set(version, forKey: lastVersionKey)
        return true
    }

    /// Request a review if eligible for the current app version. Call after a
    /// genuine resurface, once the reveal has been dismissed.
    static func requestIfEligible(_ action: RequestReviewAction) {
        if claimPrompt(version: currentVersion) { action() }
    }
}
