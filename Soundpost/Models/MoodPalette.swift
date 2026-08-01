import SwiftUI
import UIKit

/// A concrete sRGB colour a user picked for a mood (M14 §4C).
///
/// Stored **resolved**, so — like `ShareCardView`'s deterministic inks — an
/// exported card or video looks the same whatever the device's appearance was at
/// render time. Built-in mood colours are deliberately *not* `MoodColor`s: they
/// stay semantic SwiftUI colours so they keep adapting to light/dark exactly as
/// they always have.
struct MoodColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Parse `RRGGBB` (case-insensitive, `#` optional). `nil` for anything else, so
    /// a corrupted preference degrades to "no override" rather than to a wrong colour.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        String(format: "%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Flatten a picked `Color` to concrete sRGB. Resolved against a **fixed light**
    /// trait so what the user picks is what an exported card or video shows,
    /// whatever appearance the device happened to be in.
    init(_ color: Color) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            self.init(red: 0, green: 0, blue: 0)
            return
        }
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }

    /// Relative luminance (WCAG coefficients).
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// The same hue, nudged into a band that stays readable **both** as dark ink on
    /// the near-white share card and as a waveform on the video's dark ground
    /// (M14 §7). Applied on resolve rather than on save, so the picker preview, the
    /// cards and the video all show the identical colour — the user is never shown
    /// one colour and given another.
    var legible: MoodColor {
        let minimum = 0.10, maximum = 0.72
        let current = luminance
        guard current > 0 else { return MoodColor(red: minimum, green: minimum, blue: minimum) }
        if current > maximum {
            let scale = maximum / current
            return MoodColor(red: red * scale, green: green * scale, blue: blue * scale)
        }
        if current < minimum {
            let scale = minimum / current
            return MoodColor(red: red * scale, green: green * scale, blue: blue * scale)
        }
        return self
    }
}

/// The user's chosen colour for each mood, layered over the built-in palette
/// (M14 §4A/§4B).
///
/// **Pure and free of entitlement.** Resolving a colour never consults `isPro` —
/// that is precisely what makes a custom palette *lapse-safe*: a colour chosen
/// while Pro keeps rendering forever, and a lapse only takes away the ability to
/// *change* it (M11 §1.2/§4D, M14 §4D). It is the same contract `Theme` has, and
/// the deliberate opposite of `ProGate.echoWindow`, which seeds *new* captures and
/// so is read at capture-start instead.
///
/// Stored as one compact `UserDefaults` string (`calm=E4A11B;tender=FF2D55`) that
/// views observe via `@AppStorage`, mirroring `cardTheme`. Unknown moods and
/// unparseable colours are ignored, so the format is forwards-compatible and a
/// corrupted value can only ever mean "fall back to the defaults".
struct MoodPalette: Equatable, Sendable {
    /// The `UserDefaults` key views observe.
    static let storageKey = "moodPalette"

    private(set) var overrides: [Mood: MoodColor]

    init(overrides: [Mood: MoodColor] = [:]) {
        self.overrides = overrides
    }

    /// The palette as currently stored, for non-view code (the video renderer).
    /// Views should use `@AppStorage(MoodPalette.storageKey)` instead, so they
    /// repaint when it changes.
    static var current: MoodPalette {
        MoodPalette(stored: UserDefaults.standard.string(forKey: storageKey))
    }

    init(stored: String?) {
        var parsed: [Mood: MoodColor] = [:]
        for pair in (stored ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let mood = Mood(rawValue: String(parts[0])),
                  let colour = MoodColor(hex: String(parts[1])) else { continue }
            parsed[mood] = colour
        }
        self.overrides = parsed
    }

    /// Serialised form, key-sorted so the stored value is stable (no spurious
    /// `UserDefaults` writes, and a readable plist).
    var stored: String {
        overrides
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.hex)" }
            .joined(separator: ";")
    }

    var isEmpty: Bool { overrides.isEmpty }

    func hasOverride(for mood: Mood) -> Bool { overrides[mood] != nil }

    /// The colour to actually draw. Falls back to the mood's built-in (adaptive)
    /// tint, and to the app accent for a capsule with no mood at all.
    func tint(for mood: Mood?) -> Color {
        guard let mood else { return .accentColor }
        if let override = overrides[mood] { return override.legible.color }
        return mood.defaultTint
    }

    /// Remove an override (always allowed — resetting is never a Pro action, so no
    /// one can be stranded with a palette they cannot undo; M14 §4F).
    mutating func reset(_ mood: Mood) {
        overrides[mood] = nil
    }

    mutating func resetAll() {
        overrides.removeAll()
    }

    mutating func set(_ colour: MoodColor, for mood: Mood) {
        overrides[mood] = colour
    }
}
