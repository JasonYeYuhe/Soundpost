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

    /// A request to open capture from outside the app's own doors — an App Shortcut or
    /// the Home Screen quick action (M20 §4F). ContentView drains it once the gallery
    /// exists (`CaptureLaunchRoute`).
    ///
    /// **The newest request wins, and this and a notification link are never both
    /// live.** Both live here, on one main-actor owner, so "newest" is simply whichever
    /// was set last: asking for capture drops a link still waiting for its capsule, and
    /// a notification tap drops a capture request still waiting for the gallery.
    private(set) var pendingCaptureRequest = false

    /// Ask for capture (the intent, the quick action). Drops a waiting link: left
    /// pending under the capture sheet, it would fire when its capsule imported — or
    /// when the user's own capture saved and the library grew.
    func requestCapture() {
        pendingCaptureRequest = true
        pendingDeepLinkCapsuleID = nil
    }

    /// A notification was tapped. Drops a waiting capture request: the person went
    /// somewhere else after asking.
    func openFromNotification(_ capsuleID: UUID) {
        pendingDeepLinkCapsuleID = capsuleID
        pendingCaptureRequest = false
    }

    /// Capture is on screen; the request has been honoured.
    func consumeCaptureRequest() {
        pendingCaptureRequest = false
    }

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
    /// `.notDetermined` there is a question that is about to be asked. **Capture's echo
    /// never asks; capture's seal option asks when its date is confirmed, as the seal
    /// sheet does** (M20 §4E). Onboarding asks too, and has a Skip button — so
    /// `.notDetermined` beside the capture *echo* means nothing on that path will ever
    /// ask, the echo is scheduled into a permission the app does not hold, and
    /// `UNUserNotificationCenter` drops it silently. Promising there is the untruth `canPromiseAReminder` was
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

    /// Numbers each `sync` in the order it was *called*, on the main actor, before any
    /// suspension — the scheduler's notion of "newest plan" (M20 §4D).
    private var syncGeneration = 0

    /// Key the content-free server push carries so the app can dedup/deep-link.
    nonisolated static let capsulePushKey = "capsule_id"

    override init() {
        scheduler = NotificationScheduler(center: UNUserNotificationCenter.current())
        super.init()
        center.delegate = self
    }

    #if DEBUG
    /// Test seam (M21 §4B): drive the real `sync` against a stand-in centre, so a test
    /// can see what it schedules — `UNUserNotificationCenter` cannot be constructed or
    /// stubbed. Does not become the system centre's delegate: the test host's app
    /// already holds that role.
    init(center scheduling: UserNotificationScheduling, delivery: SealDeliveryService?) {
        scheduler = NotificationScheduler(center: scheduling)
        super.init()
        sealDelivery = delivery
    }
    #endif

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
        // First, before anything can suspend: this call's place among all syncs.
        syncGeneration += 1
        let generation = syncGeneration
        // The local plan first, and without waiting on the network (offline-first).
        await planAndReconcile(capsules: capsules, in: context, now: now, generation: generation)

        // Reconcile the far-seal job set with the server in lockstep with the
        // local plan (no-op when signed out / backend unconfigured).
        guard let sealDelivery,
              await sealDelivery.reconcile(capsules: capsules, in: context, now: now) else { return }

        // **A delivery change re-plans, from fresh data** (M21 §4B). The plan above
        // read `serverJobSyncedAt` before the server was asked, so whatever the
        // reconcile just changed is not in it — and the case that matters most is a far
        // seal entering its last day: the plan left it out (the server owned it), then
        // the reconcile cancelled its job and handed it back. Nothing re-planned, so if
        // the app was not opened again before the day, neither the push nor the local
        // reminder fired.
        //
        // Never from `capsules`: that array was taken before the network wait, and a
        // sync that ran meanwhile may have changed the library (a capture saved, a
        // capsule deleted). This plan gets a new, higher number — it is the newest
        // look at the store, so it is right for it to win over any sync that started
        // during the wait; over the stale array it would have overwritten a newer plan.
        let fresh: [Capsule]
        do {
            fresh = try fetchCapsulesForReplan(context)
        } catch {
            // Abandon, never plan from `[]`: an empty plan would remove every pending
            // request. The schedule stays as the plan above left it, and the next sync
            // re-plans.
            Diagnostics.notice("Could not re-read capsules after a delivery change; keeping the current schedule",
                               code: (error as NSError).code)
            return
        }
        syncGeneration += 1
        await planAndReconcile(capsules: fresh, in: context, now: now, generation: syncGeneration)
    }

    /// Where the re-plan reads the library from. A seam only so a test can make the
    /// fetch fail (SwiftData offers no supported way to); production reads the store.
    @ObservationIgnored
    var fetchCapsulesForReplan: (ModelContext) throws -> [Capsule] = { try CapsuleStore(context: $0).all() }

    /// Plan the local notifications for `capsules` and reconcile the scheduler to the
    /// plan under `generation`. One function for the first pass and the re-plan, so the
    /// two cannot drift apart.
    private func planAndReconcile(capsules: [Capsule], in context: ModelContext,
                                  now: Date, generation: Int) async {
        let plan = NotificationPlanner.plan(capsules: capsules, now: now)
        let personalized = NotificationPreferences.personalized
        // The rule every card uses (M22 §4E): a heard phrase is shown only while
        // listening is on AND this device has standing. It used to read `isEnabled`
        // alone, and only for the content version — the digest carried the stored label
        // whatever either said, so a phone with no standing could put on its lock screen
        // a label its own cards hid.
        let reveal = Self.notificationsMayRevealHeardSounds

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

        let digests = Self.digests(for: capsules, rejections: rejections, reveal: reveal)
        await scheduler.reconcile(
            plan: plan,
            // `reveal` here too, so a body scheduled while labels could be shown is
            // re-issued when they no longer can (and back): `p1` ↔ `p1n`.
            contentVersion: NotificationPreferences.contentVersion(personalized: personalized, listening: reveal),
            generation: generation
        ) { item in
            NotificationCopy.make(for: item, digest: digests[item.capsuleID], personalized: personalized)
        }
    }

    /// Whether a notification body may lead with what Soundpost heard: the cards' rule,
    /// `SoundAnalysisPreferences.mayReveal` (listening on and standing).
    static var notificationsMayRevealHeardSounds: Bool { SoundAnalysisPreferences.mayReveal }

    /// The copy inputs for each capsule. A soundprint is included only when `reveal` is
    /// true and the corrections could be read — never otherwise, because a body is baked
    /// in when it is scheduled and shown on a lock screen.
    static func digests(for capsules: [Capsule], rejections: RejectionIndex?,
                        reveal: Bool) -> [UUID: NotificationCopy.Digest] {
        Dictionary(
            capsules.map {
                ($0.id, NotificationCopy.Digest(
                    createdAt: $0.createdAt,
                    note: $0.note,
                    placeName: $0.place?.name,
                    mood: $0.mood,
                    // Only ever a *fallback* for the lead phrase, and only consulted
                    // when `personalized` is on (M15 §S5).
                    soundprint: (rejections == nil || !reveal) ? nil : Soundprint(stored: $0.soundprintRaw),
                    rejected: rejections?.sounds(for: $0.id) ?? .none
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
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
        await MainActor.run { self.openFromNotification(uuid) }
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
