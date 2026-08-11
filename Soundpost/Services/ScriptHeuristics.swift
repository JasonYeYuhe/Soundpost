import Foundation

/// The one place that decides "is this CJK", for the three rules that need to branch
/// on it.
///
/// Three copies of this test had accumulated — the capture-suggestion join, the
/// summary writer's fact anchors, and gallery search — each written for its own case
/// and each subtly different. They are branching on the same fact and should agree
/// about it, because when they disagree the symptom is a feature that behaves one way
/// in Japanese and another way in Chinese for no reason anyone intended.
enum ScriptHeuristics {

    /// Ideographs and kana. **Punctuation is deliberately excluded**: this answers
    /// "is this text written in a script without word boundaries", and a full stop is
    /// no evidence either way.
    static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF66...0xFF9F,   // Halfwidth Katakana
             0x20000...0x3134F: // CJK Extension B–G
            return true
        default:
            return false
        }
    }

    /// Ideographs, kana, **and** CJK punctuation and fullwidth forms.
    ///
    /// The join rule needs this wider set: "朝の音、" ends in a character that is not
    /// an ideograph but absolutely does not want an ASCII space after it.
    static func isCJKOrCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation — 、。「」・
             0xFF01...0xFF60:   // Fullwidth forms — ，！？：
            return true
        default:
            return isIdeographic(scalar)
        }
    }

    /// Whether the string contains any ideograph or kana — i.e. whether it is written,
    /// even partly, in a script that does not separate words with spaces.
    static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains(where: isIdeographic)
    }
}
