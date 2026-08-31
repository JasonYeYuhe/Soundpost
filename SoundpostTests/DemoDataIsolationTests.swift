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
