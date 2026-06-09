import SwiftUI

/// The emotional tone the user attaches to a captured sound.
///
/// Raw values are stable identifiers persisted by SwiftData — **do not rename**
/// them (add new cases instead). User-facing labels are localized in M6.
enum Mood: String, CaseIterable, Codable, Identifiable, Sendable {
    case calm
    case joyful
    case tender
    case melancholy
    case anxious
    case nostalgic
    case energized

    var id: String { rawValue }
}

extension Mood {
    /// User-facing, localized label. `String(localized:)` because this is read as
    /// a `String` (e.g. `Text(mood.label)`), which SwiftUI would not localize on
    /// its own — only string *literals* in `Text("…")` are auto-localized.
    var label: String {
        switch self {
        case .calm: String(localized: "Calm")
        case .joyful: String(localized: "Joyful")
        case .tender: String(localized: "Tender")
        case .melancholy: String(localized: "Melancholy")
        case .anxious: String(localized: "Anxious")
        case .nostalgic: String(localized: "Nostalgic")
        case .energized: String(localized: "Energized")
        }
    }

    /// SF Symbol shown on the capsule card.
    var symbolName: String {
        switch self {
        case .calm: "leaf"
        case .joyful: "sun.max"
        case .tender: "heart"
        case .melancholy: "cloud.rain"
        case .anxious: "wind"
        case .nostalgic: "moon.stars"
        case .energized: "bolt"
        }
    }

    /// Accent color used to tint the waveform card.
    var tint: Color {
        switch self {
        case .calm: .teal
        case .joyful: .yellow
        case .tender: .pink
        case .melancholy: .indigo
        case .anxious: .orange
        case .nostalgic: .purple
        case .energized: .green
        }
    }
}
