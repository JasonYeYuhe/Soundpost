#if DEBUG
import Foundation
import SwiftData

/// Debug-only sample data for screenshots/manual review. Used ONLY when the app
/// is launched with `-seedSampleData`, via a throwaway in-memory container — it
/// never touches the user's real store.
enum DemoData {
    @MainActor
    static let container: ModelContainer = {
        // **Is** the production schema, rather than a hand-kept copy of its entity
        // list (M18 §4H). A screenshot build that reaches Settings would otherwise
        // trap the moment the Listening toggle wrote a record for an entity this
        // container had never heard of — and the copy would fall behind silently, the
        // way every other list derived from `Schema([...])` by hand has.
        // **`cloudKitDatabase: .none` is load-bearing, and its absence was a live
        // data-loss-shaped bug.** `isStoredInMemoryOnly: true` sounds like it settles
        // the question and does not: the CloudKit parameter defaults to `.automatic`,
        // and because the app carries the iCloud entitlement SwiftData spins up a
        // mirroring delegate for this store too. So the "throwaway" demo library was
        // **exporting its six sample capsules into the real user's iCloud**, from
        // where the production container imported them straight back — one copy per
        // `-seedSampleData` launch, in their actual gallery, on every device.
        //
        // `SoundpostModelContainer` documents this exact trap on its own rung 2 and
        // fixes it there; this container never got the same line. Found 2026-08-31
        // by reading a device's store during an unrelated sync test, after twelve
        // demo capsules and a demo correction had reached a real account.
        let container = try! ModelContainer(
            for: SoundpostModelContainer.productionSchema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        )
        seed(into: container.mainContext)
        return container
    }()

    @MainActor
    static func seed(into context: ModelContext) {
        // Localized so screenshots read natively in every store locale.
        //
        // `sounds` are classifier identifiers, seeded so the demo library shows what
        // M17 made visible: a card renders "Soundpost heard …" only when it has no
        // note, so the fifth sample deliberately has none. Without that, a screenshot
        // build would show none of this milestone at all and would misrepresent the
        // app — the labels are the differentiator, and hiding them in the demo is the
        // same mistake M17 exists to fix, one layer out.
        //
        // A `nil` note is what the card treats as a silence for the guess to fill;
        // the phrases themselves are looked up at render time, so these stay correct
        // in every language.
        let samples: [(mood: Mood, note: String?, place: String?, duration: Double,
                       daysAgo: Double, sounds: [String])] = [
            (.calm, String(localized: "Rain on the window this morning"), String(localized: "Home"),
             12, 0, ["rain", "raindrop"]),
            (.joyful, String(localized: "Kids laughing at the park"), String(localized: "Ueno Park"),
             8, 1, ["laughter", "chatter"]),
            (.nostalgic, String(localized: "The old train crossing bell"), nil,
             17, 3, ["train"]),
            (.tender, String(localized: "Her humming in the kitchen"), String(localized: "Home"),
             22, 6, ["water_tap_faucet"]),
            // No note: the one card that shows what Soundpost heard.
            (.calm, nil, String(localized: "Home"), 9, 8, ["bird_chirp_tweet", "wind_rustling_leaves"]),
        ]
        for (index, sample) in samples.enumerated() {
            let capsule = Capsule(createdAt: Date(timeIntervalSinceNow: -sample.daysAgo * 86_400))
            capsule.audioFileName = "sample\(index).m4a"
            capsule.durationSeconds = sample.duration
            capsule.waveformSamples = (0..<56).map { i in
                // A pleasant pseudo-waveform (no RNG needed) so screenshots are stable.
                let base = abs(sin(Double(i) * 0.5 + Double(index)))
                let envelope = 0.4 + 0.6 * sin(Double(i) / 56.0 * .pi)
                return Float(0.2 + 0.8 * base * envelope)
            }
            capsule.mood = sample.mood
            capsule.note = sample.note
            // Descending confidences, so the order on screen is the order here.
            capsule.soundprintRaw = Soundprint(
                classifier: "version1",
                labels: sample.sounds.enumerated().map {
                    Soundprint.Label(identifier: $1, confidence: 0.88 - Double($0) * 0.15)
                }
            ).stored
            if let place = sample.place {
                capsule.place = Place(latitude: 35.7148, longitude: 139.7753, name: place)
            }
            try? capsule.transition(to: .recording)
            try? capsule.transition(to: .captured)
            if index == 1 {
                // One capsule with a pending echo so the bell badge shows in demos.
                capsule.echoAt = Date(timeIntervalSinceNow: 9 * 86_400)
            }
            context.insert(capsule)
        }

        // A sealed capsule so the locked card/detail state is visible in demos.
        // Newest so it sorts to the top of the gallery for screenshots.
        let sealed = Capsule(createdAt: Date(timeIntervalSinceNow: -1_800))
        sealed.audioFileName = "sample_sealed.m4a"
        sealed.durationSeconds = 14
        sealed.waveformSamples = (0..<56).map { i in Float(0.3 + 0.5 * abs(sin(Double(i) * 0.7))) }
        sealed.mood = .energized
        sealed.note = String(localized: "A note to open on my birthday")
        // Carried so the demo also covers the rule that matters most: a sealed-not-due
        // capsule shows NOTHING, note or sound, however much it holds (M17 §4A).
        sealed.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "crowd", confidence: 0.83)]
        ).stored
        try? sealed.transition(to: .recording)
        try? sealed.transition(to: .captured)
        sealed.sealUntil = Date(timeIntervalSinceNow: 200 * 86_400)
        sealed.sealTimeZoneID = TimeZone.current.identifier
        try? sealed.transition(to: .sealed)
        context.insert(sealed)

        try? context.save()
    }
}
#endif
