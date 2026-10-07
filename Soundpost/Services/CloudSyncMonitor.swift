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

    /// What an unsurfaced sync error is reported to Sentry as — integers only, so the
    /// `StaticString` no-PII rule holds (M20 §4D).
    ///
    /// It used to be one message per sync *event* with only the outer `NSError.code`:
    /// 98 messages in eight minutes from one device, all reading "code 134400"-style
    /// numbers whose domain — and the `CKError` that actually explains them, nested
    /// under `NSUnderlyingError` — was never sent.
    struct ErrorReport: Hashable, Sendable {
        /// The outer error's domain as a fixed small number (`Domain`), never its string.
        let domain: Int
        let code: Int
        /// The first `CKError` code in the underlying chain, or -1 when there is none.
        let cloudKitCode: Int
    }

    /// Error domains as numbers. Anything unlisted is `other` — the code still says
    /// which error it was within whatever domain that is.
    enum Domain: Int {
        case other = 0, cocoa = 1, cloudKit = 2, url = 3, posix = 4
    }

    /// Reports already sent this launch: one per (domain, code, CloudKit code). A
    /// retry storm is one fact, not ninety-eight.
    @ObservationIgnored private var reportedThisLaunch: Set<ErrorReport> = []

    /// Where an unsurfaced error goes. Sentry, through `Diagnostics`; a test swaps it.
    @ObservationIgnored var sendReport: (ErrorReport) -> Void = { report in
        Diagnostics.notice("CloudKit sync error, not surfaced", domain: report.domain,
                           code: report.code, cloudKitCode: report.cloudKitCode)
    }
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
                // prior state so a blip doesn't flip honest copy back and forth. Once
                // per kind per launch.
                let report = Self.report(for: error)
                if reportedThisLaunch.insert(report).inserted { sendReport(report) }
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

    /// The integers an error is reported as. Pure, so it is tested without Sentry.
    static func report(for error: Error) -> ErrorReport {
        let outer = error as NSError
        let domain: Domain
        switch outer.domain {
        case NSCocoaErrorDomain: domain = .cocoa
        case CKErrorDomain:      domain = .cloudKit
        case NSURLErrorDomain:   domain = .url
        case NSPOSIXErrorDomain: domain = .posix
        default:                 domain = .other
        }
        let cloudKit = errorChain(error).lazy.compactMap { $0 as? CKError }.first
        return ErrorReport(domain: domain.rawValue, code: outer.code,
                           cloudKitCode: cloudKit.map { $0.errorCode } ?? -1)
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
