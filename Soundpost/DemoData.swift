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
        let samples: [(mood: Mood, note: String, place: String?, duration: Double, daysAgo: Double)] = [
            (.calm, "Rain on the window this morning", "Home", 12, 0),
            (.joyful, "Kids laughing at the park", "Ueno Park", 8, 1),
            (.nostalgic, "The old train crossing bell", nil, 17, 3),
            (.tender, "Her humming in the kitchen", "Home", 22, 6),
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
            context.insert(capsule)
        }
        try? context.save()
    }
}
#endif
