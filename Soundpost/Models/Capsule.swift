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
    ///
    /// From M9 this is a **legacy fallback**: `audioData` is the canonical store.
    /// Capsules captured before the file→Data backfill (docs/M9-DEVPLAN.md §S2)
    /// still read their clip through this until the backfill reclaims the file.
    var audioFileName: String?

    /// The recorded clip, held as an external-storage blob — SwiftData keeps it
    /// out of the row, and under CloudKit mirrors it as a `CKAsset` that faults
    /// lazily, so the gallery `@Query` never loads audio into memory (only
    /// `AudioPlayer` faults it at play time). **Canonical** audio store from M9
    /// on (docs/M9-DEVPLAN.md §A). Optional so the CloudKit-mirrored schema stays
    /// purely additive/legal; `nil` until captured or backfilled.
    @Attribute(.externalStorage) var audioData: Data?

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

    /// A gentle "echo": when set on a *captured* (unsealed) capsule, a local
    /// notification on this date reminds the user what this day sounded like.
    /// Unlike a seal it hides nothing — the capsule stays visible. Picked at
    /// random (user-editable) when a capsule is saved; cleared by sealing,
    /// which supersedes it. Optional so CloudKit mirroring stays legal.
    var echoAt: Date?

    /// IANA time-zone identifier captured at seal time (e.g. "Asia/Tokyo").
    /// Stored so far-future delivery can be recomputed correctly across DST and
    /// tz-rule changes — see docs/PROJECT.md §1e.5.
    var sealTimeZoneID: String?

    /// When the cloud-delivery server confirmed a far-future job for this sealed
    /// capsule (M10 §S3/§4D). `nil` until a signed-in device registers the job;
    /// once set (and synced to the user's other devices via M9 CloudKit), every
    /// device drops its **local** notification backstop and lets the server push
    /// own delivery — so exactly one notification fires per resurfacing. Cleared
    /// when the job is cancelled (unseal / resurface / re-seal). Optional + additive
    /// so the CloudKit-mirrored schema stays legal.
    var serverJobSyncedAt: Date?

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
        self.audioData = nil
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
