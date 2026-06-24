import Testing
import SwiftUI
@testable import Soundpost

/// The global card theme (M11 §2B(c)) and its lapse-safety: an applied theme
/// renders from the stored preference, never from entitlement (§4D).
@MainActor
struct ThemeTests {
    @Test func classicReproducesTheBaselineLook() {
        // The default/free base must look exactly like the pre-Pro card: no tint
        // wash, hairline stroke — so existing and lapsed users see no change.
        #expect(Theme.classic.tintWashOpacity == 0)
        #expect(Theme.classic.strokeWidth == 1)
    }

    @Test func everyThemeHasADistinctNonEmptyLabel() {
        for theme in Theme.allCases { #expect(!theme.label.isEmpty) }
        let labels = Theme.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test func resolvedDefaultsToClassic() {
        #expect(Theme.resolved(fromStored: nil) == .classic)
        #expect(Theme.resolved(fromStored: "") == .classic)
        #expect(Theme.resolved(fromStored: "not-a-theme") == .classic)
        #expect(Theme.resolved(fromStored: "graphite") == .graphite)
    }

    /// The cardinal lapse-safety rule for themes: a theme applied while Pro keeps
    /// rendering after a lapse. The render path resolves the *stored* value and
    /// never consults `isPro`; the gate only blocks newly *choosing* a locked one.
    @Test func appliedThemeRendersRegardlessOfEntitlement() {
        let stored = "graphite"                 // chosen while Pro
        let lapsed = ProGate(isPro: false)
        #expect(!lapsed.canUse(.graphite))      // can't newly choose it…
        #expect(Theme.resolved(fromStored: stored) == .graphite) // …but it still renders
    }
}
