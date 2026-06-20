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

    private let center = UNUserNotificationCenter.current()
    private let scheduler: NotificationScheduler

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
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let uuid = NotificationScheduler.capsuleID(
            fromIdentifier: response.notification.request.identifier
        ) else { return }
        await MainActor.run { self.pendingDeepLinkCapsuleID = uuid }
    }
}
