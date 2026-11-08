import Foundation
import SwiftData
import os

/// Pure routing policy for cloud-backed delivery (docs/M10-DEVPLAN.md §4A).
///
/// Echoes and **near** seals stay on the exact, offline local path. Only a
/// signed-in user's **far** seals (beyond the local horizon) need a durable
/// server job — they're the ones at risk from the 64-pending cap and uninstall.
enum SealDeliveryRouter {
    /// Seals firing within this window stay purely local (exact, offline, no
    /// per-minute cron latency — a `now+60s` seal must not depend on the server).
    /// Beyond it, a signed-in user's seal also gets a durable server job. Tunable;
    /// most real seals ("open in 5 years") are far and so server-backed.
    static let localHorizon: TimeInterval = 24 * 60 * 60

    /// The far-seal jobs that *should* exist server-side right now, for a
    /// signed-in user: sealed capsules whose fire date is beyond the horizon.
    static func desiredJobs(capsules: [Capsule], now: Date, horizon: TimeInterval = localHorizon) -> [DeliveryJob] {
        capsules.compactMap { desiredJob(for: $0, now: now, horizon: horizon) }
    }

    /// The one "still a far seal" rule (M21 §4B): the job the server should hold for
    /// this capsule right now, or `nil` when it should hold none — not sealed, no date
    /// or zone, or due within the horizon (near seals stay local). The diff, the
    /// post-upsert check and the delete-cancel drain all ask this, with the `now` the
    /// reconcile was called with, so they cannot disagree about one capsule.
    static func desiredJob(for capsule: Capsule, now: Date, horizon: TimeInterval = localHorizon) -> DeliveryJob? {
        guard capsule.state == .sealed,
              let due = capsule.sealUntil,
              let tz = capsule.sealTimeZoneID,
              due.timeIntervalSince(now) > horizon  // near seals → local only
        else { return nil }
        return DeliveryJob(capsuleID: capsule.id, kind: "seal", fireDate: due, timeZoneID: tz)
    }
}

/// Reconciles the desired far-seal job set against the delivery backend, mirroring
/// `NotificationScheduler`'s diff-against-plan approach. Runs alongside the local
/// notification sync (via `NotificationCoordinator`), so routing is recomputed on
/// launch and every reactive sync. Idempotent + debounced: it upserts a job only
/// while the capsule is unstamped (`serverJobSyncedAt == nil`) and cancels only a
/// stamped job that's no longer desired — so a steady state makes **no** backend
/// calls and **no** CloudKit writes (avoiding the resurface-mirror thrash, §3 caution).
@MainActor
@Observable
final class SealDeliveryService {
    private let backend: DeliveryBackend
    private let identity: DeliveryIdentityProviding
    /// Whether the user has opted out of cloud delivery (§S5). Injectable for tests.
    private let isOptedOut: @Sendable () -> Bool
    private let log = Logger(subsystem: "com.soundpost.Soundpost", category: "delivery")

    /// Capsules with a request to the server in flight (M21 §4B). Skipped by **both**
    /// the upsert and the cancel loop, so an overlapping reconcile sends no second
    /// request for the same capsule in either direction.
    ///
    /// **Memory only, on purpose.** Until M21 the claim lived in `serverJobSyncedAt`
    /// itself, written before the await. That field is persisted and mirrored by
    /// CloudKit, so any save during the request — every user write, autosave, the
    /// gallery's own refresh — published "the server owns this seal" to every device
    /// before the server had answered, and each one dropped its local reminder. A
    /// request that then never answered (a kill, a dead network) left the claim in
    /// place for good. Here a kill loses only this set: nothing was stamped, so the
    /// next launch upserts again and the local reminder stays scheduled meanwhile.
    private var inFlight: Set<UUID> = []

    init(
        backend: DeliveryBackend,
        identity: DeliveryIdentityProviding,
        isOptedOut: @escaping @Sendable () -> Bool = { DeliveryPreferences.cloudOptedOut }
    ) {
        self.backend = backend
        self.identity = identity
        self.isOptedOut = isOptedOut
    }

    /// Diff the desired far-seal jobs against the server. Signed-out / unconfigured
    /// ⇒ no-op (jobs are user-scoped and are NOT cancelled on sign-out, §4A).
    ///
    /// - Parameter context: the store every decision is checked against (M20 §4C,
    ///   M21 §4B) — **not** `capsules`, which can be a snapshot taken before a delete,
    ///   or `[]` from a fetch that failed. Stamps are written to, and saved through,
    ///   this context.
    /// - Returns: whether any `serverJobSyncedAt` changed. The local plan reads that
    ///   field, so the caller must re-plan when it did (M21 §4B): a far seal entering
    ///   its last day is handed back to the device *here*, after the local plan ran.
    @discardableResult
    func reconcile(capsules: [Capsule], in context: ModelContext, now: Date = .now) async -> Bool {
        guard backend.isConfigured else { return false }
        guard let userKey = await identity.currentUserKey() else { return false } // signed out: local path
        var changed = await drainPendingCancels(userKey: userKey, in: context,       // durable delete-cancels (§S4)
                                                now: now, horizon: SealDeliveryRouter.localHorizon)
        guard !isOptedOut() else {                                                  // user deleted cloud data (§S5)
            if changed { save(context) }
            return changed
        }

        let desired = SealDeliveryRouter.desiredJobs(capsules: capsules, now: now)
        let desiredIDs = Set(desired.map(\.capsuleID))
        let byID = Dictionary(capsules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Upsert far seals the server doesn't yet own.
        //
        // **Only for a capsule still in the store** (M20 §4C review). `capsules` was
        // taken before this method's awaits, and a delete can land during any of them —
        // the key lookup alone can take seconds on a cold launch. Upserting a deleted
        // capsule from the stale snapshot would re-create a job nothing would ever
        // cancel. The check is synchronous and sits right before the request.
        //
        // **Stamped only after the server answers, and only if the store still holds
        // the same far seal** (M21 §4B) — a fresh fetch decides, never the snapshot.
        for job in desired {
            guard byID[job.capsuleID]?.serverJobSyncedAt == nil,
                  !inFlight.contains(job.capsuleID) else { continue }
            let id = job.capsuleID
            inFlight.insert(id)
            defer { inFlight.remove(id) }
            if await upsertUntilSettled(id, userKey: userKey, in: context, now: now) { changed = true }
        }

        // Cancel server jobs no longer in the desired set (unsealed / resurfaced /
        // fell within the local horizon). Delete is handled separately (§S4) since
        // a deleted capsule isn't in this array. The stamp stays until the server
        // confirms the cancel, so a failed request simply retries next sync.
        for capsule in capsules where capsule.serverJobSyncedAt != nil && !desiredIDs.contains(capsule.id) {
            // A capsule deleted since the snapshot is the delete path's to cancel; do not
            // write to it here.
            guard !inFlight.contains(capsule.id),
                  case .stored = lookup(capsule.id, in: context) else { continue }
            let id = capsule.id
            inFlight.insert(id)
            defer { inFlight.remove(id) }
            do {
                try await backend.cancelJob(capsuleID: id, userKey: userKey)
            } catch {
                log.info("cancelJob failed; will retry on next sync")
                continue
            }
            // The job is gone, so whatever the store holds now must not claim one: a
            // capsule re-sealed far during the request is upserted again next sync.
            if case .stored(let fresh) = lookup(id, in: context), fresh.serverJobSyncedAt != nil {
                fresh.serverJobSyncedAt = nil
                changed = true
            }
        }

        if changed { save(context) }
        return changed
    }

    /// Cancel one capsule's job by id — for the delete path, which removes the
    /// capsule before `reconcile` could see it (§S4). Durable: the id is enqueued
    /// in `DeliveryPreferences` by the caller, and is only resolved when the
    /// server confirms the cancel; if the key is momentarily unresolved (cold
    /// launch / transient CloudKit), it stays queued and `reconcile` retries it.
    func cancelJob(capsuleID: UUID) async {
        guard backend.isConfigured, let userKey = await identity.currentUserKey() else { return }
        do {
            try await backend.cancelJob(capsuleID: capsuleID, userKey: userKey)
            DeliveryPreferences.resolvePendingCancel(capsuleID)
        } catch {
            log.info("cancelJob failed; queued for retry on next sync")
        }
    }

    /// How many times one reconcile will re-send a capsule's job because the capsule
    /// changed while the previous request was in flight.
    static let maximumUpsertsPerCapsule = 3

    /// Send this capsule's job, and stamp it only once the server has accepted exactly
    /// what the store holds. Called with the capsule in flight. Returns whether it
    /// stamped.
    ///
    /// The job is built from a fresh fetch **at the moment it is sent**, not from the
    /// snapshot: earlier iterations of the caller's loop awaited the network, and the
    /// capsule may have been re-sealed meanwhile. When the server answers, a second fresh
    /// fetch decides (M21 §4B table):
    /// - the same far seal → stamp `now`;
    /// - a far seal with another instant or zone → send that now, while the capsule is
    ///   still in flight. Leaving it for "the next reconcile" left nothing to run it: the
    ///   sync the re-seal itself started had skipped this capsule *because* it was in
    ///   flight, and the server would have pushed on the old day (review, S1);
    /// - no longer a far seal, or gone → take the job back (`cancelOrphan`);
    /// - the store cannot answer → the server holds a job nothing records, so queue its
    ///   cancel; the drain resolves it untouched if the capsule turns out to be the same
    ///   far seal, and the diff then upserts and stamps it.
    ///
    /// **Never stamps after "Delete my cloud data".** That action purges the server,
    /// turns delivery off and clears every stamp; a request already in flight that
    /// answers afterwards must not write one back — no device would schedule a local
    /// reminder for that seal, and an opted-out device never reconciles it again.
    private func upsertUntilSettled(_ id: UUID, userKey: String, in context: ModelContext,
                                    now: Date) async -> Bool {
        guard case .stored(let current) = lookup(id, in: context), current.serverJobSyncedAt == nil,
              var job = SealDeliveryRouter.desiredJob(for: current, now: now) else { return false }
        for _ in 0..<Self.maximumUpsertsPerCapsule {
            do {
                try await backend.upsertJob(job, userKey: userKey)
            } catch {
                log.info("upsertJob failed; will retry on next sync")
                return false                   // nothing was stamped → retry on next sync
            }
            guard !isOptedOut() else { return false }
            switch lookup(id, in: context) {
            case .stored(let fresh):
                guard let wanted = SealDeliveryRouter.desiredJob(for: fresh, now: now) else {
                    // Unsealed, resurfaced or brought inside the horizon during the
                    // request: nothing will ever see this job again (it is unstamped),
                    // so take it back now — durably, through the delete-cancel queue.
                    await cancelOrphan(id, userKey: userKey)
                    return false
                }
                if wanted == job {
                    fresh.serverJobSyncedAt = now   // every device now drops its local backstop
                    return true
                }
                job = wanted                   // re-sealed during the request: send the new day
            case .absent:
                // Deleted during the request. The delete's own cancel may have reached
                // the server *before* this upsert re-created the row.
                await cancelOrphan(id, userKey: userKey)
                return false
            case .unknown:
                DeliveryPreferences.enqueuePendingCancel(id)
                return false
            }
        }
        return false                           // still changing: unstamped, the next sync decides
    }

    /// Take back a job just upserted for a capsule that, by the time the server
    /// answered, was no longer a far seal or no longer existed. Queued first, so a
    /// failure here (or a kill) is retried by the drain on the next sync; resolved on
    /// the server's word. Called while the capsule is still in flight.
    private func cancelOrphan(_ capsuleID: UUID, userKey: String) async {
        DeliveryPreferences.enqueuePendingCancel(capsuleID)
        do {
            try await backend.cancelJob(capsuleID: capsuleID, userKey: userKey)
            DeliveryPreferences.resolvePendingCancel(capsuleID)
        } catch {
            log.info("cancelJob for a capsule changed mid-upsert failed; queued for retry")
        }
    }

    /// Retry every queued cancel; resolve each only once the server confirms it
    /// (idempotent, so retries are safe).
    ///
    /// **Each id is decided by a fresh fetch, never by `capsules`** (M20 §4C). The
    /// delete path queues the cancel *before* it saves, so that a cancel survives a cold
    /// launch. The other side of that order: a kill between the queue and the save left
    /// a capsule that still exists with its id queued, and this cancelled its server job
    /// unconditionally. Its `serverJobSyncedAt` stayed set, so the reconcile never
    /// upserted it again and the planner scheduled no local reminder for it — a far seal
    /// that would never notify. Pre-existing since M10.
    ///
    /// Still in the store **and still a far seal** → the delete never committed (or the
    /// capsule was re-sealed): resolve without cancelling; the ordinary diff owns that
    /// job. Still in the store but no longer a far seal (M21 §4B: queued by an upsert
    /// that found the capsule changed under it, which the diff can no longer see because
    /// nothing was stamped) → cancel. Gone → cancel. Cannot tell → leave it queued.
    ///
    /// - Parameters:
    ///   - now: the reconcile's own `now` — never `Date.now`, or a test with a fixed
    ///     clock (and a reconcile that waited on the network) would classify a capsule
    ///     against a different instant from the diff's.
    /// - Returns: whether a stamp was cleared.
    private func drainPendingCancels(userKey: String, in context: ModelContext,
                                     now: Date, horizon: TimeInterval) async -> Bool {
        var changed = false
        for capsuleID in DeliveryPreferences.pendingCancelCapsuleIDs where !inFlight.contains(capsuleID) {
            switch lookup(capsuleID, in: context) {
            case .unknown:
                continue
            case .stored(let capsule)
                where SealDeliveryRouter.desiredJob(for: capsule, now: now, horizon: horizon) != nil:
                DeliveryPreferences.resolvePendingCancel(capsuleID)
                continue
            case .stored, .absent:
                break
            }
            inFlight.insert(capsuleID)
            defer { inFlight.remove(capsuleID) }
            do {
                try await backend.cancelJob(capsuleID: capsuleID, userKey: userKey)
                DeliveryPreferences.resolvePendingCancel(capsuleID)
            } catch {
                continue                     // leave queued; retried on the next sync
            }
            if case .stored(let fresh) = lookup(capsuleID, in: context), fresh.serverJobSyncedAt != nil {
                fresh.serverJobSyncedAt = nil
                changed = true
            }
        }
        return changed
    }

    /// What the store holds for this id right now — a fresh fetch, not a look at any
    /// array a caller is holding.
    private enum Lookup {
        case stored(Capsule)
        case absent
        /// The store could not answer; decide nothing.
        case unknown
    }

    private func lookup(_ id: UUID, in context: ModelContext) -> Lookup {
        #if DEBUG
        if unreadableForTesting.contains(id) { return .unknown }
        #endif
        var fetch = FetchDescriptor<Capsule>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        guard let found = try? context.fetch(fetch) else { return .unknown }
        return found.first.map(Lookup.stored) ?? .absent
    }

    #if DEBUG
    /// Test seam: ids whose fresh fetch reports that the store could not answer.
    /// SwiftData offers no supported way to make one fetch fail.
    @ObservationIgnored var unreadableForTesting: Set<UUID> = []
    #endif

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            // The stamps stay in memory and go out with the next save; a later
            // reconcile reaches the same decision either way.
            log.info("Saving delivery stamps failed; the next save carries them")
        }
    }

    /// "Delete my cloud data": purge every token + job for this user and set the
    /// server-side opt-out tombstone (§S5). Returns whether the data is gone:
    /// `true` when there's nothing to purge (no server configured) or the purge
    /// succeeded; `false` only when an actual purge attempt failed (e.g. offline)
    /// — so the caller can keep the control visible and retry rather than falsely
    /// reporting success.
    @discardableResult
    func deleteAllCloudData() async -> Bool {
        guard backend.isConfigured else { return true }         // no server ⇒ nothing to delete
        guard let userKey = await identity.currentUserKey() else { return false } // can't authenticate ⇒ retry
        do {
            try await backend.deleteAll(userKey: userKey)
            return true
        } catch {
            return false
        }
    }
}
