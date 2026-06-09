import Foundation
import SwiftData

/// A single sound memory: an audio clip plus the mood, place, and one line that
/// give it meaning — optionally sealed to resurface to your future self.
///
/// This is the core persisted entity. Its `state` is governed by
/// `CapsuleState`'s transition rules; always mutate it through `transition(to:)`
/// so illegal jumps throw rather than corrupting the lifecycle.
@Model
final class Capsule {
    /// Stable identity. Also used as the local-notification request identifier.
    ///
    /// NOT `@Attribute(.unique)`: CloudKit-mirrored SwiftData stores (planned
    /// for durability, see docs/DEVPLAN.md M9) forbid unique constraints, so
    /// uniqueness is guaranteed at the app layer (UUIDs by construction). Every
    /// stored property here is optional or carries a declaration default for the
    /// same reason — keep it that way so enabling CloudKit needs no scalar migration.
    var id: UUID = UUID()

    /// When the capsule was created.
    var createdAt: Date = Date.now

    /// Filename (relative to the audio store directory) of the recorded clip.
    /// Nil until recording is captured — populated in M2.
    var audioFileName: String?

    /// Clip length in seconds.
    var durationSeconds: Double = 0

    /// Normalized amplitude samples (0...1) used to draw the waveform card.
    /// Populated in M2; empty until then.
    var waveformSamples: [Float] = []

    /// Emotional tone chosen by the user. Optional until they pick one.
    var mood: Mood?

    /// One-line diary note.
    var note: String?

    /// Optional place stamp.
    var place: Place?

    /// If sealed, the moment the capsule should resurface. Nil when not sealed.
    var sealUntil: Date?

    /// IANA time-zone identifier captured at seal time (e.g. "Asia/Tokyo").
    /// Stored so far-future delivery can be recomputed correctly across DST and
    /// tz-rule changes — see docs/PROJECT.md §1e.5.
    var sealTimeZoneID: String?

    /// Current lifecycle state. Mutate via `transition(to:)`.
    private(set) var state: CapsuleState = CapsuleState.draft

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        state: CapsuleState = .draft
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFileName = nil
        self.durationSeconds = 0
        self.waveformSamples = []
        self.mood = nil
        self.note = nil
        self.place = nil
        self.sealUntil = nil
        self.sealTimeZoneID = nil
        self.state = state
    }
}

// MARK: - State machine

extension Capsule {
    /// Attempt a lifecycle transition, throwing if it isn't allowed.
    func transition(to next: CapsuleState) throws {
        guard state.canTransition(to: next) else {
            throw CapsuleStateError.illegalTransition(from: state, to: next)
        }
        state = next
    }

    /// Whether the capsule's content should currently be visible to the user.
    /// A sealed capsule stays hidden until its `sealUntil` instant passes.
    func isContentVisible(now: Date = .now) -> Bool {
        switch state {
        case .draft, .recording:
            false
        case .sealed:
            (sealUntil.map { now >= $0 }) ?? false
        case .captured, .resurfaced, .opened:
            true
        }
    }

    /// Whether a sealed capsule is now due to resurface.
    func isDueToResurface(now: Date = .now) -> Bool {
        guard state == .sealed, let sealUntil else { return false }
        return now >= sealUntil
    }
}
