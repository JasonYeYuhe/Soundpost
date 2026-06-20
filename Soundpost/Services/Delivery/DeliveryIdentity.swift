import Foundation
import CloudKit

/// Resolves the per-user **delivery key**: a high-entropy secret stored in the
/// user's CloudKit *private* database, so it syncs only to that user's devices
/// and survives reinstall on a signed-in device. It is both the server **user
/// key** (the fan-out group for the user's tokens/jobs) and the **bearer** the
/// app presents to the backend — because only the user's devices possess it, no
/// caller can spoof another user's delivery (docs/M10-DEVPLAN.md §B).
///
/// Resolution is **async + fallible**: signed-out / pre-handshake ⇒ no key ⇒ the
/// caller falls back to the local path. Abstracted behind a protocol so the
/// registrar's logic is unit-testable without an iCloud account.
protocol DeliveryIdentityProviding: Sendable {
    /// The current user's delivery key, or `nil` when unavailable (signed out,
    /// pre-account, or a transient CloudKit failure). Never throws — "no key" is
    /// a normal, expected state that routes the caller to local delivery.
    func currentUserKey() async -> String?

    /// Drop any cached key so the next resolve re-reads the (possibly new)
    /// account's private DB. Called on an Apple-ID switch (`CKAccountChanged`).
    func accountDidChange() async
}

extension DeliveryIdentityProviding {
    func accountDidChange() async {}
}

/// Production `DeliveryIdentityProviding` backed by CloudKit. Fetches (or, on
/// first use, creates) a single `DeliveryIdentity` record in the **private DB's
/// default zone** — distinct from the custom zone `NSPersistentCloudKitContainer`
/// uses for capsules (M9), so the two never collide. Uses the same container id
/// as the M9 store so the key lives in the user's existing iCloud container.
actor CloudKitDeliveryIdentity: DeliveryIdentityProviding {
    private let container: CKContainer
    private let recordType = "DeliveryIdentity"
    private let recordName = "delivery-identity"
    private let keyField = "userKey"

    /// In-memory cache of the resolved key, plus the iCloud account it belongs
    /// to. Binding the key to the account means a stale key can never be served
    /// after an Apple-ID switch even if `accountDidChange()` is somehow missed —
    /// the next resolve sees a different `ubiquityIdentityToken` and drops it.
    private var cachedKey: String?
    private var cachedAccount: (any NSObjectProtocol)?

    /// Coalesces concurrent resolves into a single CloudKit round-trip: actors
    /// are re-entrant across `await`, so without this two cache-miss callers
    /// could each fetch/create the record.
    private var resolution: Task<String?, Never>?

    private var db: CKDatabase { container.privateCloudDatabase }

    init(containerID: String = SoundpostModelContainer.cloudKitContainerID) {
        self.container = CKContainer(identifier: containerID)
    }

    func currentUserKey() async -> String? {
        let account = FileManager.default.ubiquityIdentityToken
        // Invalidate a cache that belongs to a different (or no) account.
        if !Self.sameAccount(cachedAccount, account) {
            cachedKey = nil
            cachedAccount = nil
            resolution?.cancel()
            resolution = nil
        }
        if let cachedKey { return cachedKey }
        guard account != nil else { return nil }   // signed out: no key, local path

        // Share one in-flight resolution among all concurrent callers.
        if let resolution { return await resolution.value }
        let task = Task<String?, Never> { await self.resolve() }
        resolution = task
        let key = await task.value
        resolution = nil
        return key
    }

    private func resolve() async -> String? {
        guard (try? await container.accountStatus()) == .available else { return nil }
        let account = FileManager.default.ubiquityIdentityToken
        let recordID = CKRecord.ID(recordName: recordName)
        do {
            let existing = try await db.record(for: recordID)
            if let key = existing[keyField] as? String, !key.isEmpty {
                cachedKey = key
                cachedAccount = account
                return key
            }
            // Record exists but is malformed — repair it in place (it carries a
            // valid change tag, so the save will succeed).
            return await save(existing, account: account)
        } catch let error as CKError where error.code == .unknownItem {
            // No record yet — create one.
            return await save(CKRecord(recordType: recordType, recordID: recordID), account: account)
        } catch {
            // Transient CloudKit failure — no key this time; caller uses local.
            return nil
        }
    }

    /// Write a fresh random key onto `record`, resolving the two-devices-write-
    /// at-once race by adopting whichever key the server kept (or repairing it).
    private func save(_ record: CKRecord, account: (any NSObjectProtocol)?) async -> String? {
        let key = Self.generateKey()
        record[keyField] = key as CKRecordValue
        do {
            _ = try await db.save(record)
            cachedKey = key
            cachedAccount = account
            return key
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Adopt the server's valid key so every device shares one group…
            if let server = error.serverRecord?[keyField] as? String, !server.isEmpty {
                cachedKey = server
                cachedAccount = account
                return server
            }
            // …or repair the server's malformed record (it has the change tag).
            if let serverRecord = error.serverRecord {
                serverRecord[keyField] = key as CKRecordValue
                if let saved = try? await db.save(serverRecord),
                   let healed = saved[keyField] as? String, !healed.isEmpty {
                    cachedKey = healed
                    cachedAccount = account
                    return healed
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func accountDidChange() async {
        cachedKey = nil
        cachedAccount = nil
        resolution?.cancel()
        resolution = nil
    }

    /// 256 bits of cryptographically-secure randomness, hex-encoded — the
    /// delivery key / bearer. `SystemRandomNumberGenerator` is documented as
    /// cryptographically secure on Apple platforms.
    static func generateKey() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }
            .joined()
    }

    /// Account-token equality (both nil ⇒ signed out on both sides ⇒ equal).
    private static func sameAccount(_ a: (any NSObjectProtocol)?, _ b: (any NSObjectProtocol)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.isEqual(y)
        default: return false
        }
    }
}
