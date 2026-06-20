import Foundation
@testable import Soundpost

enum DeliveryTestError: Error { case boom }

/// In-memory `DeliveryBackend` that records every call (mirrors the project's
/// `@unchecked Sendable` mock style; tests await each call so access is serial).
final class SpyDeliveryBackend: DeliveryBackend, @unchecked Sendable {
    var configured: Bool
    var shouldThrow = false

    private(set) var registerCalls: [(registration: DeviceTokenRegistration, userKey: String)] = []
    private(set) var unregisterCalls: [(token: String, userKey: String)] = []
    private(set) var upsertedJobs: [(job: DeliveryJob, userKey: String)] = []
    private(set) var cancelledJobs: [(capsuleID: UUID, userKey: String)] = []
    private(set) var deleteAllCalls: [String] = []

    init(configured: Bool = true) { self.configured = configured }

    var isConfigured: Bool { configured }

    func registerToken(_ registration: DeviceTokenRegistration, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        registerCalls.append((registration, userKey))
    }
    func unregisterToken(_ token: String, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        unregisterCalls.append((token, userKey))
    }
    func upsertJob(_ job: DeliveryJob, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        upsertedJobs.append((job, userKey))
    }
    func cancelJob(capsuleID: UUID, userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        cancelledJobs.append((capsuleID, userKey))
    }
    func deleteAll(userKey: String) async throws {
        if shouldThrow { throw DeliveryTestError.boom }
        deleteAllCalls.append(userKey)
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
