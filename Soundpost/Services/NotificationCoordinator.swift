import Foundation
import Observation
import UserNotifications

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
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Reconcile pending notifications with the capsules that are sealed in the future.
    func sync(capsules: [Capsule], now: Date = .now) async {
        let plan = NotificationPlanner.plan(capsules: capsules, now: now)
        await scheduler.reconcile(
            plan: plan,
            title: String(localized: "A capsule has resurfaced"),
            body: String(localized: "Open Soundpost to hear this moment again.")
        )
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
        let identifier = response.notification.request.identifier
        guard identifier.hasPrefix(NotificationScheduler.identifierPrefix) else { return }
        let uuidString = String(identifier.dropFirst(NotificationScheduler.identifierPrefix.count))
        guard let uuid = UUID(uuidString: uuidString) else { return }
        await MainActor.run { self.pendingDeepLinkCapsuleID = uuid }
    }
}
