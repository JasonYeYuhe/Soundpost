import Foundation
import Observation
import UserNotifications
import UIKit

/// App-level glue for local notifications: requests permission, reconciles the
/// scheduled set with the current capsules (via the 64-nearest planner), and
/// turns a notification tap into a deep link to the capsule.
@MainActor
@Observable
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    /// Set when a notification is tapped; ContentView observes this to navigate.
    var pendingDeepLinkCapsuleID: UUID?

    /// Cloud-backed delivery reconciler (M10 §S3). Injected by the app; nil under
    /// tests/previews, where only the local path runs. Reconciled in lockstep with
    /// the local notification sync so routing is recomputed at the same points.
    var sealDelivery: SealDeliveryService?

    private let center = UNUserNotificationCenter.current()
    private let scheduler: NotificationScheduler

    /// Key the content-free server push carries so the app can dedup/deep-link.
    nonisolated static let capsulePushKey = "capsule_id"

    override init() {
        scheduler = NotificationScheduler(center: UNUserNotificationCenter.current())
        super.init()
        center.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            // Cloud-backed delivery (M10 §S1): once the user has allowed alerts,
            // register for remote notifications so the APNs token reaches the
            // server. Inert until the backend is configured (S2/S3); the local
            // path keeps working regardless. The OS mints the token and the
            // AppDelegate forwards it to `DeliveryRegistrar`.
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }

    /// Reconcile pending notifications with the current capsules: sealed ones
    /// resurfacing on their date, and captured ones echoing back later.
    func sync(capsules: [Capsule], now: Date = .now) async {
        let plan = NotificationPlanner.plan(capsules: capsules, now: now)
        let createdAt = Dictionary(
            capsules.map { ($0.id, $0.createdAt) },
            uniquingKeysWith: { first, _ in first }
        )
        await scheduler.reconcile(plan: plan) { item in
            switch item.kind {
            case .seal:
                return (
                    String(localized: "A capsule has resurfaced"),
                    String(localized: "Open Soundpost to hear this moment again.")
                )
            case .echo:
                let days = max(
                    1,
                    Calendar.current.dateComponents(
                        [.day],
                        from: createdAt[item.capsuleID] ?? item.fireDate,
                        to: item.fireDate
                    ).day ?? 1
                )
                return (
                    String(localized: "An echo from your past"),
                    String(localized: "\(days) days ago, you captured this sound. Listen back.")
                )
            }
        }

        // Reconcile the far-seal job set with the server in lockstep with the
        // local plan (no-op when signed out / backend unconfigured).
        await sealDelivery?.reconcile(capsules: capsules, now: now)
    }

    // MARK: Delivery-time dedup

    /// The capsule UUID a notification refers to — from our local request
    /// identifier, else the server push's `capsule_id` userInfo. Pure, so callable
    /// from the `nonisolated` delegate callbacks.
    nonisolated static func capsuleID(of notification: UNNotification) -> UUID? {
        NotificationScheduler.capsuleID(fromIdentifier: notification.request.identifier)
            ?? capsuleID(fromPushUserInfo: notification.request.content.userInfo)
    }

    /// Parse the capsule UUID a server push carries in its `capsule_id` userInfo.
    nonisolated static func capsuleID(fromPushUserInfo userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[capsulePushKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// True if this is our content-free server push (carries `capsule_id`).
    nonisolated static func isServerPush(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo[capsulePushKey] != nil
    }

    /// Which of `identifiers` are this capsule's local **seal** requests — the set
    /// a server push dedups away. Pure, so the dedup rule is unit-testable.
    nonisolated static func localSealIdentifiers(for capsuleID: UUID, among identifiers: [String]) -> [String] {
        let prefix = "\(NotificationScheduler.identifierPrefix)\(capsuleID.uuidString)|seal|"
        return identifiers.filter { $0.hasPrefix(prefix) }
    }

    /// Remove any pending OR delivered LOCAL seal request for `capsuleID`, so a
    /// server push that already arrived doesn't also let a local backstop fire —
    /// the hard, delivery-time dedup guarantee (§4). Every device does this.
    func removeLocalSealRequests(for capsuleID: UUID) async {
        let pending = Self.localSealIdentifiers(
            for: capsuleID, among: await center.pendingNotificationRequests().map(\.identifier))
        if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }
        let delivered = Self.localSealIdentifiers(
            for: capsuleID, among: await center.deliveredNotifications().map(\.request.identifier))
        if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // On our server push, drop any local backstop for the same capsule first.
        if Self.isServerPush(notification), let uuid = Self.capsuleID(of: notification) {
            await self.removeLocalSealRequests(for: uuid)
        }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let notification = response.notification
        guard let uuid = Self.capsuleID(of: notification) else { return }
        if Self.isServerPush(notification) {
            await self.removeLocalSealRequests(for: uuid)
        }
        await MainActor.run { self.pendingDeepLinkCapsuleID = uuid }
    }
}
