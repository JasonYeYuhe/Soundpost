import Foundation

/// User writes that touch a far seal's server job — the delete, the seal, the launch
/// normalize — out of the views so a failing save can be tested; there is no UI-test
/// target (M20 §4C, M23 §4F.1).
@MainActor
enum CapsuleActions {
    /// Delete `capsule` for good. Returns whether it happened. On `false` nothing has
    /// changed — the capsule, its corrections, its audio file and its far-future push
    /// are all still there — and the caller says so and stays where it is.
    ///
    /// **The order is the point.**
    /// 1. Queue the server cancel *first*, with no `await` between it and the save. A
    ///    kill after the save but before the network call must still cancel the push
    ///    on the next launch (§S4). If the save never commits, the drain's fresh-fetch
    ///    check (`SealDeliveryService.drainPendingCancels`) finds the capsule still
    ///    there and drops the entry instead of cancelling a live seal's push.
    /// 2. Delete and save as one write (`CapsuleStore.commitDelete`). On failure the
    ///    pending deletes are undone and the queue entry resolved here — **only if this
    ///    delete added it**. An entry already queued belongs to someone else: since M21
    ///    the delivery reconcile queues one to take back a job it upserted for a capsule
    ///    that changed under the request, and resolving that here would leave the job on
    ///    the server for good if its own cancel had failed.
    /// 3. Only then remove the audio file and ask the server. The file used to go
    ///    first, so a failed save left a capsule with no sound; the cancel used to fire
    ///    regardless, so a failed delete took a surviving seal's push with it.
    @discardableResult
    static func delete(
        _ capsule: Capsule,
        in store: CapsuleStore,
        audioStore: AudioStore = AudioStore(),
        cancelServerJob: (UUID) -> Void,
        commit: (() throws -> Void)? = nil
    ) -> Bool {
        let capsuleID = capsule.id
        let audioFile = capsule.audioFileName
        let alreadyQueued = DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsuleID)
        DeliveryPreferences.enqueuePendingCancel(capsuleID)
        do {
            try store.commitDelete(capsule, commit: commit)
        } catch {
            if !alreadyQueued { DeliveryPreferences.resolvePendingCancel(capsuleID) }
            Diagnostics.notice("Delete save failed at user action")
            return false
        }
        if let audioFile { try? audioStore.delete(audioFile) }
        cancelServerJob(capsuleID)
        return true
    }

    /// Seal `capsule` until `date` and save, as one user write (M23 §4F.1).
    ///
    /// **A re-seal must not orphan the old far job.** `unseal` keeps `serverJobSyncedAt`
    /// so the reconcile can cancel the job; offline, that cancel fails and the stamp
    /// stays — and `seal` then clears it. Re-sealed *near*, nothing would ever cancel the
    /// old job (near seals have none, and the cancel loop looks only at stamped capsules),
    /// so the server would push "A capsule has resurfaced" on the old date. So a capsule
    /// that carries a stamp before this seal gets a durable pending cancel **before** the
    /// save, like `delete`. The drain decides it by a fresh fetch: near or gone → cancel;
    /// still a far seal → wait until the server holds this seal (the upsert stamps it).
    ///
    /// On a failed save the capsule is put back (`commitSeal`) and the queue entry is
    /// resolved — **only if this call added it**; one already queued is someone else's.
    /// Not inside `CapsuleStore.seal`, which knows nothing of delivery (M22 L-D3).
    static func seal(
        _ capsule: Capsule,
        until date: Date,
        in store: CapsuleStore,
        timeZone: TimeZone = .current,
        now: Date = .now,
        commit: (() throws -> Void)? = nil
    ) throws {
        let capsuleID = capsule.id
        let ownsAJob = capsule.serverJobSyncedAt != nil
        let alreadyQueued = DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsuleID)
        if ownsAJob { DeliveryPreferences.enqueuePendingCancel(capsuleID) }
        do {
            try store.commitSeal(capsule, until: date, timeZone: timeZone, now: now, commit: commit)
        } catch {
            if ownsAJob && !alreadyQueued { DeliveryPreferences.resolvePendingCancel(capsuleID) }
            throw error
        }
    }

    /// The launch / foreground write before a sync (M23 §4F.1): normalize seal hours,
    /// flip due seals, one save — in that order, as `refreshAndSync` always did.
    ///
    /// `normalizeSealHours` clears the stamp of every seal it moves before it returns, so
    /// which of them owned a server job is recorded **first**. A stamped seal it moves
    /// gets a pending cancel, for the same reason as a re-seal: moved inside the horizon,
    /// nothing else would cancel the old job (moved but still far, the drain waits for
    /// the re-upsert to stamp it). On a failed save only the entries added here are
    /// resolved; the due seals flipped to `.resurfaced` are handled exactly as before.
    static func normalizeAndRefresh(in store: CapsuleStore, now: Date = .now,
                                    commit: (() throws -> Void)? = nil) {
        let owned = Set(((try? store.sealedCapsules()) ?? [])
            .filter { $0.serverJobSyncedAt != nil }.map(\.id))
        let moved = ((try? store.normalizeSealHours(now: now)) ?? []).filter { owned.contains($0.id) }
        var added: [UUID] = []
        for capsule in moved where !DeliveryPreferences.pendingCancelCapsuleIDs.contains(capsule.id) {
            DeliveryPreferences.enqueuePendingCancel(capsule.id)
            added.append(capsule.id)
        }
        _ = try? store.refreshDueSeals(now: now)
        do {
            if let commit { try commit() } else { try store.save() }
        } catch {
            for id in added { DeliveryPreferences.resolvePendingCancel(id) }
            Diagnostics.notice("Launch normalize save failed")
        }
    }
}
