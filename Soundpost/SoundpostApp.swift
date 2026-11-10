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
    /// bootstrap (M10 §S1). **Live in production**: the backend is configured in
    /// every shipped build (`SupabaseDeliveryConfig.current`), so a signed-in device
    /// registers its APNs token with the `cli-pulse` Supabase project. It stays
    /// quiet only while there is no iCloud account or delivery key, or after
    /// "Delete my cloud data".
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
        // The doors outside the view tree — the App Shortcut, the quick action — reach
        // the coordinator through this one hook, set before any scene connects (M20 §4F).
        CaptureRequests.coordinator = coordinator
        _notifications = State(initialValue: coordinator)
        // The APNs token callbacks reach the registrar through this hook, set here —
        // before any scene connects and before the delegate's launch-time settings read
        // can return — rather than in a view's `.task`, so no launch can deliver its
        // token to a registrar that is not there yet (M21 §4B).
        let tokenRegistrar = DeliveryRegistrar(backend: backend, identity: identity)
        SoundpostAppDelegate.registrar = tokenRegistrar
        _registrar = State(initialValue: tokenRegistrar)
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
            } else if let phase = ProductionSyncCheck.requestedPhase {
                // The production container on purpose: the point is what the REAL
                // store does with the REAL entitlement (M19 §8 item 2).
                Color.clear.task {
                    if let store { await ProductionSyncCheck.run(phase, in: store.container) }
                }
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
                // The widget's door (M22 §4C): its fixed URL sets the capture request and
                // nothing else. Outside the onboarding switch, so a tap during onboarding
                // is kept and the route makes it wait.
                .onOpenURL { CaptureDoor.open($0) }
                .modelContainer(store.container)
                .task { await runBackfill(store) }
                .task {
                    // The launch's privacy-critical order — consent before anything
                    // trusts the listening mirror, a re-sync after it, standing before
                    // the library is touched — lives in one tested type (M21 §4C).
                    // Nothing else runs here: a step added beside the sequence would
                    // escape its order.
                    await LaunchSequence(
                        store: store,
                        notifications: notifications,
                        registrar: registrar,
                        remoteChanges: remoteChanges,
                        accountChanges: accountChanges,
                        syncMonitor: syncMonitor
                    ).run()
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
    /// container — i.e. not under tests, the demo seed, or the self-tests (each of
    /// which uses its own store).
    ///
    /// Split by configuration because everything it excludes is **compiled out of a
    /// shipping build**. Those modes are reachable only through launch arguments, and
    /// an App Store app cannot be given launch arguments — so in Release the
    /// exclusions are not merely false, they do not exist. Keeping them non-DEBUG so
    /// that this one expression could name them was what put `-runAudioSelfTest` and
    /// `-runVideoSelfTest` into the shipping binary as dead strings, which
    /// `scripts/check-debug-only.sh` then had to be told to ignore. Better that the
    /// gate mean exactly what it says.
    static var usesProductionContainer: Bool {
        #if DEBUG
        !isRunningUnderTests && !isDemoSeed && !isAudioSelfTest && !isVideoSelfTest
        #else
        !isRunningUnderTests
        #endif
    }

    #if DEBUG
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
    #endif

    /// Which screen a screenshot run wants (M19 §4A), from `-screenshotScreen <name>`.
    ///
    /// The store's five screenshots were captured by hand on 2026-06-10 and never
    /// touched through eight releases. Nothing failed; there was no step that could.
    /// So the capture path is a script, and a script needs a way to reach a screen.
    ///
    /// **A launch argument, not a mockup.** §4A rule 3 says a screenshot may only show
    /// states the app actually produces, from the real UI, with real demo data. This
    /// enters the real views by setting the same state a tap would — it does not
    /// assemble a picture of them.
    #if DEBUG
    static var screenshotScreen: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-screenshotScreen"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    #endif

    #if DEBUG
    /// Debug-only: run the headless audio-pipeline self-test instead of the UI.
    static var isAudioSelfTest: Bool {
        CommandLine.arguments.contains("-runAudioSelfTest")
    }

    /// Debug-only: render a capsule to video and play it back for the human-gated
    /// device smoke test the simulator can't stand in for (M13 §5 S2).
    static var isVideoSelfTest: Bool {
        CommandLine.arguments.contains("-runVideoSelfTest")
    }
    #endif
}
