import Testing
import Foundation
@testable import Soundpost

/// M17 §S3 — "find the others that sounded like this".
///
/// A facet, not the search box, and the difference is the point: free text also
/// matches notes and places, so "rain" surfaces a capsule whose note says rain and
/// whose sound was a train. The facet says what it means.
///
/// **This suite claims no UI coverage.** That tapping a chip on the detail screen
/// actually reaches `ContentView.findSimilar`, and what the gallery looks like
/// afterwards, was checked by hand in the simulator — this project has no UI-test
/// target.
@MainActor
struct SoundFacetTests {

    private func captured(_ labels: [(String, Double)], note: String? = nil) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = note
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: labels.map { Soundprint.Label(identifier: $0.0, confidence: $0.1) }
        ).stored
        return capsule
    }

    // MARK: What the facet finds

    @Test func theFacetFindsEveryCapsuleHeardAsThatSound() throws {
        let rainy = try captured([("rain", 0.91)])
        let alsoRainy = try captured([("wind", 0.80), ("rain", 0.62)])
        let windy = try captured([("wind", 0.88)])

        let found = GalleryFilter.apply([rainy, alsoRainy, windy],
                                        .init(sounds: ["rain"]), listening: true)
        #expect(found.count == 2)
        #expect(!found.contains { $0 === windy })
    }

    /// The reason this is a facet at all. `train`'s phrase is "a train", which
    /// *contains* "rain", and a note is free text: search answers a different question
    /// and is allowed to be generous, a facet is not.
    @Test func theFacetDoesNotMatchANoteOrANearbyWord() throws {
        let notedRain = try captured([("wind", 0.88)], note: "rain all afternoon")
        let train = try captured([("train", 0.88)])

        #expect(GalleryFilter.apply([notedRain, train], .init(sounds: ["rain"]), listening: true).isEmpty)
        // …while free-text search, deliberately, still finds the note.
        #expect(GalleryFilter.apply([notedRain, train], .init(searchText: "rain"), listening: true)
                    .contains { $0 === notedRain })
    }

    /// Identifiers, not phrases: matching on display text would tie a filter to the
    /// device's language and drag in the word-boundary rules search needs.
    @Test func theFacetMatchesOnTheIdentifierNotThePhrase() throws {
        // A label whose phrase is NOT its identifier, or the test cannot tell the two
        // apart: `rain`'s English phrase is the string "rain".
        let leaves = try captured([("wind_rustling_leaves", 0.91)])
        let phrase = try #require(SoundVocabulary.displayName(for: "wind_rustling_leaves"))
        #expect(phrase != "wind_rustling_leaves", "otherwise this test proves nothing")

        #expect(GalleryFilter.apply([leaves], .init(sounds: ["wind_rustling_leaves"]),
                                    listening: true).count == 1)
        #expect(GalleryFilter.apply([leaves], .init(sounds: [phrase]), listening: true).isEmpty)
    }

    @Test func severalSoundsMatchAnyOfThem() throws {
        let rainy = try captured([("rain", 0.91)])
        let windy = try captured([("wind", 0.88)])
        let neither = try captured([("laughter", 0.88)])

        let found = GalleryFilter.apply([rainy, windy, neither],
                                        .init(sounds: ["rain", "wind"]), listening: true)
        #expect(found.count == 2)
    }

    // MARK: The gates it inherits

    /// A sealed-not-due capsule's sound is as hidden as its note. A facet that
    /// returned one would reveal that an unopened capsule is a rainy one — the exact
    /// leak M15 §S4 closed for the search box.
    @Test func theFacetNeverRevealsASealedNotDueCapsule() throws {
        let sealed = try captured([("rain", 0.91)])
        sealed.sealUntil = Date.now.addingTimeInterval(86_400)
        try sealed.transition(to: .sealed)

        #expect(GalleryFilter.apply([sealed], .init(sounds: ["rain"]), listening: true).isEmpty)
    }

    @Test func theFacetIsSilentWithListeningOff() throws {
        let rainy = try captured([("rain", 0.91)])
        #expect(GalleryFilter.apply([rainy], .init(sounds: ["rain"]), listening: false).isEmpty)
    }

    /// A facet can only ever match a label the app was willing to name (§4C), so it
    /// cannot surface a capsule on evidence the user was never shown.
    @Test func theFacetCannotMatchALabelBelowItsFloor() throws {
        let weak = try captured([("waterfall", 0.35)])
        #expect(GalleryFilter.apply([weak], .init(sounds: ["waterfall"]), listening: true).isEmpty)

        let strong = try captured([("waterfall", 0.50)])
        #expect(GalleryFilter.apply([strong], .init(sounds: ["waterfall"]), listening: true).count == 1)
    }

    @Test func aNeverAnalysedCapsuleIsNeverFoundByAFacet() throws {
        let capsule = try captured([("rain", 0.91)])
        capsule.soundprintRaw = nil
        #expect(GalleryFilter.apply([capsule], .init(sounds: ["rain"]), listening: true).isEmpty)
    }

    // MARK: How it composes

    @Test func anEmptyFacetChangesNothing() throws {
        let rainy = try captured([("rain", 0.91)])
        let windy = try captured([("wind", 0.88)])
        #expect(GalleryFilter.apply([rainy, windy], .init(), listening: true).count == 2)
    }

    /// The facet narrows alongside the other criteria rather than replacing them, so a
    /// mood filter left on is still honoured.
    @Test func theFacetNarrowsWithTheOtherCriteria() throws {
        let calmRain = try captured([("rain", 0.91)])
        calmRain.mood = .calm
        let joyfulRain = try captured([("rain", 0.91)])
        joyfulRain.mood = .joyful
        // A capsule the MOOD filter alone would keep. Without it this test passes
        // identically against an implementation that ignores the facet entirely —
        // found by control mutation, not by reading it.
        let calmWind = try captured([("wind", 0.88)])
        calmWind.mood = .calm

        let found = GalleryFilter.apply([calmRain, joyfulRain, calmWind],
                                        .init(moods: [.calm], sounds: ["rain"]), listening: true)
        #expect(found.count == 1)
        #expect(found.first === calmRain)
    }

    /// The filter bar's "Clear filters" and its active-state colouring both read
    /// `isActive`, so a facet the user cannot see is a facet they cannot remove.
    @Test func aFacetCountsAsAnActiveFilter() {
        #expect(GalleryFilter.Criteria(sounds: ["rain"]).isActive)
        #expect(!GalleryFilter.Criteria().isActive)
    }

    // MARK: The chip the user tapped

    /// §S3's performance rule, as a property of the type rather than a comment: what a
    /// capsule offers to tap is derived from that capsule alone. Nothing enumerates
    /// the vocabulary or walks the library to build a facet list — the gallery already
    /// re-walks several times per body pass and `AudioPlayer` drives updates at 20 Hz
    /// while a capsule plays.
    @Test func theTappablePhrasesComeFromTheCapsuleAlone() throws {
        let capsule = try captured([("rain", 0.91), ("waterfall", 0.35), ("wind", 0.60)])
        let offered = SoundprintDisplay.heard(for: capsule, on: .detail, rejecting: .none, listening: true)

        #expect(offered.map(\.identifier) == ["rain", "wind"], "showable only, confidence order")
        #expect(offered.map(\.phrase) == ["rain", "wind"].compactMap { SoundVocabulary.displayName(for: $0) })
        #expect(offered.count < SoundVocabulary.allowedIdentifiers.count,
                "and it is this capsule's labels, not the vocabulary")
    }

    /// Tapping a phrase must produce a facet that finds the capsule you tapped it on —
    /// the identifier the chip carries and the identifier the filter matches are the
    /// same one, which is the whole join §S3 depends on.
    @Test func tappingAPhraseFindsTheCapsuleItCameFrom() throws {
        let capsule = try captured([("rain", 0.91)])
        let tapped = try #require(SoundprintDisplay.heard(for: capsule, on: .detail, rejecting: .none,
                                                          listening: true).first)
        #expect(GalleryFilter.apply([capsule], .init(sounds: [tapped.identifier]),
                                    listening: true).count == 1)
    }
}
