import SwiftUI
import SwiftData

/// App entry point.
@main
struct SoundpostApp: App {
    /// Owns only the APNs registration handshake (M10 §S1); the SwiftUI-native
    /// `NotificationCoordinator` keeps the presentation/tap delegate role.
    @UIApplicationDelegateAdaptor(SoundpostAppDelegate.self) private var appDelegate
    @State private var notifications: NotificationCoordinator
    @State private var syncMonitor = CloudSyncMonitor()

    /// The app's single playback owner (M16 §4A). Held here, above every screen that
    /// can play a capsule, so exactly one sound can be playing at a time.
    @State private var playback = PlaybackController()

    /// Cloud-backed delivery: device-token registration + per-user identity
    /// bootstrap (M10 §S1). Until the backend's config is filled in (after S2
    /// deploy), `SupabaseDeliveryBackend.isConfigured == false`, so this is inert
    /// in production — it caches the token and does no network work; the local
    /// path keeps working.
    @State private var registrar: DeliveryRegistrar

    /// The far-seal job reconciler (M10 §S3), sharing the same backend + identity
    /// as the registrar. Injected into `NotificationCoordinator` so server jobs
    /// reconcile in lockstep with the local notification sync.
    @State private var sealDelivery: SealDeliveryService

    /// On-device StoreKit 2 entitlement service for Soundpost Pro (M11). Inert
    /// until ASC products exist (ship-dormant — §0): `Product.products(for:)`
    /// returns empty and the paywall stays unreachable. `autoStart` is off under
    /// tests so the unit-test runner opens no StoreKit network client.
    @State private var storeService: StoreService

    /// The production SwiftData stack (CloudKit-mirrored), built once and retained
    /// for the app's lifetime. `nil` under tests / DEBUG demo / self-test — those
    /// paths use their own store and must never create the production (or a
    /// second) container for `Capsule`.
    private let store: ProductionStore?

    init() {
        // Crash/hang reporting. No-op without a SentryDSN; skipped under tests so
        // the unit-test runner never opens a network client.
        if !AppEnvironment.isRunningUnderTests {
            SentryBootstrap.start()
        }
        store = AppEnvironment.usesProductionContainer
            ? SoundpostModelContainer.makeProductionContainer()
            : nil

        // One backend + one identity shared by token registration (S1) and job
        // reconcile (S3), so the identity cache and backend config stay consistent.
        let identity = CloudKitDeliveryIdentity()
        let backend: DeliveryBackend = SupabaseDeliveryBackend()
        let coordinator = NotificationCoordinator()
        let delivery = SealDeliveryService(backend: backend, identity: identity)
        coordinator.sealDelivery = delivery
        _notifications = State(initialValue: coordinator)
        _registrar = State(initialValue: DeliveryRegistrar(backend: backend, identity: identity))
        _sealDelivery = State(initialValue: delivery)
        _storeService = State(initialValue: StoreService(autoStart: !AppEnvironment.isRunningUnderTests))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(notifications)
                .environment(syncMonitor)
                .environment(playback)
                .environment(registrar)
                .environment(storeService)
                // Hand the registrar to the AppDelegate so APNs token callbacks
                // can reach it. The register-on-launch reconciliation in the
                // delegate covers the brief race before this runs.
                .task { SoundpostAppDelegate.registrar = registrar }
        }
    }
}

/// Roots the UI and owns the SwiftData stack — but only outside of tests.
///
/// Under XCTest/Swift Testing the host app must NOT create a `ModelContainer`
/// for `Capsule`: each unit test spins up its own in-memory container, and two
/// containers for the same model in one process crash SwiftData. So when testing
/// we render nothing and create no store, leaving the test's container as the
/// single source of truth.
private struct RootView: View {
    /// The production stack from `SoundpostApp` (nil for the non-production paths).
    let store: ProductionStore?

    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(CloudSyncMonitor.self) private var syncMonitor
    @Environment(DeliveryRegistrar.self) private var registrar

    /// App-layer observer that reschedules notifications when CloudKit merges
    /// remote changes (M9 S4). Held in `@State` so it (and its NotificationCenter
    /// registration) outlives view-body evaluation and keeps firing in the
    /// background — the case the reactive `@Query` path can't cover.
    @State private var remoteChanges = RemoteChangeReconciler()

    /// App-layer observer that relinks/prunes the APNs token and reconciles
    /// far-seal jobs when the iCloud account changes (M10 §S4).
    @State private var accountChanges = DeliveryAccountObserver()

    /// One-shot first-run flag. (UserDefaults — declared in PrivacyInfo as CA92.1.)
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if AppEnvironment.isRunningUnderTests {
            Color.clear
        } else {
            #if DEBUG
            if AppEnvironment.isAudioSelfTest {
                Color.clear.task { await AudioSelfTest.run() }   // headless audio-pipeline check
            } else if AppEnvironment.isVideoSelfTest {
                VideoSelfTestView()                              // M13 §5 S2 device smoke test
            } else if AppEnvironment.isCloudKitSchemaSeed {
                // Materialise the CloudKit Development schema for any entity the app
                // has added since the last promotion (§11B-i). Uses the production
                // container on purpose — the point is the real CloudKit export.
                Color.clear.task {
                    if let store { await CloudKitSchemaSeed.run(in: store.container) }
                }
            } else if AppEnvironment.isDemoSeed {
                ContentView().modelContainer(DemoData.container) // screenshots skip onboarding
            } else {
                production
            }
            #else
            production
            #endif
        }
    }

    /// The real app, on the CloudKit-mirrored production container.
    @ViewBuilder
    private var production: some View {
        if let store {
            mainOrOnboarding
                .modelContainer(store.container)
                .task { await runBackfill(store) }
                .task {
                    // Start app-layer remote-change observation once (idempotent).
                    remoteChanges.start(container: store.container, notifications: notifications)
                    // React to iCloud account changes for cloud-backed delivery (M10 §S4).
                    accountChanges.start(container: store.container, notifications: notifications, registrar: registrar)
                    // Watch CloudKit sync health for honest, calm in-app copy (S5/S6).
                    syncMonitor.start(rung: store.rung)
                    // Reclaim video-export temp dirs a previous launch left behind
                    // (a crash, a kill, or a share sheet that never called back —
                    // M13 §4G). Nothing is in flight at launch, and it only ever
                    // removes children of our own export container.
                    VideoExportWorkspace.scavenge()
                    // Count — never delete — audio clips no capsule points at
                    // (M17 §4E). Until §S0 a capture sheet dismissed mid-take left
                    // one behind, and nothing in the app could see it: every
                    // existing check starts from capsule rows, so none of them can
                    // fail for a file no row names. This starts from the directory.
                    // Deleting on that rule would take the take the user is
                    // recording right now, whose row does not exist until save.
                    AudioOrphanAudit.report(in: store.container.mainContext)
                    // Adopt the account-wide listening answer before anything reads
                    // the local mirror (M15 §4I, revised). Ordering matters: the
                    // backfill below gates on that mirror, so a withdrawal made on
                    // another device has to land here first — otherwise this launch
                    // would re-label the very capsules the user cleared elsewhere.
                    let mayListen: Bool
                    do {
                        mayListen = try ListeningConsentStore.applyToDevice(in: store.container.mainContext)
                    } catch {
                        // Fail CLOSED, and only for this launch. The old comment said
                        // "using this device's answer" and then ran both drains anyway
                        // — but the whole reason this call exists is that the device's
                        // answer may be a stale default, so proceeding on it is exactly
                        // the case it was written to prevent. Nothing is written to the
                        // mirror here: this is a local decision to do no retrospective
                        // work until we can read the account, not a new answer.
                        mayListen = false
                        Diagnostics.notice("Could not read account-wide listening consent at launch; skipping this launch's analysis")
                    }
                    // Re-sync after consent is applied, as the merge path already does.
                    // A withdrawal that landed while the app was closed erases the
                    // stored labels, but an already-scheduled lock-screen body has its
                    // text baked in and the scheduler skips identifiers it has already
                    // scheduled — so without this the phrase Soundpost heard keeps
                    // firing on the lock screen after the switch was turned off.
                    // `NotificationPreferences.contentVersion` folds listening in for
                    // exactly this; it only works if something re-syncs.
                    await notifications.sync(capsules: (try? CapsuleStore(context: store.container.mainContext).all()) ?? [])
                    // Does this device have standing to analyse the EXISTING library?
                    //
                    // Distinct from "may we listen", and the distinction is the whole
                    // point. A phone set up as new and signed into iCloud imports the
                    // library long before the `ListeningConsent` row — CloudKit returns
                    // a zone's changes in roughly modification order, so the person who
                    // opted out most recently has their answer sorted behind every
                    // capsule they own. With no row yet, the mirror reads its default
                    // (on), and these two drains would analyse the entire library of
                    // somebody who had said no.
                    //
                    // A row settles it outright. Failing that, `hasRecordedHere` asks
                    // whether the mirror is an answer or a default — see its doc; the
                    // wipe that makes the mirror untrustworthy clears it too.
                    //
                    // Nothing is lost by waiting. A genuinely new user has no library
                    // to backfill, and capture-time analysis is deliberately NOT gated,
                    // so their first capsule is labelled as always. And because
                    // `soundprintRaw` syncs with the capsule, this pass is per-library
                    // work rather than per-device: a device that skips it is usually
                    // skipping work another device has already done.
                    let answered = (try? ListeningConsentStore.hasAnswer(in: store.container.mainContext)) ?? false
                    let mayScanLibrary = mayListen && (answered || SoundAnalysisPreferences.hasRecordedHere)
                    guard mayScanLibrary else {
                        Diagnostics.info("No standing to analyse the existing library yet — deferring until the account's answer arrives")
                        return
                    }
                    // Hand back the capsules an older generation of gates wrote off,
                    // before the backfill runs — reopening sets `soundprintRaw` to
                    // nil, which is exactly what the backfill below looks for, so
                    // the two compose in one launch instead of two (M15 §11E).
                    SoundprintRemediation.drain(in: store.container.mainContext)
                    // Give pre-M15 capsules their soundprints. Batched so peak memory
                    // stays one clip and capture keeps the device between batches
                    // (M15 §4H), but drained rather than stopped after one batch: the
                    // release notes say search finds your rainy mornings, and one
                    // batch per launch made that true only after about fifteen of them
                    // (§11H).
                    await SoundprintBackfill(modelContainer: store.container).drain()
                }
        } else {
            Color.clear // unreachable in practice; never crash if the store is missing
        }
    }

    /// Kick the one-shot file→Data backfill (S2) once the container is up. It
    /// runs on a background `@ModelActor`, no-ops when nothing matches, and is
    /// safe to run while the first CloudKit import is in flight.
    private func runBackfill(_ store: ProductionStore) async {
        let migrator = AudioMigrator(modelContainer: store.container)
        await migrator.backfillAudio()
    }

    @ViewBuilder
    private var mainOrOnboarding: some View {
        if hasCompletedOnboarding {
            ContentView()
        } else {
            OnboardingView { hasCompletedOnboarding = true }
        }
    }
}

enum AppEnvironment {
    /// True when the process is hosting a unit-test bundle.
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True only for the real app run that should build the production CloudKit
    /// container — i.e. not under tests, the demo seed, or the audio self-test
    /// (each of which uses its own store).
    static var usesProductionContainer: Bool {
        !isRunningUnderTests && !isDemoSeed && !isAudioSelfTest && !isVideoSelfTest
    }

    /// Debug-only: write one row per entity so CloudKit's Development environment
    /// materialises the record types, then clean up (§11B-i). Needs the production
    /// container, so it is deliberately absent from `usesProductionContainer`'s
    /// exclusions.
    static var isCloudKitSchemaSeed: Bool {
        CommandLine.arguments.contains("-initializeCloudKitSchema")
    }

    /// Debug screenshot/demo mode: in-memory store pre-seeded with sample capsules.
    static var isDemoSeed: Bool {
        CommandLine.arguments.contains("-seedSampleData")
    }

    /// Debug-only: run the headless audio-pipeline self-test instead of the UI.
    static var isAudioSelfTest: Bool {
        CommandLine.arguments.contains("-runAudioSelfTest")
    }

    /// Debug-only: render a capsule to video and play it back for the human-gated
    /// device smoke test the simulator can't stand in for (M13 §5 S2).
    static var isVideoSelfTest: Bool {
        CommandLine.arguments.contains("-runVideoSelfTest")
    }
}
