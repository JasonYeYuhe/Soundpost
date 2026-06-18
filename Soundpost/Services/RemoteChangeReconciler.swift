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
            guard let notifications else { return }
            let capsules = (try? CapsuleStore(context: container.mainContext).all()) ?? []
            await notifications.sync(capsules: capsules)
        }, center: center)
    }

    /// The import-event handler. Coalesces a burst of merge notifications into a
    /// single reschedule by cancelling any still-pending one.
    @discardableResult
    func handleRemoteChange() -> Task<Void, Never>? {
        guard let reschedule else { return nil }
        work?.cancel()
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
