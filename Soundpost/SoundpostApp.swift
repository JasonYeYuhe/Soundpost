import SwiftUI
import SwiftData

/// App entry point.
@main
struct SoundpostApp: App {
    @State private var notifications = NotificationCoordinator()

    /// The production SwiftData stack (CloudKit-mirrored, S3), built once and
    /// retained for the app's lifetime so the file→Data backfill (S2) can run
    /// against it and remote CloudKit changes can be observed (S4). `nil` under
    /// tests / DEBUG demo / self-test — those paths use their own store and must
    /// never create the production (or a second) container for `Capsule`.
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
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(notifications)
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
