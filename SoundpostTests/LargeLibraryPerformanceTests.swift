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
    /// Returns the **total for `repeating` iterations**, not the per-call time. Every
    /// caller that prints a per-call figure divides — the printed line used to show
    /// the loop total under a per-call label, which made
    /// `RejectionIndex.sounds(for:)` look 200× more expensive than it is.
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
              1,000 capsules: \(String(format: "%.2f", seconds(t1) * 1000 / 3)) ms
              4,000 capsules: \(String(format: "%.2f", seconds(t4) * 1000 / 3)) ms
              ratio: \(String(format: "%.2f", ratio))×  (linear ≈ 4, quadratic ≈ 16)
            """)
        // 8, not 10. Clean is 3.9–4.0× and the quadratic mutation is 15.7×, so the
        // bound sits nearly four standard deviations from the signal on both sides;
        // 10 was closer to the failure it was meant to catch than to the truth.
        #expect(ratio < 8, "4× the capsules cost \(String(format: "%.1f", ratio))× the time — that is not a linear walk")
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
              1,000 keys / 3,000 rows:  \(String(format: "%.2f", seconds(t1) * 1000 / 5)) ms
              4,000 keys / 12,000 rows: \(String(format: "%.2f", seconds(t4) * 1000 / 5)) ms
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
              1,000 lookups against 1,000 keys: \(String(format: "%.2f", seconds(t1) * 1000 / 200)) ms
              4,000 lookups against 4,000 keys: \(String(format: "%.2f", seconds(t4) * 1000 / 200)) ms
              ratio: \(String(format: "%.2f", ratio))×  (hash ≈ 4, scan ≈ 16)
            """)
        #expect(ratio < 8, """
            4× the capsules cost \(String(format: "%.1f", ratio))× the lookups. \
            A hashed index does not do that; a linear scan does.
            """)
    }

    /// The two library walks that were **not** the rejection index, measured because
    /// a third review pass named them and guessing which of three costs matters is how
    /// the first one got missed (§4B-iii).
    ///
    /// `sealSignature` is the one worth having measured. It feeds `.onChange`, so
    /// SwiftUI evaluates it on **every body pass** — every keystroke, every sheet, every
    /// `scenePhase` transition — and it used to build one interpolated string per
    /// capsule and join them. The hash costs a fraction of that and is fixed-width, so
    /// the comparison SwiftUI does afterwards stops being proportional to the library
    /// too. Both figures are recorded; the ratio is the assertion, as everywhere else
    /// in this suite.
    @Test func theOtherPerPassLibraryWalksAreLinearAndCheap() throws {
        let small = try LargeLibrary.makeStore()
        let large = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 1_000, rejectingEvery: 7, in: small)
        try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, in: large)
        let smallRows = try small.fetch(FetchDescriptor<Capsule>())
        let largeRows = try large.fetch(FetchDescriptor<Capsule>())

        let s1 = bestOfThree(repeating: 20) { _ = UpcomingResurfaces.sealSignature(smallRows) }
        let s4 = bestOfThree(repeating: 20) { _ = UpcomingResurfaces.sealSignature(largeRows) }
        let n1 = bestOfThree(repeating: 20) { _ = UpcomingResurfaces.nearest(smallRows, now: LargeLibrary.epoch) }
        let n4 = bestOfThree(repeating: 20) { _ = UpcomingResurfaces.nearest(largeRows, now: LargeLibrary.epoch) }

        let sealRatio = seconds(s4) / max(seconds(s1), 1e-9)
        let nearRatio = seconds(n4) / max(seconds(n1), 1e-9)
        print("""
            M19 §4B  the other per-pass walks
              sealSignature      1,000: \(String(format: "%.3f", seconds(s1) * 1000 / 20)) ms  \
            4,000: \(String(format: "%.3f", seconds(s4) * 1000 / 20)) ms  \
            ratio: \(String(format: "%.2f", sealRatio))×
              UpcomingResurfaces 1,000: \(String(format: "%.3f", seconds(n1) * 1000 / 20)) ms  \
            4,000: \(String(format: "%.3f", seconds(n4) * 1000 / 20)) ms  \
            ratio: \(String(format: "%.2f", nearRatio))×
            """)
        #expect(sealRatio < 8, "sealSignature is \(String(format: "%.1f", sealRatio))× — not a linear walk")
        #expect(nearRatio < 8, "UpcomingResurfaces.nearest is \(String(format: "%.1f", nearRatio))× — not a linear walk")
        // The premise `nearest` needs and did not have: candidates to sort. Timed with
        // `now:` defaulted, every seeded seal is long expired and this was a walk that
        // produced nothing and sorted an empty array.
        #expect(UpcomingResurfaces.nearest(largeRows, now: LargeLibrary.epoch).count == 3)

        // **What the signature is for**, not merely that it is a function of its input.
        // The first version of these premises compared libraries of different sizes and
        // a library against itself-minus-one, all of which `return capsules.count`
        // satisfies — and a signature that is only the count never changes when a seal
        // date does, so `.onChange` never fires and the notification re-sync silently
        // stops. That mutation survived; these are the assertions that kill it.
        let before = UpcomingResurfaces.sealSignature(largeRows)
        #expect(UpcomingResurfaces.sealSignature(largeRows) == before, "not stable within a run")

        let sealed = try #require(largeRows.first { $0.state == .sealed })
        let wasSealedUntil = sealed.sealUntil
        sealed.sealUntil = wasSealedUntil?.addingTimeInterval(86_400)
        #expect(UpcomingResurfaces.sealSignature(largeRows) != before,
                "moving a seal date left the signature unchanged — .onChange would not re-sync")
        sealed.sealUntil = wasSealedUntil
        #expect(UpcomingResurfaces.sealSignature(largeRows) == before, "and it is reversible")

        // The other half of why it is a *signature*: an edit that changes nothing about
        // when a notification should fire must not churn the scheduler.
        let noted = try #require(largeRows.first { $0.note != nil })
        let wasNote = noted.note
        noted.note = "an edit that has nothing to do with scheduling"
        #expect(UpcomingResurfaces.sealSignature(largeRows) == before,
                "editing a note changed the seal signature; every keystroke would re-sync")
        noted.note = wasNote
    }

    /// A filtered pass does not pay for the strip it is not showing, and an empty
    /// library pays for nothing at all.
    @Test func aPassOnlyBuildsWhatItWillShow() throws {
        let context = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 200, rejectingEvery: 3, in: context)
        let capsules = try context.fetch(FetchDescriptor<Capsule>())
        let rejections = try context.fetch(FetchDescriptor<SoundRejection>())

        let unfiltered = GalleryPass.make(capsules: capsules, rejections: rejections,
                                          criteria: GalleryFilter.Criteria(),
                                          now: LargeLibrary.epoch, listening: true)
        let filtered = GalleryPass.make(capsules: capsules, rejections: rejections,
                                        criteria: GalleryFilter.Criteria(searchText: "rain"),
                                        now: LargeLibrary.epoch, listening: true)
        // The shape the fixture claims, asserted here because a mutation that stopped
        // seeding seals altogether was survived by every test in this file: echoes
        // alone kept the strip populated, and nothing else looked at the lineage.
        let sealedCount = capsules.filter { $0.state == .sealed }.count
        #expect(sealedCount > 0, "the fixture seeded no sealed capsules")
        #expect(capsules.contains { !$0.isContentVisible(now: LargeLibrary.epoch) },
                "no capsule is sealed-not-due, so the hidden-content branch never runs")
        #expect(!GalleryFilter.apply(capsules, GalleryFilter.Criteria(sealedOnly: true),
                                     rejecting: unfiltered.rejecting,
                                     now: LargeLibrary.epoch, listening: true).isEmpty,
                "the sealedOnly filter matches nothing in this fixture")
        #expect(!unfiltered.upcoming.isEmpty, "the fixture seeds sealed capsules, so the strip has items")
        #expect(filtered.upcoming.isEmpty, "a filtered gallery hides the strip and must not compute it")

        // An empty library resolves nothing, even holding rejection rows.
        let counter = SoundRejectionStore.Counter()
        var empty: GalleryPass?
        SoundRejectionStore.$resolveCounter.withValue(counter) {
            empty = GalleryPass.make(capsules: [], rejections: rejections,
                                     criteria: GalleryFilter.Criteria(),
                                     now: LargeLibrary.epoch, listening: true)
        }
        #expect(counter.count == 0, "an empty library resolved the index \(counter.count) time(s)")
        #expect(try #require(empty).isEmpty)
        #expect(!rejections.isEmpty, "and there were rows it could have walked, so this is not a count of nothing")
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

        let counter = SoundRejectionStore.Counter()
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

        let counter = SoundRejectionStore.Counter()
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

        // **Both surfaces.** `.card` alone was not enough: it returns at
        // `if surface == .card, hasNote(capsule)`, and the fixture gives notes to two
        // of every three capsules, so two thirds of this loop used to be a note check
        // and nothing else. `.detail` has no such short-circuit — it is the surface
        // that always reaches `Soundprint(stored:)` — and it is what
        // `CapsuleDetailView` and `ResurfaceView` actually render.
        let counter = SoundRejectionStore.Counter()
        var shown = 0
        var reached = 0
        SoundRejectionStore.$fetchCounter.withValue(counter) {
            for capsule in capsules {
                for surface in [SoundprintDisplay.Surface.card, .detail] {
                    let heard = SoundprintDisplay.heard(for: capsule, on: surface,
                                                       rejecting: index, listening: true)
                    shown += heard.count
                    if !heard.isEmpty { reached += 1 }
                }
            }
        }
        #expect(counter.count == 0,
                "the display policy performed \(counter.count) store reads over \(capsules.count) capsules")
        #expect(shown > 0, "and it actually produced labels, so this is not a count of nothing")
        // The premise the `.card`-only version could not state: the loop got past the
        // note short-circuit often enough for the count to mean something.
        #expect(reached > capsules.count,
                "only \(reached) of \(capsules.count * 2) calls produced anything — too many returned early")
    }

    /// **The count M19 §4B promised and M18 §4B assumed**: `RejectionIndex` is built
    /// once per gallery pass, not once per card.
    ///
    /// This is the assertion that was missing for two milestones, and the gallery was
    /// wrong for both of them. No fetch counter could have found it: the gallery holds
    /// its rejections in a `@Query` and performs **zero** fetches, so
    /// `theWholeTableIndexIsOneFetch` and `theDisplayPolicyCostsNoFetchesPerCapsule`
    /// were both green over an implementation that walked the whole rejection table
    /// once per rendered card. Resolution and reading are different costs and need
    /// different counters.
    ///
    /// It counts a `GalleryPass`, not a `ContentView`: a body is not something this
    /// suite can evaluate without a UI-test target, which the milestone does not have.
    /// What makes that enough is that the pass now holds its three results in stored
    /// properties, so a view cannot recompute them by reading them —
    /// `contentViewMakesExactlyOneGalleryPass` covers the remaining half, that the
    /// view builds one pass rather than one per card.
    @Test func aGalleryPassResolvesTheIndexOnceNoMatterHowManyCapsules() throws {
        let context = try LargeLibrary.makeStore()
        try LargeLibrary.seed(capsules: 4_000, rejectingEvery: 7, answersPerKey: 3, in: context)
        let capsules = try context.fetch(FetchDescriptor<Capsule>())
        let rejections = try context.fetch(FetchDescriptor<SoundRejection>())
        // Every 7th capsule is answered, three times each: 572 keys, 1,716 rows. Stated
        // exactly rather than as `> 0`, so a fixture change that quietly stopped
        // seeding rejections would fail here instead of turning the count below into
        // a measurement of nothing.
        #expect(capsules.count == 4_000)
        #expect(rejections.count == 572 * 3, "seeded \(rejections.count) rejection rows")

        // Both sizes, because the name says "no matter how many" and one size cannot
        // establish that. One is the interesting one: a `make` that resolved per
        // capsule would return 1 for a single-capsule library and look correct.
        for capsuleCount in [1, 4_000] {
            let counter = SoundRejectionStore.Counter()
            SoundRejectionStore.$resolveCounter.withValue(counter) {
                _ = GalleryPass.make(capsules: Array(capsules.prefix(capsuleCount)),
                                     rejections: rejections,
                                     criteria: GalleryFilter.Criteria(searchText: "rain"),
                                     now: LargeLibrary.epoch, listening: true)
            }
            #expect(counter.count == 1,
                    "\(capsuleCount) capsules resolved the index \(counter.count) times")
        }

        let counter = SoundRejectionStore.Counter()
        var pass: GalleryPass?
        SoundRejectionStore.$resolveCounter.withValue(counter) {
            pass = GalleryPass.make(capsules: capsules, rejections: rejections,
                                    criteria: GalleryFilter.Criteria(searchText: "rain"),
                                    now: LargeLibrary.epoch, listening: true)
        }
        let made = try #require(pass)

        #expect(counter.count == 1, """
            one pass over 4,000 capsules resolved the rejection index \(counter.count) \
            times. It walks every row in the table; once per card is the whole table \
            per card, and no fetch counter can see it because there is no fetch.
            """)
        // The premises, so a count of one cannot be a count of nothing having happened.
        #expect(!made.isEmpty, "the pass filtered everything away, so it proves nothing")
        #expect(made.sections.reduce(0) { $0 + $1.capsules.count } == made.count)
        #expect(!made.rejecting.isEmpty, "and the index it resolved actually holds rejections")
    }

    /// The other half: the view builds **one** pass, and never resolves for itself.
    ///
    /// The first version of this guard counted `SoundRejectionStore.index(` and
    /// required exactly one, on the reasoning that ContentView legitimately resolves
    /// for its two sheets. **It would not have caught the bug it was written for.**
    /// The shipped defect had exactly one such call — inside a computed property — and
    /// resolved the whole table per card anyway, because the count of *call sites* and
    /// the count of *evaluations* are different numbers and only the second one
    /// matters. A guard that passes on the code that motivated it is not a guard.
    ///
    /// So the property is gone and the assertion is zero, which is a thing source text
    /// can actually establish: `body` builds one `GalleryPass` and hands it down, and
    /// this file no longer names the resolver at all. Still weak in the usual ways —
    /// a second construction spelled differently slips past — but the strength here is
    /// structural rather than textual: `GalleryPass` stores its three results, so no
    /// amount of reading them recomputes anything.
    @Test func contentViewResolvesRejectionsOnlyThroughOnePass() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/ContentView.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8))
        // Whitespace-normalised before counting. `GalleryPass.make (` is correct code
        // and a textual guard that reddens on a stray space is a guard people learn to
        // edit around.
        let source = raw.replacingOccurrences(of: " (", with: "(")

        let passes = source.components(separatedBy: "GalleryPass.make(").count - 1
        #expect(passes == 1, "ContentView builds \(passes) gallery passes; it should build one")

        // The **whole type**, not `.index`. `SoundRejectionStore.winners(among:)` is a
        // second route to the same walk, and the first version of this guard named only
        // the first one — the same narrowness that let the original bug through.
        let resolves = source.components(separatedBy: "SoundRejectionStore").count - 1
        #expect(resolves == 0, """
            ContentView names SoundRejectionStore \(resolves) time(s). Resolving walks \
            every row in the table, and anything reachable by name from a body is \
            eventually read inside a ForEach — which is the bug that shipped. The \
            gallery, the detail screen and the reveal all read `pass.rejecting`.
            """)

        // What this cannot see, stated rather than implied: a resolver reached through
        // a helper or an extension defined elsewhere — `rejections.resolved` — names
        // none of these strings. No source guard can close that, and the reason this
        // one is still worth having is that it is not carrying the weight alone:
        // `GalleryPass` stores its results, so the failure mode it protects against
        // needs someone to write a new resolver rather than to read an existing one.
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
                         "Soundpost/Views/ResurfaceView.swift",
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
            // `[SoundRejection]` catches the idiomatic SwiftUI route the first three
            // miss entirely: `@Query private var rejections: [SoundRejection]` names
            // none of them and would give a per-capsule view the whole table.
            for read in ["SoundRejectionStore.index", "SoundRejectionStore.rows",
                         "SoundRejectionStore.winners", "FetchDescriptor<SoundRejection",
                         "[SoundRejection]", "Array<SoundRejection"] {
                #expect(!source.contains(read), """
                    \(relative) contains `\(read)`. The gallery resolves the index once \
                    per pass and hands it down; a per-capsule view resolving its own is \
                    the cost M18 §4B moved off this path.
                    """)
            }
        }
    }
}
