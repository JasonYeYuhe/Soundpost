import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M19 §4B / S1 — turning this project's performance claims into measurements.
///
/// **What this suite deliberately does not do is assert a duration.** The obvious
/// test — "filtering 4,000 capsules must take under 200 ms" — is a coin flip on this
/// machine. `VideoGateTests.playbackStaysFree` already fails locally for
/// environmental reasons, and a neighbouring project building against the same
/// simulator once stretched a two-second suite to 1500 seconds while every test
/// still passed. A gate that flakes gets disabled, and a disabled gate leaves what
/// it guarded unguarded — which is worse than never having written it.
///
/// So the assertions here are **integers and ratios**:
///
/// * a *ratio* between two sizes measured back to back on the same machine, where a
///   loaded CPU slows both halves and cancels out, and only a change in algorithmic
///   shape moves the number;
/// * *counts* of fetches and index builds, which do not vary with load at all.
///
/// Durations are printed as diagnostics so a human can look at them. Nothing asserts
/// on them.
@MainActor
@Suite(.serialized)
struct LargeLibraryPerformanceTests {

    /// Best of three. One sample is at the mercy of a GC pause or another process
    /// waking up; the minimum of three is the closest cheap estimate of "how long
    /// this takes when the machine is not interfering", which is the quantity the
    /// ratio is about.
    private func bestOfThree(_ body: () -> Void) -> Duration {
        var best = Duration.seconds(3600)
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let taken = clock.measure(body)
            if taken < best { best = taken }
        }
        return best
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    // MARK: Growth — the shape, not the speed

    /// Quadrupling the library must not multiply the work by sixteen.
    ///
    /// The bound is deliberately loose. A linear walk gives ~4×; the failure this
    /// exists to catch is an accidental O(n²) — a `first(where:)` inside the filter,
    /// a rejection lookup that scans instead of hashing — which gives ~16×. Anything
    /// under 10× is a pass, which leaves a wide margin for measurement noise while
    /// still being unable to accommodate quadratic growth.
    @Test func filteringTheLibraryGrowsLinearlyNotQuadratically() throws {
        let small = try LargeLibrary.makeStore()
        let large = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 1_000, rejectingEvery: 7, in: small)
        try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, in: large)

        let smallRows = try small.fetch(FetchDescriptor<Capsule>())
        let largeRows = try large.fetch(FetchDescriptor<Capsule>())
        let smallIndex = try SoundRejectionStore.index(in: small)
        let largeIndex = try SoundRejectionStore.index(in: large)
        let criteria = GalleryFilter.Criteria(searchText: "rain")

        let t1 = bestOfThree {
            _ = GalleryFilter.apply(smallRows, criteria, rejecting: smallIndex, listening: true)
        }
        let t4 = bestOfThree {
            _ = GalleryFilter.apply(largeRows, criteria, rejecting: largeIndex, listening: true)
        }

        let ratio = seconds(t4) / max(seconds(t1), 1e-9)
        print("""
            M19 §4B  GalleryFilter.apply
              1,000 capsules: \(String(format: "%.2f", seconds(t1) * 1000)) ms
              4,000 capsules: \(String(format: "%.2f", seconds(t4) * 1000)) ms
              ratio: \(String(format: "%.2f", ratio))×  (linear ≈ 4, quadratic ≈ 16)
            """)
        #expect(ratio < 10, "4× the capsules cost \(String(format: "%.1f", ratio))× the time — that is not a linear walk")
        // And the premise: the filter is actually doing work, not returning early.
        #expect(!GalleryFilter.apply(largeRows, criteria, rejecting: largeIndex, listening: true).isEmpty)
    }

    /// The same question for resolving rejections, which is the part M18 §4B moved
    /// out of the render path on the argument that it would otherwise be quadratic.
    @Test func resolvingRejectionsGrowsLinearlyInTheNumberOfRows() throws {
        let small = try LargeLibrary.makeStore()
        let large = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 1_000, rejectingEvery: 1, in: small)
        try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 1, in: large)

        let smallRows = try small.fetch(FetchDescriptor<SoundRejection>())
        let largeRows = try large.fetch(FetchDescriptor<SoundRejection>())
        #expect(smallRows.count == 1_000 && largeRows.count == 4_000)

        let t1 = bestOfThree { _ = SoundRejectionStore.index(among: smallRows) }
        let t4 = bestOfThree { _ = SoundRejectionStore.index(among: largeRows) }

        let ratio = seconds(t4) / max(seconds(t1), 1e-9)
        print("""
            M19 §4B  SoundRejectionStore.index(among:)
              1,000 rows: \(String(format: "%.2f", seconds(t1) * 1000)) ms
              4,000 rows: \(String(format: "%.2f", seconds(t4) * 1000)) ms
              ratio: \(String(format: "%.2f", ratio))×
            """)
        #expect(ratio < 10)
    }

    /// **The lookup, isolated — and this is the one with teeth.**
    ///
    /// The end-to-end filter test above is a smoke test with a deliberately loose
    /// bound, and a control experiment proved it is too loose to be relied on alone:
    /// replacing `RejectionIndex`'s hash lookup with a linear scan moved that ratio
    /// only from 3.9× to 6.6× and sailed through, because the string matching in the
    /// filter dilutes the quadratic term.
    ///
    /// So this asks the index about every capsule and nothing else. With a hash
    /// lookup the work is O(n) and the ratio tracks the input; with a scan it is
    /// O(n·k) and the ratio squares. Nothing else is in the measurement to hide it.
    @Test func askingTheIndexAboutEveryCapsuleGrowsLinearly() throws {
        let small = try LargeLibrary.makeStore()
        let large = try LargeLibrary.makeStore()
        let smallIDs = try LargeLibrary.seed(capsules: 1_000, rejectingEvery: 1, in: small)
        let largeIDs = try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 1, in: large)
        let smallIndex = try SoundRejectionStore.index(in: small)
        let largeIndex = try SoundRejectionStore.index(in: large)
        #expect(smallIndex.capsuleIDs.count == 1_000 && largeIndex.capsuleIDs.count == 4_000)

        let t1 = bestOfThree { for id in smallIDs { _ = smallIndex.sounds(for: id) } }
        let t4 = bestOfThree { for id in largeIDs { _ = largeIndex.sounds(for: id) } }

        let ratio = seconds(t4) / max(seconds(t1), 1e-9)
        print("""
            M19 §4B  RejectionIndex.sounds(for:) over every capsule
              1,000 lookups against 1,000 keys: \(String(format: "%.2f", seconds(t1) * 1000)) ms
              4,000 lookups against 4,000 keys: \(String(format: "%.2f", seconds(t4) * 1000)) ms
              ratio: \(String(format: "%.2f", ratio))×  (hash ≈ 4, scan ≈ 16)
            """)
        #expect(ratio < 8, """
            4× the capsules cost \(String(format: "%.1f", ratio))× the lookups. \
            A hashed index does not do that; a linear scan does.
            """)
    }

    // MARK: Counts — immune to load entirely

    /// **M18 §4B's claim, as an integer.** "One scoped fetch per operation, never one
    /// per capsule" was a paragraph in a doc comment. A library of 4,000 capsules
    /// would make the difference between one fetch and 4,000 impossible to miss, and
    /// this is the assertion that would have caught it.
    @Test func aScopedIndexIsOneFetchWhateverTheLibrarySize() throws {
        let context = try LargeLibrary.makeStore()
        let ids = try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, in: context)

        SoundRejectionStore.resetFetchCount()
        let index = try SoundRejectionStore.index(forCapsules: ids, in: context)
        #expect(SoundRejectionStore.fetchCount == 1,
                "reading 4,000 capsules' corrections took \(SoundRejectionStore.fetchCount) fetches")
        #expect(!index.isEmpty, "and it actually found the rejections, so the count is not of nothing")
    }

    /// The whole-table read is one fetch too — the gallery's `@Query` path.
    @Test func theWholeTableIndexIsAlsoOneFetch() throws {
        let context = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 2_000, rejectingEvery: 5, in: context)

        SoundRejectionStore.resetFetchCount()
        _ = try SoundRejectionStore.index(in: context)
        #expect(SoundRejectionStore.fetchCount == 1)
    }

    /// **Asking a resolved index a question must not read the store at all.** This is
    /// what makes the index worth having: a card asks it a `Set` question on a body
    /// pass, and a body pass must never become 4,000 fetches.
    @Test func askingTheIndexAboutEveryCapsuleCostsNoFetches() throws {
        let context = try LargeLibrary.makeStore()
        let ids = try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, in: context)
        let index = try SoundRejectionStore.index(in: context)
        let capsules = try context.fetch(FetchDescriptor<Capsule>())

        SoundRejectionStore.resetFetchCount()
        var shown = 0
        for capsule in capsules {
            shown += SoundprintDisplay.heard(for: capsule, on: .card, rejecting: index,
                                             listening: true).count
        }
        #expect(SoundRejectionStore.fetchCount == 0,
                "rendering \(ids.count) cards performed \(SoundRejectionStore.fetchCount) store reads")
        #expect(shown > 0, "and the cards actually rendered labels, so this is not vacuous")
    }

    // MARK: The structural half — a card cannot reach the store even if it wanted to

    /// A count proves the render path is clean *today*. This proves it cannot stop
    /// being clean without someone noticing: the view types take a resolved
    /// `RejectionIndex` and have no route to the store at all.
    ///
    /// Source-read rather than behavioural, for the same reason
    /// `DemoDataIsolationTests` is: the property is "this file never does X", and no
    /// runtime observation can establish a negative about code that did not run.
    @Test func noViewOnTheGalleryPathReachesForTheStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for relative in ["Soundpost/Views/CapsuleCard.swift",
                         "Soundpost/Views/CapsuleDetailView.swift",
                         "Soundpost/Services/SoundprintDisplay.swift"] {
            let url = root.appending(path: relative)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "\(relative) is not where this guard expects it")
            #expect(!source.contains("SoundRejectionStore.index"), """
                \(relative) resolves rejections itself. The gallery builds the index \
                once per pass and hands it down; a view doing its own resolution is \
                the per-card cost M18 §4B moved off this path.
                """)
        }
    }
}
