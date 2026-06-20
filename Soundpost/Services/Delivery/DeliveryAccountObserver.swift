import Foundation
import CloudKit
import SwiftData

/// Reacts to iCloud account changes for cloud-backed delivery (docs/M10-DEVPLAN.md
/// §4A/§F). CloudKit posts `CKAccountChanged` on sign-in, sign-out, and Apple-ID
/// switch; we can't tell which from the notification, so we read the current
/// account and branch:
///   * **signed out** → prune *only this device's* token (the user-scoped jobs are
///     left intact so the user's other devices keep delivering);
///   * **signed in / switched** → re-key the identity and re-register the token
///     under the new user (the server's `ON CONFLICT(token)` transfers ownership),
///     then reconcile the far-seal jobs under the new identity.
///
/// Lives at the app layer (a plain `NotificationCenter` observer alive while
/// backgrounded), mirroring `RemoteChangeReconciler`.
@MainActor
final class DeliveryAccountObserver {
    private var token: NSObjectProtocol?
    private var center: NotificationCenter?
    private var onChange: (() async -> Void)?

    /// Register for `CKAccountChanged` with an action. Idempotent.
    func observe(onAccountChange: @escaping () async -> Void, center: NotificationCenter = .default) {
        guard token == nil else { return }
        self.onChange = onAccountChange
        self.center = center
        token = center.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.handle() }
        }
    }

    /// Production wiring: on an account change, relink/prune the token and
    /// reconcile jobs under the (possibly new) identity.
    func start(
        container: ModelContainer,
        notifications: NotificationCoordinator,
        registrar: DeliveryRegistrar,
        center: NotificationCenter = .default
    ) {
        observe(onAccountChange: { [weak notifications, weak registrar] in
            guard let registrar else { return }
            if FileManager.default.ubiquityIdentityToken == nil {
                await registrar.signOut()          // prune this device's token only
            } else {
                await registrar.accountDidChange()  // re-key + re-register (transfer on switch)
            }
            guard let notifications else { return }
            let capsules = (try? CapsuleStore(context: container.mainContext).all()) ?? []
            await notifications.sync(capsules: capsules) // reconcile under the new identity
        }, center: center)
    }

    @discardableResult
    func handle() -> Task<Void, Never>? {
        guard let onChange else { return nil }
        return Task { @MainActor in await onChange() }
    }

    func stop() {
        if let token { (center ?? .default).removeObserver(token) }
        token = nil
        center = nil
        onChange = nil
    }
}
