import SwiftUI
import SwiftData

/// App entry point.
@main
struct SoundpostApp: App {
    @State private var notifications = NotificationCoordinator()

    init() {
        // Crash/hang reporting. No-op without a SentryDSN; skipped under tests so
        // the unit-test runner never opens a network client.
        if !AppEnvironment.isRunningUnderTests {
            SentryBootstrap.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
    var body: some View {
        if AppEnvironment.isRunningUnderTests {
            Color.clear
        } else {
            #if DEBUG
            if AppEnvironment.isAudioSelfTest {
                Color.clear.task { await AudioSelfTest.run() }   // headless audio-pipeline check
            } else if AppEnvironment.isDemoSeed {
                ContentView().modelContainer(DemoData.container)
            } else {
                ContentView().modelContainer(for: Capsule.self)
            }
            #else
            ContentView().modelContainer(for: Capsule.self)
            #endif
        }
    }
}

enum AppEnvironment {
    /// True when the process is hosting a unit-test bundle.
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
