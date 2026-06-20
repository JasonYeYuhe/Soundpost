import UIKit
import UserNotifications
import os

/// Thin `@UIApplicationDelegateAdaptor`. SwiftUI has no first-class hook for
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, so this
/// owns **only** the APNs registration handshake (token in / failure). Foreground
/// presentation + notification-tap routing stay with `NotificationCoordinator`
/// (the `UNUserNotificationCenterDelegate`); this class is deliberately *not*
/// that delegate, so the two never fight over the same callbacks.
final class SoundpostAppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `SoundpostApp` on launch so the token callbacks can reach the
    /// registrar. Weak: the App owns the registrar's lifetime.
    @MainActor static weak var registrar: DeliveryRegistrar?

    private let log = Logger(subsystem: "com.soundpost.Soundpost", category: "delivery")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Reconcile the APNs token every cold launch (cli-pulse pattern): iOS
        // only re-fires didRegister when the token actually *changes*, but a
        // token that rotated while the app was uninstalled leaves the server
        // stale until we ask again. `registerForRemoteNotifications` is a cheap
        // local OS call; the OS itself decides whether to mint a token from the
        // user's settings — so we only ask when already authorized. The
        // first-run grant flow (NotificationCoordinator) triggers the very first
        // registration at the right product moment.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in application.registerForRemoteNotifications() }
            case .denied, .notDetermined:
                break
            @unknown default:
                break
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        log.info("APNs registration succeeded (\(deviceToken.count, privacy: .public) bytes)")
        Task { @MainActor in
            await Self.registrar?.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on most dev installs (no aps-environment entitlement,
        // simulator without an Apple ID, a transient network blip). INFO, then
        // fall back to the local notification path — delivery only *enhances*.
        log.info("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}
