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
    ///
    /// `audioData` is the canonical M9 store; when supplied (the just-recorded
    /// clip read into memory) the capsule is durable immediately and CloudKit
    /// mirrors it as a `CKAsset`. `audioFileName` is kept as a transitional
    /// fallback — the file→Data backfill (§S2) reclaims the on-disk clip later.
    /// `audioData` is optional so existing file-only call sites/tests still work.
    func markCaptured(
        _ capsule: Capsule,
        audioFileName: String,
        audioData: Data? = nil,
        durationSeconds: Double,
        waveformSamples: [Float]
    ) throws {
        capsule.audioFileName = audioFileName
        capsule.audioData = audioData
        capsule.durationSeconds = durationSeconds
        capsule.waveformSamples = waveformSamples
        try capsule.transition(to: .captured)
    }

    /// Seal a captured capsule until `date`, stamping the time zone for correct
    /// far-future delivery (docs/PROJECT.md §1e.5). The chosen day is normalized to
    /// a humane local hour (09:00 in `timeZone`) via `SealClock` so the capsule
    /// resurfaces at a civil time, not whenever it happened to be captured (M12
    /// §S2). Sealing supersedes any pending echo — a sealed capsule hides its
    /// content, so a "remember this day" echo would contradict it.
    ///
    /// Clears `serverJobSyncedAt`: the wall clock just changed, so the M10
    /// reconcile must re-upsert the job (and the local planner re-arm its
    /// backstop). A removal (unseal/delete) deliberately does NOT clear it — that
    /// path relies on the reconcile *cancel* branch to tell the server to drop the
    /// job (§S2 P0).
    func seal(_ capsule: Capsule, until date: Date, timeZone: TimeZone = .current) throws {
        capsule.sealUntil = SealClock.normalize(date, in: timeZone)
        capsule.sealTimeZoneID = timeZone.identifier
        capsule.echoAt = nil
        capsule.serverJobSyncedAt = nil
        try capsule.transition(to: .sealed)
    }

    /// Set or clear a capsule's gentle echo reminder. A non-nil date is normalized
    /// to 09:00 device-local (echoes are near-term wall-clock events — see
    /// `NotificationPlanner`) so the reminder lands at a humane hour (M12 §S2).
    func setEcho(_ capsule: Capsule, at date: Date?) {
        capsule.echoAt = date.map { SealClock.normalize($0) }
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

    /// One-shot humane-hour normalization for capsules sealed/echoed before §S2
    /// (or at an antisocial hour). Rewrites each *future* seal/echo fire instant to
    /// 09:00 local in its intended zone and — crucially for a seal the server
    /// already owns — clears `serverJobSyncedAt` so the M10 reconcile re-upserts the
    /// new wall clock and the local planner re-arms (§S2 P0); without that the
    /// Supabase job keeps firing at the old 02:47.
    ///
    /// Idempotent (an instant already at 09:00 is left untouched), so it is safe to
    /// run on every launch with no backend churn. Never moves a fire instant into
    /// the past: a seal whose 09:00 would already have passed keeps its stored
    /// instant (it resurfaces in-app on its date regardless). Returns the capsules
    /// it changed.
    @discardableResult
    func normalizeSealHours(now: Date = .now) throws -> [Capsule] {
        var changed: [Capsule] = []
        for capsule in try all() {
            switch capsule.state {
            case .sealed:
                guard let due = capsule.sealUntil, due > now else { continue }
                let zone = capsule.sealTimeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
                let normalized = SealClock.normalize(due, in: zone)
                guard normalized != due, normalized > now else { continue }
                capsule.sealUntil = normalized
                capsule.serverJobSyncedAt = nil   // re-arm: wall clock changed (§S2 P0)
                changed.append(capsule)
            case .captured:
                guard let echo = capsule.echoAt, echo > now else { continue }
                let normalized = SealClock.normalize(echo)
                guard normalized != echo, normalized > now else { continue }
                capsule.echoAt = normalized
                changed.append(capsule)
            default:
                continue
            }
        }
        return changed
    }
}
