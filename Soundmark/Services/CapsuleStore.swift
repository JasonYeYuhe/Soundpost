import Foundation
import SwiftData

/// Persistence + lifecycle operations over `Capsule`, on top of SwiftData.
///
/// Kept deliberately thin: SwiftData's `ModelContext` is the source of truth and
/// the UI (M3+) observes it via `@Query`. This type exists so the lifecycle
/// rules live in one place that can be unit-tested with an in-memory container.
@MainActor
final class CapsuleStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Create / read / delete

    @discardableResult
    func create(createdAt: Date = .now) -> Capsule {
        let capsule = Capsule(createdAt: createdAt)
        context.insert(capsule)
        return capsule
    }

    /// All capsules, newest first.
    func all() throws -> [Capsule] {
        try context.fetch(
            FetchDescriptor<Capsule>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
    }

    /// Capsules currently in the `.sealed` state.
    ///
    /// Filtered in memory rather than via `#Predicate` to avoid SwiftData's
    /// rough edges predicating on enum-typed properties; the local set is small.
    func sealedCapsules() throws -> [Capsule] {
        try all().filter { $0.state == .sealed }
    }

    func delete(_ capsule: Capsule) {
        context.delete(capsule)
    }

    func save() throws {
        if context.hasChanges { try context.save() }
    }

    // MARK: Lifecycle

    func markRecording(_ capsule: Capsule) throws {
        try capsule.transition(to: .recording)
    }

    /// Cancel an in-progress recording, returning to `.draft`.
    func cancelRecording(_ capsule: Capsule) throws {
        try capsule.transition(to: .draft)
    }

    /// Finalize a recording: attach the audio + waveform and move to `.captured`.
    func markCaptured(
        _ capsule: Capsule,
        audioFileName: String,
        durationSeconds: Double,
        waveformSamples: [Float]
    ) throws {
        capsule.audioFileName = audioFileName
        capsule.durationSeconds = durationSeconds
        capsule.waveformSamples = waveformSamples
        try capsule.transition(to: .captured)
    }

    /// Seal a captured capsule until `date`, stamping the time zone for correct
    /// far-future delivery (docs/PROJECT.md §1e.5).
    func seal(_ capsule: Capsule, until date: Date, timeZone: TimeZone = .current) throws {
        capsule.sealUntil = date
        capsule.sealTimeZoneID = timeZone.identifier
        try capsule.transition(to: .sealed)
    }

    /// Cancel a seal before its date, returning the capsule to `.captured`.
    func unseal(_ capsule: Capsule) throws {
        try capsule.transition(to: .captured)
        capsule.sealUntil = nil
        capsule.sealTimeZoneID = nil
    }

    func markResurfaced(_ capsule: Capsule) throws {
        try capsule.transition(to: .resurfaced)
    }

    func open(_ capsule: Capsule) throws {
        try capsule.transition(to: .opened)
    }

    /// Flip any sealed capsules whose date has passed into `.resurfaced`.
    /// Returns the capsules that changed so callers can react. Idempotent.
    @discardableResult
    func refreshDueSeals(now: Date = .now) throws -> [Capsule] {
        let due = try sealedCapsules().filter { $0.isDueToResurface(now: now) }
        for capsule in due { try capsule.transition(to: .resurfaced) }
        return due
    }
}
