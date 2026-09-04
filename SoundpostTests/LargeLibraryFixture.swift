import Foundation
import SwiftData
@testable import Soundpost

/// A library big enough to measure (M19 §4B / S1).
///
/// **Nothing in this suite has ever seeded more than 48 of anything.** Every
/// performance claim the codebase makes — `RejectionIndex` built once per pass, one
/// scoped fetch per operation, filtering that walks the library once — has therefore
/// been an argument rather than a measurement. This is the instrument that changes
/// that, and M18 §11 named building it as that milestone's most likely follow-on.
///
/// **It must never reach CloudKit, and that is not automatic.**
/// `ModelConfiguration(isStoredInMemoryOnly: true)` reads as "a throwaway local
/// store" and is not: `cloudKitDatabase` defaults to `.automatic`, and with the
/// iCloud entitlement present SwiftData mirrors it. That defaulting is what exported
/// twelve fabricated capsules into a real person's iCloud on 2026-08-31 (`a3139db`).
/// A fixture that seeds *thousands* would be the same mistake at scale, so the
/// opt-out here is explicit and `DemoDataIsolationTests` guards the same shape
/// elsewhere.
enum LargeLibrary {

    /// A container of its own, opted out of CloudKit, holding nothing else.
    ///
    /// Not `TestSupport.container`: that one is shared by every suite, and seeding
    /// thousands of rows into it would make every other test slower and would make
    /// *this* measurement depend on what else happened to be in there.
    static func makeStore() throws -> ModelContext {
        let container = try ModelContainer(
            for: SoundpostModelContainer.productionSchema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    /// Deterministic, varied, and cheap to build.
    ///
    /// * **Deterministic** — a seeded generator rather than `random()`, so a failure
    ///   is reproducible and a growth ratio is not comparing two different shapes.
    /// * **Varied** — notes, moods, places and soundprints differ across the library,
    ///   because a filter over identical rows measures the wrong thing: every
    ///   predicate would short-circuit at the same branch.
    /// * **Cheap** — `waveformSamples` stays empty and `audioData` stays nil. They
    ///   are a transformable and an external-storage blob, they cost far more than
    ///   everything else here put together, and nothing being measured reads them.
    ///   (The gallery is forbidden from reading `audioData` at all — the M9
    ///   gallery-memory rule.)
    ///
    /// - Returns: the ids of every capsule seeded, in insertion order.
    @discardableResult
    static func seed(
        capsules count: Int,
        rejectingEvery nth: Int = 0,
        in context: ModelContext,
        now: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) throws -> [UUID] {
        var random = SplitMix64(seed: 0x5011_4D90_57AB_1E01)
        var ids: [UUID] = []
        ids.reserveCapacity(count)

        for index in 0..<count {
            let capsule = Capsule(createdAt: now.addingTimeInterval(-Double(index) * 3_600))
            try capsule.transition(to: .recording)
            try capsule.transition(to: .captured)
            capsule.durationSeconds = 8 + Double(index % 20)
            capsule.mood = Mood.allCases[index % Mood.allCases.count]
            // A third have no note, which is the branch the card's "guess fills a
            // silence" rule takes — so the filter walk exercises both sides.
            if index % 3 != 0 {
                capsule.note = "\(Self.notes[index % Self.notes.count]) \(index)"
            }
            if index % 4 != 0 {
                capsule.place = Place(latitude: 35.7, longitude: 139.7,
                                      name: Self.places[index % Self.places.count])
            }
            let vocabulary = Self.identifiers
            let first = vocabulary[Int(random.next() % UInt64(vocabulary.count))]
            let second = vocabulary[Int(random.next() % UInt64(vocabulary.count))]
            capsule.soundprintRaw = Soundprint(
                classifier: "version1",
                labels: [Soundprint.Label(identifier: first, confidence: 0.90),
                         Soundprint.Label(identifier: second, confidence: 0.55)]
            ).stored
            context.insert(capsule)
            ids.append(capsule.id)

            if nth > 0, index % nth == 0 {
                context.insert(SoundRejection(capsuleID: capsule.id, identifier: first,
                                              rejected: true,
                                              changedAt: now.addingTimeInterval(-Double(index))))
            }
        }
        try context.save()
        return ids
    }

    /// Real identifiers, so the vocabulary and floor lookups do the work they do in
    /// production rather than falling out early on an unknown label.
    private static let identifiers = [
        "rain", "raindrop", "wind_rustling_leaves", "bird_chirp_tweet", "train",
        "laughter", "water_tap_faucet", "typing", "crowd", "music",
    ]
    private static let notes = [
        "the storm broke", "she was humming", "the last train", "coffee and rain",
        "kids in the square", "wind in the pines",
    ]
    private static let places = ["Home", "Ueno Park", "Kyoto", "36-5, Shimizucho"]
}

/// A tiny deterministic generator.
///
/// `SystemRandomNumberGenerator` would make a failing growth ratio impossible to
/// reproduce, and would let two runs of the "same" fixture differ in how many
/// capsules match a filter — which is the one thing a growth comparison must hold
/// constant.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
