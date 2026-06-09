import SwiftUI
import SwiftData

/// App entry point.
@main
struct SoundpostApp: App {
    @State private var notifications = NotificationCoordinator()

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
            if AppEnvironment.isDemoSeed {
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
}
