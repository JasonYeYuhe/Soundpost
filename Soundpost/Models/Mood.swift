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
    /// User-facing label. Wrapped for localization (String Catalog) in M6.
    var label: String {
        switch self {
        case .calm: "Calm"
        case .joyful: "Joyful"
        case .tender: "Tender"
        case .melancholy: "Melancholy"
        case .anxious: "Anxious"
        case .nostalgic: "Nostalgic"
        case .energized: "Energized"
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
