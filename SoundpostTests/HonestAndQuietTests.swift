import CloudKit
import Foundation
import SwiftUI
import Testing
@testable import Soundpost

/// M21 §4E: the edit sheet and Settings say only what is true with notifications off,
/// an offline phone is not reported as a fault, and the dormant store retry retries.
@MainActor
@Suite("Honest and quiet")
struct HonestAndQuietTests {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The catalog key a `LocalizedStringKey` was built with — its `==` does not compare
    /// what a test needs to know (`CaptureSealTests.catalogKey`).
    private func catalogKey(_ key: LocalizedStringKey?) -> String? {
        key.flatMap { Mirror(reflecting: $0).children.first { $0.label == "key" }?.value as? String }
    }

    private let offSentence = "Notifications are off, so this won't reach you until you turn them on."

    // MARK: The edit sheet's reminder

    /// "Remind me of this later" in the edit sheet now says so when the reminder will
    /// not arrive — capture's own sentence, by capture's own rule.
    @Test func theEditSheetSaysWhenAnEchoWillNotArrive() throws {
        #expect(catalogKey(CapsuleEditSheet.echoNotice(remindersWouldBeDelivered: false)) == offSentence)
        #expect(CapsuleEditSheet.echoNotice(remindersWouldBeDelivered: true) == nil,
                "capture's other sentence is about 'today', which an edit is not")

        let capture = try source("Soundpost/Capture/CaptureView.swift")
        #expect(capture.contains("\"\(offSentence)\""), "the sheet no longer shares capture's sentence")
    }

    /// The rule is the stricter one: editing an echo never asks for permission, so an
    /// undecided permission is not a promise here (M17's `EchoPromiseTests`).
    @Test func theEditSheetDecidesByWhetherTheReminderWouldBeDelivered() throws {
        let sheet = try source("Soundpost/Views/CapsuleEditSheet.swift")
        #expect(sheet.contains("@Environment(NotificationCoordinator.self)"))
        #expect(sheet.contains("echoNotice(remindersWouldBeDelivered: notifications.remindersWouldBeDelivered)"))
        #expect(!sheet.contains("canPromiseAReminder"))
    }

    // MARK: Settings › Delete my cloud data

    /// "Far-future reminders fall back to this device's local schedule" is true only
    /// while notifications are on; the sentence now says so.
    @Test func theCloudDeleteSentenceHoldsWithNotificationsOff() throws {
        let settings = try source("Soundpost/Views/SettingsView.swift")
        #expect(settings.contains("which can alert you only while notifications are on for Soundpost."))
        #expect(!settings.contains("fall back to this device's local schedule.\")"),
                "the unqualified promise is back")
    }

    // MARK: An offline phone is not a fault

    private func wrapped(_ ck: CKError.Code, depth: Int = 1) -> NSError {
        var error: NSError = CKError(ck) as NSError
        for level in 0..<depth {
            error = NSError(domain: NSCocoaErrorDomain, code: 134_421 + level,
                            userInfo: [NSUnderlyingErrorKey: error])
        }
        return error
    }

    @Test func anOfflinePhoneIsLoggedNotReported() {
        let monitor = CloudSyncMonitor()
        var sent: [CloudSyncMonitor.ErrorReport] = []
        var logged: [CloudSyncMonitor.ErrorReport] = []
        monitor.sendReport = { sent.append($0) }
        monitor.logOffline = { logged.append($0) }

        monitor.apply(error: CKError(.networkUnavailable), finished: true)   // what 1.10.0 sent
        monitor.apply(error: wrapped(.networkFailure), finished: true)
        monitor.apply(error: wrapped(.networkUnavailable, depth: 2), finished: true)
        monitor.apply(error: wrapped(.zoneBusy), finished: true)
        // A real fault with a network error somewhere beneath it is still a real fault.
        let busy = NSError(domain: CKErrorDomain, code: CKError.Code.serverRejectedRequest.rawValue,
                           userInfo: [NSUnderlyingErrorKey: CKError(.networkFailure)])
        monitor.apply(error: busy, finished: true)

        #expect(sent.map(\.cloudKitCode) == [CKError.Code.zoneBusy.rawValue,
                                             CKError.Code.serverRejectedRequest.rawValue],
                "an offline phone was reported to Sentry as a fault, or a real fault was not")
        #expect(logged.count == 3, "the local log line was dropped too")
        #expect(monitor.state == .unknown, "an offline blip changed the calm state")
    }

    // MARK: The dormant store retry

    @Test func aFailedProductLoadIsRetriedUntilItSucceeds() async {
        let store = StoreService(autoStart: false)
        var calls = 0
        await store.loadProducts(using: { _ in
            calls += 1
            if calls < 3 { throw URLError(.notConnectedToInternet) }
            return []
        }, pause: { _ in })
        #expect(calls == 3, "the retry never ran")
        #expect(store.loadError == nil)
        #expect(!store.isLoading)
    }

    @Test func aProductLoadThatKeepsFailingStopsAfterFiveTries() async {
        let store = StoreService(autoStart: false)
        var calls = 0
        await store.loadProducts(using: { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }, pause: { _ in })
        #expect(calls == 5)
        #expect(store.loadError != nil)
        #expect(!store.isLoading)
    }
}
