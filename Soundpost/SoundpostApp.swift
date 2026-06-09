import SwiftUI
import SwiftData

/// App entry point.
@main
struct SoundpostApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
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
            ContentView()
                .modelContainer(for: Capsule.self)
        }
    }
}

enum AppEnvironment {
    /// True when the process is hosting a unit-test bundle.
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
