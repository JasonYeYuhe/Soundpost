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
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(notifications)
                .environment(syncMonitor)
                .environment(registrar)
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
        !isRunningUnderTests && !isDemoSeed && !isAudioSelfTest
    }

    /// Debug screenshot/demo mode: in-memory store pre-seeded with sample capsules.
    static var isDemoSeed: Bool {
        CommandLine.arguments.contains("-seedSampleData")
    }

    /// Debug-only: run the headless audio-pipeline self-test instead of the UI.
    static var isAudioSelfTest: Bool {
        CommandLine.arguments.contains("-runAudioSelfTest")
    }
}
