import Foundation
import Observation
import UserNotifications
import SwiftData
import UIKit

/// App-level glue for local notifications: requests permission, reconciles the
/// scheduled set with the current capsules (via the 64-nearest planner), and
/// turns a notification tap into a deep link to the capsule.
@MainActor
@Observable
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    /// Set when a notification is tapped; ContentView observes this to navigate.
    var pendingDeepLinkCapsuleID: UUID?

    /// Whether the OS currently permits Soundpost to post an alert. `nil` until it
    /// has been read once.
    ///
    /// **Read on becoming active, never cached from launch.** Authorization is async
    /// and the user can revoke it in Settings while the app is backgrounded, so a
    /// value taken once at startup goes stale in exactly the case that matters — and
    /// the app would go on offering to "notify you on 14 March 2027" when it has been
    /// told it may not (M17 §S4).
    ///
    /// Nothing in the app read `notificationSettings()` at all before this: the one
    /// existing call site is `SoundpostAppDelegate`, which uses it to decide whether
    /// to re-register for APNs and hands the answer to no view.
    private(set) var authorizationStatus: UNAuthorizationStatus?

    /// Whether a dated reminder is a promise the app can still keep.
    ///
    /// `.notDetermined` counts as *yes*, and deliberately: sealing asks for
    /// permission as part of the flow, so warning someone about a refusal that has
    /// not happened — and probably will not — would be its own small untruth. Only an
    /// outright denial is a state where the app knows, before saying anything, that
    /// nothing will arrive.
    var canPromiseAReminder: Bool { authorizationStatus != .denied }

    /// Whether a reminder scheduled **right now** would actually be delivered.
    ///
    /// Stricter than `canPromiseAReminder`, and the difference is which screen is
    /// asking. The seal sheet requests authorization as part of its own flow, so
    /// `.notDetermined` there is a question that is about to be asked. **Capture never
    /// asks** — onboarding does, and onboarding has a Skip button — so `.notDetermined`
    /// on the capture sheet means nothing on that path will ever ask, the echo is
    /// scheduled into a permission the app does not hold, and `UNUserNotificationCenter`
    /// drops it silently. Promising there is the untruth `canPromiseAReminder` was
    /// written to avoid, arriving through the other door (Codex, M17 review).
    ///
    /// Unread (`nil`) promises, deliberately: not knowing yet is not the same as
    /// knowing it is off, and claiming otherwise would be its own false statement.
    var remindersWouldBeDelivered: Bool {
        guard let authorizationStatus else { return true }
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    /// Refresh `authorizationStatus`. Cheap, local, and safe to call on every
    /// foreground.
    func refreshAuthorization() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

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
        // The answer we just got IS the current state; re-reading it would be a
        // second round trip to learn what this call already returned.
        authorizationStatus = granted ? .authorized : .denied
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
    /// resurfacing on their date, and captured ones echoing back later. Bodies are
    /// built by the pure `NotificationCopy` (metadata-only — never faults audio),
    /// personalized when the user opted in (§S3/§4A, default off). The current
    /// personalized *and listening* states are folded into each request's identity
    /// via `contentVersion`, so flipping either re-issues every owned request
    /// rather than leaving a stale body baked on the lock screen (§S3 P0).
    /// - Parameter context: the store to read corrections from — **one scoped fetch
    ///   per sync**, not one per capsule (M18 §4B). A context rather than a threaded
    ///   index because there are eleven call sites and every one of them already has
    ///   one; asking each to build the index would have been eleven chances to pass
    ///   `.none` and eleven places for a stale lock-screen body to come from.
    func sync(capsules: [Capsule], in context: ModelContext, now: Date = .now) async {
        let plan = NotificationPlanner.plan(capsules: capsules, now: now)
        let personalized = NotificationPreferences.personalized
        let listening = SoundAnalysisPreferences.isEnabled

        // **A failed read suppresses every heard phrase rather than showing them
        // all.** If the corrections cannot be read we do not know which labels were
        // dismissed, and the two ways to be wrong are not symmetric: a generic body
        // is calm and true, while a body carrying a phrase its owner rejected is
        // rule 1 failing on a lock screen, where they cannot ask a follow-up
        // question. So the soundprint is dropped from every digest and the copy falls
        // back to what it says when there is nothing to lead with (§4C).
        let rejections: RejectionIndex?
        do {
            rejections = try SoundRejectionStore.index(forCapsules: capsules.map(\.id),
                                                       in: context, now: now)
        } catch {
            rejections = nil
            Diagnostics.notice("Could not read sound corrections while rebuilding notification copy",
                               code: (error as NSError).code)
        }

        let digests = Dictionary(
            capsules.map {
                ($0.id, NotificationCopy.Digest(
                    createdAt: $0.createdAt,
                    note: $0.note,
                    placeName: $0.place?.name,
                    mood: $0.mood,
                    // Only ever a *fallback* for the lead phrase, and only consulted
                    // when `personalized` is on (M15 §S5).
                    soundprint: rejections == nil ? nil : Soundprint(stored: $0.soundprintRaw),
                    rejected: rejections?.sounds(for: $0.id) ?? .none
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        await scheduler.reconcile(
            plan: plan,
            contentVersion: NotificationPreferences.contentVersion(personalized: personalized, listening: listening)
        ) { item in
            NotificationCopy.make(for: item, digest: digests[item.capsuleID], personalized: personalized)
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

#if DEBUG
extension NotificationCoordinator {
    /// Test seam: stand in a given authorization state without a live notification
    /// centre. `UNUserNotificationCenter` cannot be constructed or stubbed, and
    /// `notificationSettings()` reports whatever the test *host* happens to be
    /// authorized for — which is a property of the simulator, not of this code.
    func setAuthorizationForTesting(_ status: UNAuthorizationStatus) {
        authorizationStatus = status
    }
}
#endif
