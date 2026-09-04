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
    private func bestOfThree(repeating: Int = 1, _ body: () -> Void) -> Duration {
        var best = Duration.seconds(3600)
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let taken = clock.measure { for _ in 0..<repeating { body() } }
            if taken < best { best = taken }
        }
        return best
    }

    /// `repeating` exists because "the ratio cancels load" stops being true at
    /// sub-millisecond scale. A macOS scheduling slice is 5–10 ms and the thread can
    /// migrate between a performance and an efficiency core between two samples; a
    /// 0.12 ms measurement can absorb either and move by 10×, which is a flake
    /// wearing a regression's clothes. Repeating the body until the measured block is
    /// tens of milliseconds puts the noise back below the signal. Caught in review —
    /// the first version measured 0.12 ms against 0.52 ms and called it evidence.

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    // MARK: Growth — the shape, not the speed

    /// Quadrupling the library must not multiply the work by sixteen.
    ///
    /// **This one is a smoke test, and its bound is loose on purpose.** A linear walk
    /// gives ~4×; a quadratic walk over the library itself gives ~16×.
    ///
    /// What it does *not* catch is worth stating, because the doc comment here once
    /// claimed the opposite: replacing `RejectionIndex`'s hash lookup with a linear
    /// scan moves this ratio only to ~6.6× and sails through, because the string
    /// matching in the filter dilutes the quadratic term. That case belongs to
    /// `askingTheIndexAboutEveryCapsuleGrowsLinearly`, which measures the lookup with
    /// nothing else in the frame.
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

        let t1 = bestOfThree(repeating: 3) {
            _ = GalleryFilter.apply(smallRows, criteria, rejecting: smallIndex, listening: true)
        }
        let t4 = bestOfThree(repeating: 3) {
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

    /// The same question for the resolution M18 §4A built — the part §4B moved off
    /// the render path on the argument that it would otherwise be quadratic.
    ///
    /// **Three answers per key, not one**, and that is the difference between
    /// measuring the algorithm and measuring a dictionary. With a single row per key,
    /// `winner(amongRowsForOneKey:)` is `Array.max(by:)` over one element, which
    /// returns *without ever calling the comparator* — so the date clamping, the
    /// ordering and the tie-break, everything this test's name promises, never ran.
    /// Caught in review. Superseded answers are also the shape a real library carries
    /// between compactions, so this is the honest fixture as well as the measurable one.
    ///
    /// **No `ModelContext` either.** `index(among:)` takes rows and returns a value;
    /// pushing thousands through SwiftData would spend seconds measuring SQLite in a
    /// test that is not about SQLite.
    @Test func resolvingRejectionsGrowsLinearlyInTheNumberOfRows() {
        func rows(keys: Int, answersPerKey: Int) -> [SoundRejection] {
            let epoch = Date(timeIntervalSince1970: 1_780_000_000)
            return (0..<keys).flatMap { _ -> [SoundRejection] in
                let capsule = UUID()
                return (0..<answersPerKey).map { answer in
                    SoundRejection(capsuleID: capsule, identifier: "rain",
                                   rejected: answer.isMultiple(of: 2),
                                   changedAt: epoch.addingTimeInterval(Double(answer)))
                }
            }
        }
        let small = rows(keys: 1_000, answersPerKey: 3)
        let large = rows(keys: 4_000, answersPerKey: 3)
        #expect(small.count == 3_000 && large.count == 12_000)

        // `repeating: 5`, not 20. Five already puts the block at ~35 ms, comfortably
        // above scheduling noise — and the factor also decides how a *regression*
        // presents. A quadratic grouping over 12,000 rows repeated twenty times does
        // not fail in seconds, it hangs for minutes, which on CI reads as a stuck
        // machine rather than a red test. A guard should fail fast enough to be
        // believed.
        let t1 = bestOfThree(repeating: 5) { _ = SoundRejectionStore.index(among: small) }
        let t4 = bestOfThree(repeating: 5) { _ = SoundRejectionStore.index(among: large) }

        let ratio = seconds(t4) / max(seconds(t1), 1e-9)
        print("""
            M19 §4B  SoundRejectionStore.index(among:) — 3 answers per key
              1,000 keys / 3,000 rows:  \(String(format: "%.2f", seconds(t1) * 1000)) ms
              4,000 keys / 12,000 rows: \(String(format: "%.2f", seconds(t4) * 1000)) ms
              ratio: \(String(format: "%.2f", ratio))×
            """)
        #expect(ratio < 8)
        // The premise: resolution ran and picked one winner per key.
        #expect(SoundRejectionStore.index(among: small).capsuleIDs.count == 1_000)
    }

    /// **The lookup, isolated — and this is the one with teeth.**
    ///
    /// The end-to-end filter test above is a smoke test with a deliberately loose
    /// bound, and a control experiment proved it is too loose to stand alone:
    /// replacing `RejectionIndex`'s hash lookup with a linear scan moved that ratio
    /// only from 3.9× to 6.6× and passed, because the string matching in the filter
    /// dilutes the quadratic term. Under this test the same mutation gives 16.4× and
    /// fails.
    ///
    /// So this asks the index about every capsule and nothing else. With a hash
    /// lookup the work is O(n) and the ratio tracks the input; with a scan it is
    /// O(n·k) and the ratio squares. Nothing else is in the frame to hide it.
    @Test func askingTheIndexAboutEveryCapsuleGrowsLinearly() throws {
        let small = try LargeLibrary.makeStore()
        let large = try LargeLibrary.makeStore()
        let smallIDs = try LargeLibrary.seed(capsules: 1_000, rejectingEvery: 1, in: small)
        let largeIDs = try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 1, in: large)
        let smallIndex = try SoundRejectionStore.index(in: small)
        let largeIndex = try SoundRejectionStore.index(in: large)
        #expect(smallIndex.capsuleIDs.count == 1_000 && largeIndex.capsuleIDs.count == 4_000)

        let t1 = bestOfThree(repeating: 200) { for id in smallIDs { _ = smallIndex.sounds(for: id) } }
        let t4 = bestOfThree(repeating: 200) { for id in largeIDs { _ = largeIndex.sounds(for: id) } }

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
    @Test func aScopedIndexIsOneFetchAndIsActuallyScoped() throws {
        let context = try LargeLibrary.makeStore()
        let ids = try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, in: context)
        // A SUBSET, not the whole library. Passing all 4,000 ids proves only that one
        // fetch happened — an implementation that ignored the predicate entirely and
        // read the table would satisfy it, which is the bug most worth catching here.
        let wanted = Array(ids.prefix(200))

        let counter = SoundRejectionStore.FetchCounter()
        let index = try SoundRejectionStore.$fetchCounter.withValue(counter) {
            try SoundRejectionStore.index(forCapsules: wanted, in: context)
        }

        #expect(counter.count == 1,
                "reading 200 capsules' corrections took \(counter.count) fetches")
        #expect(!index.isEmpty, "and it found rejections, so the count is not a count of nothing")
        #expect(index.capsuleIDs.isSubset(of: Set(wanted)),
                "the index carries capsules that were never asked about — the predicate is not scoping")
        // And the library really is bigger than the slice, so the subset assertion means something.
        let whole = try SoundRejectionStore.index(in: context)
        #expect(whole.capsuleIDs.count > index.capsuleIDs.count)
    }

    /// The whole-table read is one fetch — the path `CapsuleBulkExporter` takes.
    ///
    /// **Not the gallery's**, which an earlier version of this comment claimed. The
    /// gallery reads rejections through SwiftUI's `@Query` and calls
    /// `index(among:)`; a `@Query` never routes through this store and the counter
    /// cannot see it. What this guards is the export walking the library and reading
    /// corrections once rather than once per clip.
    @Test func theWholeTableIndexIsOneFetch() throws {
        let context = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 2_000, rejectingEvery: 5, in: context)

        let counter = SoundRejectionStore.FetchCounter()
        let index = try SoundRejectionStore.$fetchCounter.withValue(counter) {
            try SoundRejectionStore.index(in: context)
        }
        #expect(counter.count == 1)
        #expect(!index.isEmpty)
    }

    /// **Asking a resolved index a question must not read the store at all.**
    ///
    /// Scope, stated precisely because the first version of this comment overstated
    /// it: this exercises `SoundprintDisplay.heard`, the policy every card body calls.
    /// **No view is instantiated and no `body` is evaluated** — a `@Query` or a
    /// `modelContext` read added inside `CapsuleCard` itself would not be caught here.
    /// `noPerCapsuleViewReachesForTheStore` is the guard for that half.
    ///
    /// What it does catch is the policy layer growing a store read, which is the
    /// shape M18 §4B moved off this path: at 4,000 capsules that is the difference
    /// between nothing and 4,000 fetches per pass.
    @Test func theDisplayPolicyCostsNoFetchesPerCapsule() throws {
        let context = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, in: context)
        let index = try SoundRejectionStore.index(in: context)
        let capsules = try context.fetch(FetchDescriptor<Capsule>())

        let counter = SoundRejectionStore.FetchCounter()
        var shown = 0
        SoundRejectionStore.$fetchCounter.withValue(counter) {
            for capsule in capsules {
                shown += SoundprintDisplay.heard(for: capsule, on: .card, rejecting: index,
                                                 listening: true).count
            }
        }
        #expect(counter.count == 0,
                "the display policy performed \(counter.count) store reads over \(capsules.count) capsules")
        #expect(shown > 0, "and it actually produced labels, so this is not a count of nothing")
    }

    // MARK: The structural half — a card cannot reach the store even if it wanted to

    /// A count proves the policy layer is clean *today*. This proves the **per-capsule
    /// views** cannot stop being clean without someone noticing: they take a resolved
    /// `RejectionIndex` and have no route to the store.
    ///
    /// **`ContentView` is deliberately not in this list**, and an earlier name for
    /// this test ("no view on the gallery path") implied it should be. It is the one
    /// place that *should* resolve the index — once, for the whole pass, which is the
    /// design. Adding it here would forbid the correct implementation.
    ///
    /// Source-read rather than behavioural, for the same reason
    /// `DemoDataIsolationTests` is: the property is "this file never does X", and no
    /// runtime observation can establish a negative about code that did not run. The
    /// limits are real — a line break inside the call, or a different route to the
    /// same rows, would slip past — so it forbids the whole type name rather than one
    /// method, and `theDisplayPolicyCostsNoFetchesPerCapsule` covers the behaviour.
    @Test func noPerCapsuleViewReachesForTheStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for relative in ["Soundpost/Views/CapsuleCard.swift",
                         "Soundpost/Views/CapsuleDetailView.swift",
                         "Soundpost/Services/SoundprintDisplay.swift"] {
            let url = root.appending(path: relative)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "\(relative) is not where this guard expects it")
            // READS, not the whole type. `CapsuleDetailView` calls
            // `SoundRejectionStore.set` when someone taps "No, it wasn't", and must:
            // that is the write the milestone exists for. What must never appear on a
            // per-capsule path is a *resolution*, which is the per-card cost M18 §4B
            // moved to the gallery. Forbidding the type name outright reddened this
            // test against correct code — a bound that is wrong in the safe-looking
            // direction is still wrong.
            for read in ["SoundRejectionStore.index", "SoundRejectionStore.rows",
                         "FetchDescriptor<SoundRejection>"] {
                #expect(!source.contains(read), """
                    \(relative) contains `\(read)`. The gallery resolves the index once \
                    per pass and hands it down; a per-capsule view resolving its own is \
                    the cost M18 §4B moved off this path.
                    """)
            }
        }
    }
}
