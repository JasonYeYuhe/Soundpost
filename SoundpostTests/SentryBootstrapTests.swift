import Testing
import Foundation
@testable import Soundpost

/// What an automatic Sentry breadcrumb may carry (`SentryBootstrap.breadcrumbDataAllowlist`).
/// The inputs are the shapes sentry-cocoa 8.58 actually builds, copied from its trackers.
struct SentryBootstrapTests {

    /// `SentryBreadcrumbTracker.fetchInfoAboutViewController:` — the detail screen's
    /// title is the capsule's mood.
    @Test func aScreenBreadcrumbKeepsItsClassButNotItsTitle() {
        let scrubbed = SentryBootstrap.scrubbedBreadcrumbData([
            "screen": "UIHostingController<CapsuleDetailView>",
            "title": "Calm",
            "beingPresented": "false",
            "parentViewController": "UINavigationController",
        ])
        #expect(scrubbed as NSDictionary? == [
            "screen": "UIHostingController<CapsuleDetailView>",
            "beingPresented": "false",
            "parentViewController": "UINavigationController",
        ] as NSDictionary)
    }

    /// `extractDataFromView:` — a view's description includes a label's text, a button's
    /// title is its text, and nothing structural is left once those go.
    @Test func aTouchBreadcrumbLosesEveryViewDetail() {
        let scrubbed = SentryBootstrap.scrubbedBreadcrumbData([
            "view": "<UILabel: 0x1; text = 'the café we loved'>",
            "tag": 3,
            "accessibilityIdentifier": "note-field",
            "title": "Save",
        ])
        #expect(scrubbed == nil)
    }

    /// `SentryNetworkTracker` — a URL and its query can carry anything; method and status
    /// cannot.
    @Test func aNetworkBreadcrumbKeepsStatusButNotAddress() {
        let scrubbed = SentryBootstrap.scrubbedBreadcrumbData([
            "url": "https://example.supabase.co/rest/v1/rpc/upsert_job",
            "http.query": "q=rain",
            "http.fragment": "x",
            "method": "POST",
            "status_code": 200,
        ])
        #expect(scrubbed as NSDictionary? == ["method": "POST", "status_code": 200] as NSDictionary)
    }

    @Test func aKeyTheSDKAddsLaterIsDroppedByDefault() {
        #expect(SentryBootstrap.scrubbedBreadcrumbData(["someFutureKey": "value"]) == nil)
        #expect(SentryBootstrap.scrubbedBreadcrumbData(nil) == nil)
    }

    /// The scrubber only matters if `start()` installs it, and `start()` never runs in a
    /// DEBUG test host. So this reads the source, as the other install-only guards here do.
    @Test func startInstallsTheScrubber() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/SentryBootstrap.swift")
        try #require(FileManager.default.fileExists(atPath: url.path), "SentryBootstrap.swift moved; this checks nothing")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let start = try #require(code.range(of: "static func start()"), "start() not found")
        let body = String(code[start.upperBound...].prefix(2000))
        #expect(body.contains("options.beforeBreadcrumb"))
        #expect(body.contains("crumb.data = scrubbedBreadcrumbData(crumb.data)"))
        // And on every outgoing event, for crumbs a crash report stored before the
        // allowlist existed.
        #expect(body.contains("event.breadcrumbs?.forEach { $0.data = scrubbedBreadcrumbData($0.data) }"))
    }
}
