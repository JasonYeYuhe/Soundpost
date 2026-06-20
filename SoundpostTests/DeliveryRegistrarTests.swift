import Testing
import Foundation
@testable import Soundpost

// Shared test doubles live in DeliveryTestSupport.swift (SpyDeliveryBackend /
// StubDeliveryIdentity) so the S1 + S3 suites use one mock that covers the full
// DeliveryBackend protocol (token + job methods).
private typealias MockBackend = SpyDeliveryBackend
private typealias MockIdentity = StubDeliveryIdentity

// MARK: - Pure helpers

struct PushTokenSyncTests {
    @Test func formatTokenLowercaseHex() {
        #expect(PushTokenSync.formatToken(Data([0x00, 0x1a, 0xff, 0x09])) == "001aff09")
        #expect(PushTokenSync.formatToken(Data()) == "")
    }

    @Test func tokenLengthBounds() {
        #expect(!PushTokenSync.isValidTokenLength(""))
        #expect(!PushTokenSync.isValidTokenLength("abcdef"))                       // 6 < 8
        #expect(PushTokenSync.isValidTokenLength(String(repeating: "a", count: 8)))
        #expect(PushTokenSync.isValidTokenLength(String(repeating: "a", count: 64)))
        #expect(PushTokenSync.isValidTokenLength(String(repeating: "a", count: 256)))
        #expect(!PushTokenSync.isValidTokenLength(String(repeating: "a", count: 257)))
    }

    @Test func environmentIsDevelopmentUnderDebugTests() {
        // The unit-test bundle builds in Debug, so the build-config rule must
        // select the APNs sandbox environment.
        #expect(DeliveryEnvironment.current == "development")
    }

    @Test func generatedKeysAreUniqueHex256() {
        let a = CloudKitDeliveryIdentity.generateKey()
        let b = CloudKitDeliveryIdentity.generateKey()
        #expect(a.count == 64)                 // 32 bytes → 64 hex chars
        #expect(a != b)
        #expect(a.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - Registrar behaviour

@MainActor
struct DeliveryRegistrarTests {
    private let token = String(repeating: "a", count: 64)

    @Test func registersTokenWhenKeyAndBackendAvailable() async {
        let backend = MockBackend(configured: true)
        let registrar = DeliveryRegistrar(
            backend: backend, identity: MockIdentity(key: "USERKEY"),
            bundleID: "com.soundpost.Soundpost", environment: "production"
        )

        await registrar.register(hexToken: token)

        #expect(backend.registerCalls.count == 1)
        let call = backend.registerCalls[0]
        #expect(call.registration.token == token)
        #expect(call.registration.platform == "ios")
        #expect(call.registration.environment == "production")
        #expect(call.registration.bundleID == "com.soundpost.Soundpost")
        #expect(call.userKey == "USERKEY")
        #expect(registrar.registeredToken == token)
    }

    @Test func tokenIsHexEncodedFromRawData() async {
        let backend = MockBackend(configured: true)
        let registrar = DeliveryRegistrar(backend: backend, identity: MockIdentity(key: "K"))
        // 32 bytes so the hex passes the length check.
        await registrar.handleDeviceToken(Data(repeating: 0xAB, count: 32))
        #expect(backend.registerCalls.first?.registration.token == String(repeating: "ab", count: 32))
    }

    @Test func cachesWhenSignedOutThenReplaysOnSignIn() async {
        let backend = MockBackend(configured: true)
        let identity = MockIdentity(key: nil)                 // signed out
        let registrar = DeliveryRegistrar(backend: backend, identity: identity, environment: "production")

        await registrar.register(hexToken: token)
        #expect(backend.registerCalls.isEmpty)                // cached, not sent
        #expect(registrar.registeredToken == nil)

        identity.key = "USERKEY"                              // sign in
        await registrar.identityDidBecomeAvailable()
        #expect(backend.registerCalls.count == 1)             // replayed exactly once
        #expect(registrar.registeredToken == token)
    }

    @Test func staysCachedWhenBackendNotConfigured() async {
        let backend = MockBackend(configured: false)          // S1 stub
        let registrar = DeliveryRegistrar(backend: backend, identity: MockIdentity(key: "USERKEY"))

        await registrar.register(hexToken: token)
        #expect(backend.registerCalls.isEmpty)
        #expect(registrar.registeredToken == nil)

        backend.configured = true                             // backend lands (S3)
        await registrar.flushPending()
        #expect(backend.registerCalls.count == 1)
    }

    @Test func oneUpsertPerKeyAndToken() async {
        let backend = MockBackend(configured: true)
        let registrar = DeliveryRegistrar(backend: backend, identity: MockIdentity(key: "K"))

        await registrar.register(hexToken: token)
        await registrar.flushPending()                        // repeat flush, same (key, token)
        await registrar.identityDidBecomeAvailable()

        #expect(backend.registerCalls.count == 1)             // deduped to a single upsert
        #expect(backend.unregisterCalls.isEmpty)
    }

    @Test func registerFailureKeepsRetained() async {
        let backend = MockBackend(configured: true)
        backend.shouldThrow = true
        let registrar = DeliveryRegistrar(backend: backend, identity: MockIdentity(key: "K"))

        await registrar.register(hexToken: token)
        #expect(registrar.registeredToken == nil)             // not marked registered

        backend.shouldThrow = false
        await registrar.flushPending()                        // retry succeeds
        #expect(backend.registerCalls.count == 1)
        #expect(registrar.registeredToken == token)
    }

    @Test func signOutPrunesOnlyThisDeviceToken() async {
        let backend = MockBackend(configured: true)
        let registrar = DeliveryRegistrar(backend: backend, identity: MockIdentity(key: "K"))
        await registrar.register(hexToken: token)
        #expect(registrar.registeredToken == token)

        await registrar.signOut()

        #expect(backend.unregisterCalls.count == 1)           // exactly this device's token
        #expect(backend.unregisterCalls[0].token == token)
        #expect(registrar.registeredToken == nil)
    }

    @Test func signOutPrunesUsingLastKeyEvenAfterTheAccountIsGone() async {
        // Register while signed in, then the account disappears (key → nil).
        let backend = MockBackend(configured: true)
        let identity = MockIdentity(key: "K")
        let registrar = DeliveryRegistrar(backend: backend, identity: identity)
        await registrar.register(hexToken: token)
        identity.key = nil                                    // signed out: live key gone

        await registrar.signOut()

        // The prune still authenticates with the last-registered key.
        #expect(backend.unregisterCalls.count == 1)
        #expect(backend.unregisterCalls[0].userKey == "K")
        #expect(backend.unregisterCalls[0].token == token)
        #expect(registrar.registeredToken == nil)
    }

    @Test func accountChangeReRegistersUnderNewKey() async {
        let backend = MockBackend(configured: true)
        let identity = MockIdentity(key: "OLDKEY")
        let registrar = DeliveryRegistrar(backend: backend, identity: identity)

        await registrar.register(hexToken: token)
        #expect(backend.registerCalls.last?.userKey == "OLDKEY")

        identity.key = "NEWKEY"                               // Apple-ID switch
        await registrar.accountDidChange()

        #expect(identity.accountChangeCount == 1)
        #expect(backend.registerCalls.count == 2)
        #expect(backend.registerCalls.last?.userKey == "NEWKEY")
        #expect(registrar.registeredToken == token)
    }

    @Test func shortTokenIsIgnored() async {
        let backend = MockBackend(configured: true)
        let registrar = DeliveryRegistrar(backend: backend, identity: MockIdentity(key: "K"))
        await registrar.register(hexToken: "abc")             // below the 8-char floor
        #expect(backend.registerCalls.isEmpty)
        #expect(registrar.registeredToken == nil)
    }
}
