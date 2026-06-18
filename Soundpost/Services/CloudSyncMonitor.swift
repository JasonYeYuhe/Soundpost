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

    /// How a capsule's durability reads to the user — the storage footer's honest
    /// copy maps directly off this (S6). Combines the container rung (is CloudKit
    /// even configured?) with the live sync state.
    enum Backup: Equatable {
        case iCloud        // CloudKit-backed and healthy (or assumed-signed-in)
        case signedOut     // CloudKit-backed but no iCloud account
        case quotaFull     // CloudKit-backed but iCloud storage is full
        case localOnly     // no CloudKit (local / in-memory rung)
    }

    private(set) var state: State = .unknown
    private(set) var rung: StorageRung = .local
    private var token: NSObjectProtocol?
    private var center: NotificationCenter?

    /// The user-facing durability summary. Policy lives here (testable); the
    /// localized strings live in the view that renders it.
    var backup: Backup {
        switch rung {
        case .local, .inMemory:
            return .localOnly
        case .cloudKit:
            switch state {
            case .signedOut:     return .signedOut
            case .quotaExceeded: return .quotaFull
            // .ok / .syncing / .unknown: the store is configured to mirror to
            // iCloud. The brief pre-account .unknown window resolves within a
            // second of launch (to .signedOut if there's no account), so an
            // optimistic "backed up" reads honestly for the common signed-in case.
            case .ok, .syncing, .unknown: return .iCloud
            }
        }
    }

    /// Begin observing CloudKit sync events, recording which storage rung the
    /// container landed on. Idempotent.
    func start(rung: StorageRung, center: NotificationCenter = .default) {
        self.rung = rung
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
    ///
    /// CoreData+CloudKit doesn't always hand us a bare `CKError`: a signed-out
    /// account surfaces (observed on a CloudKit-entitled build) as the Cocoa
    /// error 134400 "Unable to initialize without an iCloud account", and other
    /// errors arrive with the real `CKError` nested under `NSUnderlyingError`. So
    /// walk the underlying-error chain and also match the Cocoa no-account code.
    static func surfacedState(for error: Error) -> State? {
        // Cocoa error CoreData+CloudKit raises when there's no iCloud account.
        let noAccountCocoaCode = 134400

        for link in errorChain(error) {
            if let ckError = link as? CKError {
                switch ckError.code {
                case .notAuthenticated: return .signedOut
                case .quotaExceeded:    return .quotaExceeded
                default:                break
                }
            }
            let nsError = link as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == noAccountCocoaCode {
                return .signedOut
            }
        }
        return nil
    }

    /// An error plus its `NSUnderlyingError` chain (bounded), so a `CKError`
    /// wrapped by CoreData is still found.
    private static func errorChain(_ error: Error, limit: Int = 5) -> [Error] {
        var chain: [Error] = []
        var current: Error? = error
        while let link = current, chain.count < limit {
            chain.append(link)
            current = (link as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return chain
    }

    func stop() {
        if let token { (center ?? .default).removeObserver(token) }
        token = nil
        center = nil
    }
}
