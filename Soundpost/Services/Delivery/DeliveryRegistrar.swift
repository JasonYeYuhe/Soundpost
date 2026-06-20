import Foundation
import os

/// Owns the device-token side of cloud-backed delivery: takes the APNs token
/// from the AppDelegate, pairs it with the per-user delivery key, and upserts it
/// to the backend — with a **pending-token cache** so a token that arrives
/// before the key is ready (signed out / pre-handshake / backend not yet wired)
/// is replayed the moment it becomes available (the cli-pulse pending-token
/// pattern, docs/M10-DEVPLAN.md §B/§F). Job routing is a separate concern (S3).
@MainActor
@Observable
final class DeliveryRegistrar {
    private let backend: DeliveryBackend
    private let identity: DeliveryIdentityProviding
    private let bundleID: String
    private let environment: String
    private let log = Logger(subsystem: "com.soundpost.Soundpost", category: "delivery")

    /// The token confirmed-registered under the *current* key (hex). Memory-only:
    /// reset each launch (so the first flush re-registers — token reconciliation)
    /// and cleared on sign-out / account switch so a re-register fires. Within a
    /// launch it dedupes repeat flushes to **one upsert per (key, token)**.
    private(set) var registeredToken: String?

    /// The most recent token we were asked to register, retained so it can be
    /// replayed when the key/backend becomes available *and* re-sent under a new
    /// key on an Apple-ID switch.
    private var lastRegistration: DeviceTokenRegistration?

    /// The user key the current `registeredToken` was registered under. Kept so
    /// `signOut()` can prune this device's token even after the account is gone
    /// (the identity key resolves to nil once signed out, §4A).
    private var lastUserKey: String?

    init(
        backend: DeliveryBackend = UnconfiguredDeliveryBackend(),
        identity: DeliveryIdentityProviding = CloudKitDeliveryIdentity(),
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.soundpost.Soundpost",
        environment: String = DeliveryEnvironment.current
    ) {
        self.backend = backend
        self.identity = identity
        self.bundleID = bundleID
        self.environment = environment
    }

    /// Entry point from the AppDelegate's `didRegister…DeviceToken`.
    func handleDeviceToken(_ data: Data) async {
        await register(hexToken: PushTokenSync.formatToken(data))
    }

    /// Validate, wrap, and attempt to register a hex token; caches it for replay
    /// if the key isn't ready yet.
    func register(hexToken: String) async {
        guard PushTokenSync.isValidTokenLength(hexToken) else {
            log.info("Ignoring APNs token of unexpected length")
            return
        }
        lastRegistration = DeviceTokenRegistration(
            token: hexToken,
            platform: PushTokenSync.platform,
            environment: environment,
            bundleID: bundleID
        )
        await flushPending()
    }

    /// Send the retained token if it isn't already registered under the current
    /// key. No-op (stays retained) if nothing has been registered yet, the
    /// backend isn't configured (S1 stub), or the user is signed out — so the
    /// token survives until the next launch / sign-in / account resolve.
    ///
    /// Reentrancy-safe: this @MainActor method can be re-entered across the two
    /// `await`s (e.g. a launch flush overlapping a sign-in flush). The key-fetch
    /// is followed by a recheck, then the token is **claimed synchronously**
    /// (no `await` between the recheck and the claim) before the network call,
    /// so two overlapping flushes can never both reach `registerToken` for the
    /// same (key, token) — guaranteeing exactly one upsert. The claim is
    /// released if the send fails, so a real failure still retries.
    func flushPending() async {
        guard let registration = lastRegistration else { return }
        guard backend.isConfigured else { return }                 // S1 stub: stay retained
        guard registeredToken != registration.token else { return } // already current
        guard let userKey = await identity.currentUserKey() else { return } // signed out: stay retained
        guard registeredToken != registration.token else { return } // a racing flush won
        registeredToken = registration.token                       // claim before the await
        do {
            try await backend.registerToken(registration, userKey: userKey)
            lastUserKey = userKey
        } catch {
            // Release the claim so the next launch / sign-in retries.
            if registeredToken == registration.token { registeredToken = nil }
            log.info("Token register failed; will retry on next launch or sign-in")
        }
    }

    /// Sign-in (or identity-became-available) hook: replay any cached token.
    func identityDidBecomeAvailable() async {
        await flushPending()
    }

    /// Apple-ID switch: forget the old account's registration + cached key, then
    /// re-register this device under the new user (§F).
    func accountDidChange() async {
        registeredToken = nil
        await identity.accountDidChange()
        await flushPending()
    }

    /// Sign-out: prune **only this device's token**. The user-scoped jobs are
    /// deliberately left intact so the user's other signed-in devices keep
    /// receiving pushes (§4A). Uses the *last registered* key (not the live one,
    /// which is already nil once signed out) so the prune actually authenticates;
    /// if that's gone too, the server prunes later via 410 / the staleness sweep.
    func signOut() async {
        let token = registeredToken
        let userKey = lastUserKey
        registeredToken = nil
        lastUserKey = nil
        guard backend.isConfigured, let token, let userKey else { return }
        try? await backend.unregisterToken(token, userKey: userKey)
    }
}
