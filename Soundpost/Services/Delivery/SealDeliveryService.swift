import Foundation
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
        capsules.compactMap { capsule in
            guard capsule.state == .sealed,
                  let due = capsule.sealUntil,
                  let tz = capsule.sealTimeZoneID,
                  due.timeIntervalSince(now) > horizon  // near seals → local only
            else { return nil }
            return DeliveryJob(capsuleID: capsule.id, kind: "seal", fireDate: due, timeZoneID: tz)
        }
    }
}

/// Reconciles the desired far-seal job set against the delivery backend, mirroring
/// `NotificationScheduler`'s diff-against-plan approach. Runs alongside the local
/// notification sync (via `NotificationCoordinator`), so routing is recomputed on
/// launch and every reactive sync. Idempotent + debounced: it upserts a job only
/// the first time (`serverJobSyncedAt == nil`) and cancels only a previously-synced
/// job that's no longer desired — so a steady state makes **no** backend calls and
/// **no** CloudKit writes (avoiding the resurface-mirror thrash, §3 caution).
@MainActor
@Observable
final class SealDeliveryService {
    private let backend: DeliveryBackend
    private let identity: DeliveryIdentityProviding
    /// Whether the user has opted out of cloud delivery (§S5). Injectable for tests.
    private let isOptedOut: @Sendable () -> Bool
    private let log = Logger(subsystem: "com.soundpost.Soundpost", category: "delivery")

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
    func reconcile(capsules: [Capsule], now: Date = .now) async {
        guard backend.isConfigured else { return }
        guard let userKey = await identity.currentUserKey() else { return } // signed out: local path
        await drainPendingCancels(userKey: userKey)                         // durable delete-cancels (§S4)
        guard !isOptedOut() else { return }                                 // user deleted cloud data (§S5)

        let desired = SealDeliveryRouter.desiredJobs(capsules: capsules, now: now)
        let desiredIDs = Set(desired.map(\.capsuleID))
        let byID = Dictionary(capsules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var didChange = false

        // Upsert far seals the server doesn't yet own. Claim `serverJobSyncedAt`
        // SYNCHRONOUSLY before the await (mirroring DeliveryRegistrar.flushPending),
        // so a reconcile that overlaps this one across the suspension observes the
        // claim and skips — preserving the §S3 debounce (one upsert, no CloudKit
        // thrash). Released on failure so a genuine error retries next sync.
        for job in desired {
            guard let capsule = byID[job.capsuleID], capsule.serverJobSyncedAt == nil else { continue }
            capsule.serverJobSyncedAt = now    // claim before the await
            do {
                try await backend.upsertJob(job, userKey: userKey)
                didChange = true               // every device now drops its local backstop
            } catch {
                capsule.serverJobSyncedAt = nil // release → retry on next sync
                log.info("upsertJob failed; will retry on next sync")
            }
        }

        // Cancel server jobs no longer in the desired set (unsealed / resurfaced /
        // fell within the local horizon). Delete is handled separately (§S4) since
        // a deleted capsule isn't in this array. Same claim-before-await discipline.
        for capsule in capsules where capsule.serverJobSyncedAt != nil && !desiredIDs.contains(capsule.id) {
            let prior = capsule.serverJobSyncedAt
            capsule.serverJobSyncedAt = nil    // claim before the await
            do {
                try await backend.cancelJob(capsuleID: capsule.id, userKey: userKey)
                didChange = true
            } catch {
                capsule.serverJobSyncedAt = prior // restore → retry on next sync
                log.info("cancelJob failed; will retry on next sync")
            }
        }

        if didChange { try? byID.values.first?.modelContext?.save() }
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

    /// Retry every queued delete-path cancel; resolve each only once the server
    /// confirms it (idempotent, so retries are safe).
    private func drainPendingCancels(userKey: String) async {
        for capsuleID in DeliveryPreferences.pendingCancelCapsuleIDs {
            do {
                try await backend.cancelJob(capsuleID: capsuleID, userKey: userKey)
                DeliveryPreferences.resolvePendingCancel(capsuleID)
            } catch {
                // Leave queued; retried on the next sync.
            }
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
