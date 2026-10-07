import Foundation

/// The user's delete of a saved capsule, out of the view so a failing save can be
/// tested — there is no UI-test target (M20 §4C).
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
    ///    pending deletes are undone and the queue entry resolved here.
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
        DeliveryPreferences.enqueuePendingCancel(capsuleID)
        do {
            try store.commitDelete(capsule, commit: commit)
        } catch {
            DeliveryPreferences.resolvePendingCancel(capsuleID)
            Diagnostics.notice("Delete save failed at user action")
            return false
        }
        if let audioFile { try? audioStore.delete(audioFile) }
        cancelServerJob(capsuleID)
        return true
    }
}
