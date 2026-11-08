import Foundation
import UserNotifications
@testable import Soundpost

enum DeliveryTestError: Error { case boom }

/// In-memory `DeliveryBackend` that records every call (mirrors the project's
/// `@unchecked Sendable` mock style).
///
/// **Can hold a request mid-flight** (M21 §4B): `holdNextUpsert()` / `holdNextCancel()`
/// make the next such call record itself and then suspend until `releaseHeld()` — or
/// forever, which is how a test stands in for a request that never answers (a kill, a
/// dead network). Thread-safe for that reason: the service awaits these methods off the
/// main actor while the test inspects them from it.
final class SpyDeliveryBackend: DeliveryBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _configured: Bool
    private var _shouldThrow = false
    private var _registerCalls: [(registration: DeviceTokenRegistration, userKey: String)] = []
    private var _unregisterCalls: [(token: String, userKey: String)] = []
    private var _upsertedJobs: [(job: DeliveryJob, userKey: String)] = []
    private var _cancelledJobs: [(capsuleID: UUID, userKey: String)] = []
    private var _deleteAllCalls: [String] = []
    private var holdUpsert = false
    private var holdCancel = false
    private var held: CheckedContinuation<Void, Error>?

    init(configured: Bool = true) { _configured = configured }

    var configured: Bool {
        get { lock.withLock { _configured } }
        set { lock.withLock { _configured = newValue } }
    }
    var shouldThrow: Bool {
        get { lock.withLock { _shouldThrow } }
        set { lock.withLock { _shouldThrow = newValue } }
    }
    var registerCalls: [(registration: DeviceTokenRegistration, userKey: String)] { lock.withLock { _registerCalls } }
    var unregisterCalls: [(token: String, userKey: String)] { lock.withLock { _unregisterCalls } }
    var upsertedJobs: [(job: DeliveryJob, userKey: String)] { lock.withLock { _upsertedJobs } }
    var cancelledJobs: [(capsuleID: UUID, userKey: String)] { lock.withLock { _cancelledJobs } }
    var deleteAllCalls: [String] { lock.withLock { _deleteAllCalls } }

    var isConfigured: Bool { configured }

    /// Whether a request is suspended in `upsertJob` / `cancelJob` right now.
    var isHolding: Bool { lock.withLock { held != nil } }

    func holdNextUpsert() { lock.withLock { holdUpsert = true } }
    func holdNextCancel() { lock.withLock { holdCancel = true } }

    /// Let the held request return — successfully, or by throwing `error`.
    func releaseHeld(throwing error: Error? = nil) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { held = nil }
            return held
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func registerToken(_ registration: DeviceTokenRegistration, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        lock.withLock { _registerCalls.append((registration, userKey)) }
    }
    func unregisterToken(_ token: String, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        lock.withLock { _unregisterCalls.append((token, userKey)) }
    }
    func upsertJob(_ job: DeliveryJob, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        let hold = lock.withLock { () -> Bool in
            _upsertedJobs.append((job, userKey))
            defer { holdUpsert = false }
            return holdUpsert
        }
        if hold { try await suspend() }
    }
    func cancelJob(capsuleID: UUID, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        let hold = lock.withLock { () -> Bool in
            _cancelledJobs.append((capsuleID, userKey))
            defer { holdCancel = false }
            return holdCancel
        }
        if hold { try await suspend() }
    }
    func deleteAll(userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        lock.withLock { _deleteAllCalls.append(userKey) }
    }

    private func suspend() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { held = continuation }
        }
    }
}

/// In-memory `DeliveryIdentityProviding` with a settable key (nil = signed out).
final class StubDeliveryIdentity: DeliveryIdentityProviding, @unchecked Sendable {
    var key: String?
    private(set) var accountChangeCount = 0

    init(key: String?) { self.key = key }

    func currentUserKey() async -> String? { key }
    func accountDidChange() async { accountChangeCount += 1 }
}

/// A notification centre whose next `add` can be held mid-flight, so two reconciles
/// can be made to overlap at exactly the suspension where they used to interfere.
///
/// Shared by `ReconcileOverlapTests` and the M21 delivery tests, which drive the real
/// `NotificationCoordinator.sync` against it to see what a sync schedules.
///
/// Thread-safe on purpose: `NotificationScheduler.reconcile` is a nonisolated `async`
/// function, so two calls run on the global executor and — when nothing serialises
/// them, which is what the controls for this suite reintroduce — at the same time.
final class HoldingCenter: UserNotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [String] = []
    private var _everAdded: [String] = []
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?

    var pending: [String] { lock.withLock { _pending } }
    var everAdded: [String] { lock.withLock { _everAdded } }
    var isHoldingAnAdd: Bool { lock.withLock { held != nil } }

    func holdNextAdd() { lock.withLock { holdNext = true } }

    func releaseHeldAdd() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func pendingRequestIdentifiers() async -> [String] { pending }

    func removePendingRequests(withIdentifiers ids: [String]) {
        lock.withLock { _pending.removeAll { ids.contains($0) } }
    }

    func add(_ request: UNNotificationRequest) async throws {
        let shouldHold = lock.withLock { () -> Bool in
            defer { holdNext = false }
            return holdNext
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { held = continuation }
            }
        }
        lock.withLock {
            _pending.append(request.identifier)
            _everAdded.append(request.identifier)
        }
    }
}
