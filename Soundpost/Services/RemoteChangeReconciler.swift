import Foundation
import CoreData
import SwiftData

/// Reschedules local notifications when CloudKit merges remote changes into the
/// local store (docs/M9-DEVPLAN.md §S4).
///
/// A sealed/echo capsule created on another device arrives here via CloudKit
/// with **no local notification scheduled** — so its resurfacing/echo would
/// never fire on this device unless we react to the import. The reactive SwiftUI
/// path (`@Query` → `sealSignature` `onChange` → sync) only fires while the UI is
/// foreground; SwiftUI views aren't evaluated in the background, so an import
/// arriving via CloudKit's silent push while backgrounded would be missed.
///
/// We therefore observe **`.NSPersistentStoreRemoteChange`** — posted when the
/// local store is *actually modified by a remote merge* — at the app layer (a
/// plain `NotificationCenter` observer, alive while backgrounded), NOT
/// `NSPersistentCloudKitContainer.eventChangedNotification` (sync *status* only,
/// no guarantee records merged). The foreground `.task`/`scenePhase` reconcile
/// stays as the belt-and-suspenders path. Background wake is itself best-effort
/// (system-throttled) — fine for M9 (durability); guaranteed firing is M10.
@MainActor
final class RemoteChangeReconciler {
    private var token: NSObjectProtocol?
    private var center: NotificationCenter?
    private var work: Task<Void, Never>?
    private var reschedule: (() async -> Void)?

    /// Register for `.NSPersistentStoreRemoteChange` with a reschedule action.
    /// Idempotent — calling it again while already observing is a no-op.
    func observe(reschedule: @escaping () async -> Void, center: NotificationCenter = .default) {
        guard token == nil else { return }
        self.reschedule = reschedule
        self.center = center
        token = center.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (queue: .main), so we're on the main
            // actor — assert it to call the isolated handler without a warning.
            MainActor.assumeIsolated { _ = self?.handleRemoteChange() }
        }
    }

    /// Production wiring: on a remote merge, fetch the current capsules from the
    /// main context and reconcile the 64-nearest local schedule against them.
    func start(container: ModelContainer, notifications: NotificationCoordinator,
               center: NotificationCenter = .default) {
        observe(reschedule: { [weak notifications] in
            // Consent first, and before the notification bodies are rebuilt: a merge
            // may be carrying a withdrawal made on another device, and the bodies
            // built below consult the soundprints this call may be about to erase
            // (M15 §4I). `applyToDevice` also refreshes the mirror the copy reads.
            do {
                _ = try ListeningConsentStore.applyToDevice(in: container.mainContext)
            } catch {
                // Logged, not swallowed. This was a bare `try?`, so a merge carrying a
                // withdrawal could fail to apply it and fail to erase, and the rebuild
                // below would then bake the surviving labels into fresh lock-screen
                // bodies — with nothing anywhere to say it had happened.
                Diagnostics.notice("Could not apply account-wide listening consent on a remote merge",
                                   code: (error as NSError).code)
            }
            guard let notifications else { return }
            // The sync still runs on failure. This observer exists so a capsule created
            // on another device gets a local notification at all (M9 §S4); skipping it
            // would trade a copy defect for a durability one. `contentVersion` reads the
            // mirror, so a failed apply means the bodies are rebuilt against the answer
            // this device already had — the same position the launch path takes.
            let capsules = (try? CapsuleStore(context: container.mainContext).all()) ?? []
            // The same context the capsules came from, so the one scoped rejection
            // fetch inside `sync` sees exactly what this merge just delivered — this
            // is §4B's "one scoped fetch per operation" for the path that is not a
            // view and has no query.
            await notifications.sync(capsules: capsules, in: container.mainContext)
        }, center: center)
    }

    /// The import-event handler. Coalesces a burst of merge notifications into a
    /// single reschedule by cancelling any still-pending one.
    @discardableResult
    func handleRemoteChange() -> Task<Void, Never>? {
        guard let reschedule else { return nil }
        work?.cancel()
        // os.Logger on the durability path (§S8): background CloudKit merges are
        // otherwise invisible. Local log only — info, non-PII, no Sentry noise.
        Diagnostics.info("Remote store change merged — rescheduling notifications")
        let task = Task { @MainActor in await reschedule() }
        work = task
        return task
    }

    func stop() {
        if let token { (center ?? .default).removeObserver(token) }
        token = nil
        center = nil
        work?.cancel()
        work = nil
    }
}
