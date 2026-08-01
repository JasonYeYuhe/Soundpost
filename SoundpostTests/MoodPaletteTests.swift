import Testing
import SwiftUI
import Foundation
@testable import Soundpost

/// The custom mood palette (M14 §4A–§4C) and — the point of the milestone — its
/// **lapse-safety**: a colour chosen while Pro keeps rendering forever, because
/// drawing reads the stored palette and never the entitlement.
struct MoodPaletteTests {

    // MARK: - MoodColor

    @Test func hexRoundTrips() throws {
        let colour = try #require(MoodColor(hex: "E4A11B"))
        #expect(colour.hex == "E4A11B")
        #expect(abs(colour.red - 228.0 / 255) < 0.001)
        #expect(abs(colour.green - 161.0 / 255) < 0.001)
        #expect(abs(colour.blue - 27.0 / 255) < 0.001)
    }

    @Test func hexParsingIsForgivingButNeverWrong() {
        #expect(MoodColor(hex: "#ff0000")?.hex == "FF0000")   // leading # and lower case
        #expect(MoodColor(hex: "  00FF00 ")?.hex == "00FF00") // padding
        // Anything else is nil — a corrupted preference must degrade to "no
        // override", never to some other colour.
        #expect(MoodColor(hex: "FFF") == nil)
        #expect(MoodColor(hex: "GGGGGG") == nil)
        #expect(MoodColor(hex: "") == nil)
        #expect(MoodColor(hex: "FF00FF00") == nil)
    }

    @Test func componentsAreClampedToUnitRange() {
        let colour = MoodColor(red: 2, green: -1, blue: 0.5)
        #expect(colour.red == 1)
        #expect(colour.green == 0)
        #expect(colour.blue == 0.5)
    }

    // MARK: - Legibility band (§7)

    @Test func aNearWhiteChoiceIsDarkenedEnoughToStayReadable() throws {
        let white = try #require(MoodColor(hex: "FFFFFF"))
        #expect(white.luminance > 0.72)
        #expect(white.legible.luminance <= 0.7201)
    }

    @Test func aNearBlackChoiceIsLiftedOffTheDarkGround() throws {
        let almostBlack = try #require(MoodColor(hex: "010101"))
        #expect(almostBlack.legible.luminance >= 0.0999)
    }

    @Test func aColourAlreadyInTheBandIsUntouched() throws {
        let teal = try #require(MoodColor(hex: "2FB0C7"))
        #expect(teal.luminance > 0.10 && teal.luminance < 0.72)
        #expect(teal.legible == teal)
    }

    @Test func pureBlackDoesNotDivideByZero() throws {
        let black = try #require(MoodColor(hex: "000000"))
        #expect(black.legible.luminance > 0)
        #expect(black.legible.red.isFinite)
    }

    // MARK: - Serialisation

    @Test func storedFormRoundTrips() throws {
        var palette = MoodPalette()
        palette.set(try #require(MoodColor(hex: "E4A11B")), for: .calm)
        palette.set(try #require(MoodColor(hex: "FF2D55")), for: .tender)

        let stored = palette.stored
        #expect(stored == "calm=E4A11B;tender=FF2D55")   // key-sorted, so stable
        #expect(MoodPalette(stored: stored) == palette)
    }

    @Test func garbageStorageDegradesToDefaultsRatherThanWrongColours() {
        for junk in ["", "nonsense", "calm", "calm=", "=E4A11B", "calm=ZZZZZZ", ";;;", "notamood=FF0000"] {
            #expect(MoodPalette(stored: junk).isEmpty, "\(junk.debugDescription) should parse to no overrides")
        }
        // A partially-valid string keeps only the parts it can trust.
        let mixed = MoodPalette(stored: "calm=E4A11B;tender=ZZZ;bogus=FF0000")
        #expect(mixed.overrides.count == 1)
        #expect(mixed.hasOverride(for: .calm))
        #expect(!mixed.hasOverride(for: .tender))
    }

    @Test func nilStorageIsAnEmptyPalette() {
        #expect(MoodPalette(stored: nil).isEmpty)
    }

    // MARK: - Resolution

    @Test func anOverriddenMoodResolvesToTheChosenColour() throws {
        var palette = MoodPalette()
        let chosen = try #require(MoodColor(hex: "3366CC"))
        palette.set(chosen, for: .calm)
        #expect(palette.tint(for: .calm) == chosen.legible.color)
    }

    @Test func anUnsetMoodKeepsItsAdaptiveBuiltInColour() {
        let palette = MoodPalette()
        // Identity with the semantic colour matters: the built-ins must keep
        // adapting to light/dark, which a flattened sRGB value would not.
        #expect(palette.tint(for: .melancholy) == Mood.melancholy.defaultTint)
        for mood in Mood.allCases {
            #expect(palette.tint(for: mood) == mood.defaultTint)
        }
    }

    @Test func aCapsuleWithNoMoodFallsBackToTheAccent() {
        #expect(MoodPalette().tint(for: nil) == Color.accentColor)
    }

    // MARK: - Reset is never a Pro action (§4F)

    @Test func resettingRemovesOnlyThatMood() throws {
        var palette = MoodPalette()
        palette.set(try #require(MoodColor(hex: "111111")), for: .calm)
        palette.set(try #require(MoodColor(hex: "222222")), for: .joyful)

        palette.reset(.calm)
        #expect(!palette.hasOverride(for: .calm))
        #expect(palette.hasOverride(for: .joyful))
        #expect(palette.tint(for: .calm) == Mood.calm.defaultTint)

        palette.resetAll()
        #expect(palette.isEmpty)
    }

    // MARK: - Lapse-safety (§4D) — the cardinal rule

    /// A custom colour is a **rendered preference**: it must keep rendering when the
    /// user is no longer Pro. Nothing in the resolution path takes a `ProGate`, and
    /// this pins that — if someone ever threads an entitlement into rendering, the
    /// signature change breaks here first.
    @Test func aChosenColourRendersIdenticallyWhenNoLongerPro() throws {
        var palette = MoodPalette()
        let chosen = try #require(MoodColor(hex: "8844EE"))
        palette.set(chosen, for: .nostalgic)

        let whileSubscribed = palette.tint(for: .nostalgic)
        // Simulate the lapse: the entitlement flips, the stored palette does not.
        let lapsed = ProGate(isPro: false)
        let afterLapse = MoodPalette(stored: palette.stored).tint(for: .nostalgic)

        #expect(afterLapse == whileSubscribed)
        // The only thing the lapse changes is whether they may pick a NEW colour.
        #expect(lapsed.canCustomiseMoodColours == false)
        #expect(ProGate(isPro: true).canCustomiseMoodColours == true)
    }

    /// The video renderer must honour the same stored palette (M13 §11 flagged this
    /// coupling explicitly), and equally must not consult the entitlement.
    @Test func theVideoRendererUsesTheStoredPaletteToo() throws {
        var palette = MoodPalette()
        palette.set(try #require(MoodColor(hex: "CC3311")), for: .anxious)

        let custom = VideoTint.resolved(from: .anxious, palette: palette)
        let expected = try #require(MoodColor(hex: "CC3311")).legible
        #expect(abs(custom.red - expected.red) < 0.001)
        #expect(abs(custom.green - expected.green) < 0.001)
        #expect(abs(custom.blue - expected.blue) < 0.001)

        // An un-overridden mood still resolves its semantic default to something real.
        let untouched = VideoTint.resolved(from: .calm, palette: palette)
        #expect(untouched.red >= 0 && untouched.red <= 1)
        #expect(untouched != custom)
    }
}
