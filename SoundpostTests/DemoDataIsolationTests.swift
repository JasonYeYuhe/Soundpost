import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// The DEBUG demo library must never touch the user's real iCloud.
///
/// **This is a guard over a bug that actually happened.** `DemoData.container` was
/// built with `ModelConfiguration(isStoredInMemoryOnly: true)` and nothing else. That
/// reads as "a throwaway store, obviously local", and it is not: `cloudKitDatabase`
/// defaults to `.automatic`, and because the app carries the iCloud entitlement
/// SwiftData spins up a mirroring delegate for an in-memory store too. Every
/// `-seedSampleData` launch therefore **exported six fabricated capsules into
/// whichever real iCloud account the machine was signed into**, and the production
/// container imported them back as ordinary capsules — in the person's own gallery,
/// on every device they own.
///
/// `SoundpostModelContainer` carries this lesson in its own rung 2 ("`.none` is
/// load-bearing, not tidiness") because the same defaulting once turned its local
/// fallback into a second CloudKit store. The demo container never got the line.
///
/// It stayed invisible because it is DEBUG-only, it needs an iCloud-signed-in
/// machine, and its symptom — a few extra capsules — looks like the user's own data.
/// It surfaced only when someone read a device's SQLite store directly while testing
/// something else.
@MainActor
struct DemoDataIsolationTests {

    /// **The claim `DemoData.seed`'s own comment makes** (M19 §4A / §10).
    ///
    /// That comment reasons at length that the fifth sample deliberately has no note
    /// *precisely so* the card renders "Soundpost heard …", because "without that, a
    /// screenshot build would show none of this milestone at all and would
    /// misrepresent the app". **It was false on every clean machine from M17 until
    /// M19.** Every reveal surface is gated on `mayReveal` — `isEnabled && hasStanding`
    /// — and `hasStanding` is set only on the production launch path, from
    /// `answered || hasRecordedHere`. A seeded library is neither answered nor
    /// recorded, so the line never appeared and the four screenshots in the store have
    /// been photographing an app from before 1.6.0.
    ///
    /// This is the assertion that comment needed. It runs the real seeding into a real
    /// context and asks the real display policy, with standing granted the way
    /// `DemoData.container` now grants it — so the thing under test is the whole
    /// arrangement, not a rephrasing of it.
    ///
    /// The task-local suite stands in for the `-seedSampleData` launch argument, which
    /// a test process cannot set. It is the same seam `SoundAnalysisPreferences`
    /// already uses, and it keeps the grant out of this machine's real preferences.
    @Test func theDemoLibraryActuallyRendersAHeardLine() throws {
        let context = try LargeLibrary.makeStore()
        let suite = "demo-standing-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        try SoundAnalysisPreferences.$defaultsSuiteName.withValue(suite) {
            // The premise, stated first: with no standing there is nothing to show.
            // Without it this test could pass because the grant happened somewhere
            // else, or because the gate had been removed.
            #expect(!SoundAnalysisPreferences.mayReveal)

            DemoData.grantStandingForScreenshots()
            DemoData.seed(into: context)
            try context.save()
            #expect(SoundAnalysisPreferences.mayReveal)

            let capsules = try context.fetch(FetchDescriptor<Capsule>())
            let noteless = capsules.filter {
                ($0.note ?? "").isEmpty && $0.isContentVisible(now: .now)
            }
            #expect(!noteless.isEmpty, "the demo library has no note-less visible capsule")

            let lines = noteless.compactMap {
                SoundprintDisplay.sentence(for: $0, on: .card, rejecting: .none)
            }
            #expect(!lines.isEmpty, """
                No demo capsule renders a "Soundpost heard" line. That is the claim \
                DemoData.seed's comment makes, and a screenshot build would photograph \
                the app as it was before 1.6.0.
                """)
            #expect(lines.allSatisfy { !$0.isEmpty })
        }
    }

    /// And the almanac card, which is the surface M19 added and the one most likely to
    /// be photographed empty: the demo library's anniversary capsule has no note, so
    /// its line is the heard one.
    @Test func theDemoAnniversaryCardHasSomethingToSay() throws {
        let context = try LargeLibrary.makeStore()
        let suite = "demo-almanac-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        try SoundAnalysisPreferences.$defaultsSuiteName.withValue(suite) {
            DemoData.grantStandingForScreenshots()
            DemoData.seed(into: context)
            try context.save()

            let entries = Almanac.entries(among: try context.fetch(FetchDescriptor<Capsule>()))
            #expect(entries.count == 1, "the demo library seeds exactly one anniversary")
            let entry = try #require(entries.first)
            let line = Almanac.line(for: entry, rejecting: .none)
            guard case .heard(let sentence)? = line else {
                Issue.record("the demo anniversary card says \(String(describing: line))")
                return
            }
            #expect(!sentence.isEmpty)
        }
    }

    /// The assertion the fix is: this configuration is explicitly opted out of
    /// CloudKit, rather than relying on a default that means the opposite.
    @Test func theDemoLibraryIsNotMirroredToCloudKit() throws {
        let source = try demoDataSource()
        let call = try #require(
            source.range(of: "ModelConfiguration(isStoredInMemoryOnly: true"),
            "DemoData no longer builds its container the way this guard expects")
        let tail = source[call.lowerBound...].prefix(220)
        #expect(tail.contains("cloudKitDatabase: .none"), """
            DemoData.container omits `cloudKitDatabase: .none`. `isStoredInMemoryOnly` \
            does NOT imply it — the parameter defaults to `.automatic`, and with the \
            iCloud entitlement present SwiftData will mirror this store, exporting \
            fabricated demo capsules into a real person's iCloud.
            """)
    }

    /// And the reason the check reads source rather than behaviour: whether a store
    /// mirrors is decided inside SwiftData at load time and is not observable from a
    /// test without an iCloud account. A guard that could only fail on a signed-in
    /// machine would be no guard at all on CI — which is exactly where this needs to
    /// fail. So it asserts the one line, and asserts it is looking at a real file.
    @Test func theGuardIsPointedAtARealFile() throws {
        let source = try demoDataSource()
        #expect(source.contains("enum DemoData"),
                "this guard is not reading DemoData.swift any more, so it checks nothing")
    }

    private func demoDataSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundpostTests/
            .deletingLastPathComponent()   // repo root
        let url = root.appending(path: "Soundpost/DemoData.swift")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "DemoData.swift has moved; this guard is now checking nothing")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
