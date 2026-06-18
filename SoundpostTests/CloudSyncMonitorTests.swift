import Testing
import Foundation
import CloudKit
@testable import Soundpost

/// M9 §S5: CloudKit edge cases are surfaced as a calm state, never as a "broken"
/// error. Signed-out and over-quota become quiet notes; every other sync error
/// is logged, not shown. The local app keeps working regardless.
@MainActor
struct CloudSyncMonitorTests {

    @Test func signedOutIsSurfaced() {
        #expect(CloudSyncMonitor.surfacedState(for: CKError(.notAuthenticated)) == .signedOut)
    }

    @Test func quotaExceededIsSurfaced() {
        #expect(CloudSyncMonitor.surfacedState(for: CKError(.quotaExceeded)) == .quotaExceeded)
    }

    @Test func transientAndForeignErrorsAreNotSurfaced() {
        #expect(CloudSyncMonitor.surfacedState(for: CKError(.networkUnavailable)) == nil)
        #expect(CloudSyncMonitor.surfacedState(for: CKError(.serviceUnavailable)) == nil)
        #expect(CloudSyncMonitor.surfacedState(for: NSError(domain: "x", code: 7)) == nil)
    }

    @Test func applyTracksSyncLifecycle() {
        let monitor = CloudSyncMonitor()
        #expect(monitor.state == .unknown)

        monitor.apply(error: nil, finished: false)
        #expect(monitor.state == .syncing)

        monitor.apply(error: nil, finished: true)
        #expect(monitor.state == .ok)

        monitor.apply(error: CKError(.notAuthenticated), finished: true)
        #expect(monitor.state == .signedOut)

        monitor.apply(error: CKError(.quotaExceeded), finished: true)
        #expect(monitor.state == .quotaExceeded)
    }

    /// A transient, non-surfaced error must not clobber a known state — honest
    /// copy shouldn't flicker on a network blip.
    @Test func transientErrorPreservesPriorState() {
        let monitor = CloudSyncMonitor()
        monitor.apply(error: CKError(.quotaExceeded), finished: true)
        monitor.apply(error: CKError(.networkUnavailable), finished: true)
        #expect(monitor.state == .quotaExceeded)
    }
}
