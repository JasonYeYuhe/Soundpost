import Foundation
import SwiftData
import Testing
@testable import Soundpost

/// The library stays where it is (M23 §4D).
///
/// Both on-disk rungs pass `groupContainer: .none`, so a later App Group (M24's widget)
/// cannot move the store: under the default `.automatic`, SwiftData resolves into the first
/// App Group the app is entitled to and copies the store there. Nothing here builds a
/// container — `ModelConfiguration.url` says where a configuration resolves.
struct StoreLocationTests {
    /// Built independently of `ModelConfiguration`, so the comparison cannot be a URL
    /// compared with itself.
    private static let todaysStore = URL.applicationSupportDirectory.appending(path: "default.store")

    /// Rung 1 (`true`, CloudKit `.automatic`) and rung 2 (`false`, `.none`).
    private static func database(_ mirrored: Bool) -> ModelConfiguration.CloudKitDatabase {
        mirrored ? .automatic : .none
    }

    /// (a) Each on-disk rung resolves to `Application Support/default.store`.
    @Test(arguments: [true, false])
    func theOnDiskStoreIsInApplicationSupport(mirrored: Bool) {
        let url = SoundpostModelContainer.onDiskConfiguration(cloudKit: Self.database(mirrored)).url
        #expect(url.standardizedFileURL == Self.todaysStore.standardizedFileURL, "\(url.path)")
    }

    /// (b) The pin is a no-op for every existing install: it resolves exactly where the
    /// unpinned configuration 1.12.0 shipped resolves in a host with no App Group.
    @Test(arguments: [true, false])
    func thePinIsWhereTheShippedStoreAlreadyIs(mirrored: Bool) {
        let shipped = ModelConfiguration(schema: SoundpostModelContainer.productionSchema,
                                         cloudKitDatabase: Self.database(mirrored))
        let pinned = SoundpostModelContainer.onDiskConfiguration(cloudKit: Self.database(mirrored))
        #expect(pinned.url.standardizedFileURL == shipped.url.standardizedFileURL,
                "\(pinned.url.path) vs \(shipped.url.path)")
    }

    // MARK: (c) The census — no on-disk configuration escapes the pin

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift file under the app's folder, comment lines removed.
    private static func appSources() throws -> [(path: String, code: String)] {
        let base = repo.appending(path: "Soundpost")
        let walker = try #require(FileManager.default.enumerator(atPath: base.path))
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            out.append(("Soundpost/\(relative)", code))
        }
        return out
    }

    /// The text of every `ModelConfiguration(…)` call, up to its matching parenthesis.
    private static func configurationCalls(in code: String) -> [String] {
        var calls: [String] = []
        var rest = code[...]
        while let start = rest.range(of: "ModelConfiguration(") {
            var depth = 0
            var end = start.upperBound
            for index in rest[start.lowerBound...].indices {
                let ch = rest[index]
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1; if depth == 0 { end = rest.index(after: index); break } }
            }
            calls.append(String(rest[start.lowerBound..<end]))
            rest = rest[end...]
        }
        return calls
    }

    @Test func everyOnDiskConfigurationIsPinnedAndBothRungsUseThePin() throws {
        let sources = try Self.appSources()
        let container = try #require(sources.first { $0.path == "Soundpost/Services/SoundpostModelContainer.swift" },
                                     "the census did not find SoundpostModelContainer.swift; it checks nothing")
        // Both on-disk rungs, and nothing else, build their configuration through the pin.
        let pinCalls = sources.flatMap { file in
            file.code.split(separator: "\n")
                .filter { $0.contains("onDiskConfiguration(") && !$0.contains("func onDiskConfiguration(") }
                .map { "\(file.path): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        #expect(pinCalls.count == 2, "\(pinCalls)")
        #expect(pinCalls.allSatisfy { $0.hasPrefix(container.path) }, "\(pinCalls)")
        #expect(pinCalls.contains { $0.contains("cloudKit: .automatic") }, "\(pinCalls)")
        #expect(pinCalls.contains { $0.contains("cloudKit: .none") }, "\(pinCalls)")
        // Every configuration in the app is either in memory or pinned to no group.
        let calls = sources.flatMap { file in Self.configurationCalls(in: file.code).map { (file.path, $0) } }
        try #require(calls.contains { $0.0 == container.path }, "no ModelConfiguration( found; the census read nothing")
        for (path, call) in calls {
            let inMemory = call.contains("isStoredInMemoryOnly: true")
            let pinned = call.contains("groupContainer: .none")
            #expect(inMemory || pinned, "\(path): an on-disk configuration without groupContainer: .none — \(call)")
        }
    }
}
