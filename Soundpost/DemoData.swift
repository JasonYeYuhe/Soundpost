#if DEBUG
import Foundation
import SwiftData

/// Debug-only sample data for screenshots/manual review. Used ONLY when the app
/// is launched with `-seedSampleData`, via a throwaway in-memory container — it
/// never touches the user's real store.
enum DemoData {
    @MainActor
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: Capsule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        seed(into: container.mainContext)
        return container
    }()

    @MainActor
    static func seed(into context: ModelContext) {
        // Localized so screenshots read natively in every store locale.
        let samples: [(mood: Mood, note: String, place: String?, duration: Double, daysAgo: Double)] = [
            (.calm, String(localized: "Rain on the window this morning"), String(localized: "Home"), 12, 0),
            (.joyful, String(localized: "Kids laughing at the park"), String(localized: "Ueno Park"), 8, 1),
            (.nostalgic, String(localized: "The old train crossing bell"), nil, 17, 3),
            (.tender, String(localized: "Her humming in the kitchen"), String(localized: "Home"), 22, 6),
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
