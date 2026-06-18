import Foundation
import CoreData
import CloudKit
import Observation

/// Watches CloudKit sync health and folds it into a **calm** state for honest
/// in-app copy (docs/M9-DEVPLAN.md §S5). Durability is a background nicety, never
/// a gate — so a signed-out or over-quota account is surfaced as a quiet one-line
/// note (rendered by the storage footer in S6), **never** an error alert, and the
/// local app keeps working untouched. Other sync errors are logged (scrubbed) to
/// Sentry and not shown at all.
///
/// It observes `NSPersistentCloudKitContainer.eventChangedNotification` — the
/// right signal for sync *status* (S4's reschedule uses `.NSPersistentStoreRemoteChange`
/// instead, because that one needs *merged records*, not status). Without the §8
/// iCloud entitlement no events fire, so the state simply stays `.unknown` and
/// the app presents its honest local-only copy.
@MainActor
@Observable
final class CloudSyncMonitor {
    /// Calm, user-facing sync state — there is deliberately no "error" case.
    enum State: Equatable {
        case unknown        // not yet determined (local rung, or pre-account)
        case syncing
        case ok
        case signedOut      // CKError.notAuthenticated — no iCloud account
        case quotaExceeded  // iCloud storage full
    }

    private(set) var state: State = .unknown
    private var token: NSObjectProtocol?
    private var center: NotificationCenter?

    /// Begin observing CloudKit sync events. Idempotent.
    func start(center: NotificationCenter = .default) {
        guard token == nil else { return }
        self.center = center
        token = center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note) }
        }
    }

    func handle(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
        apply(error: event.error, finished: event.endDate != nil)
    }

    /// Fold one sync event into the calm state. Pure + synchronous so the mapping
    /// is unit-testable without constructing a (non-initializable) CloudKit event.
    func apply(error: Error?, finished: Bool) {
        if let error {
            if let surfaced = Self.surfacedState(for: error) {
                state = surfaced
            } else {
                // Transient/other error: log scrubbed, never surface, and keep the
                // prior state so a blip doesn't flip honest copy back and forth.
                Diagnostics.notice("CloudKit sync error (code \((error as NSError).code)), not surfaced")
            }
        } else if finished {
            state = .ok
        } else {
            state = .syncing
        }
    }

    /// The only sync errors worth telling the user about — both calmly, both
    /// leaving the local app fully functional. Everything else returns nil.
    static func surfacedState(for error: Error) -> State? {
        guard let ckError = error as? CKError else { return nil }
        switch ckError.code {
        case .notAuthenticated: return .signedOut
        case .quotaExceeded:    return .quotaExceeded
        default:                return nil
        }
    }

    func stop() {
        if let token { (center ?? .default).removeObserver(token) }
        token = nil
        center = nil
    }
}
