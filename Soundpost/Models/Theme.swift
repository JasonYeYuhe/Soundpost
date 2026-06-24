import SwiftUI

/// A global card-appearance preference, layered over the per-mood tint
/// (M11 §2B(c)).
///
/// **Data model decision:** the active theme is a single app-wide `UserDefaults`
/// value (see `ThemeStore`, wired in S3), *not* a per-capsule field. This avoids a
/// CloudKit schema change, avoids clashing with the per-mood tint, and is
/// lapse-safe by construction: rendering reads the stored preference, never
/// `isPro`, so an applied theme keeps rendering after a Pro lapse (M11 §4D).
///
/// `.classic` is the free base — the card exactly as it shipped before Pro. The
/// remaining cases are the Pro theme pack, gated via `ProGate.availableThemes`.
/// The visual treatment is applied in `CapsuleCard` (S3); each case stays
/// legible in both light and dark because it adjusts only adaptive surfaces and
/// the mood tint, never the text color.
enum Theme: String, CaseIterable, Identifiable, Sendable {
    /// The free base look (per-mood tint over the secondary system background).
    case classic
    /// A mood-washed card: the tint bled gently into the surface.
    case tinted
    /// A crisp outlined card with a stronger tinted border.
    case outlined
    /// A flatter, calmer graphite surface that lets the waveform lead.
    case graphite

    var id: String { rawValue }

    /// Localized name shown in the theme picker (S3).
    var label: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .tinted: String(localized: "Tinted")
        case .outlined: String(localized: "Outlined")
        case .graphite: String(localized: "Graphite")
        }
    }
}
