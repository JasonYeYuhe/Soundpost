import Foundation
import SwiftData

/// Reading and writing per-label rejections (M18 §4A).
///
/// **The row shape is `ListeningConsent`'s. The resolution logic is not**, and all
/// three reviewers arrived at that from different angles. `ListeningConsent` answers
/// *one global question*, so its `winner()` takes the max over the whole table.
/// A rejection answers **many independent questions**, one per
/// `(capsuleID, identifier)`, so every part of the algorithm here is scoped to a key:
///
/// * the winner is a winner *per key*, not a single row for the table;
/// * future-date settlement applies per key;
/// * compaction — a newer answer supersedes strictly-older rows — applies per key,
///   which is what stops rapid toggling leaving dozens of permanent rows while also
///   never touching a different label's history;
/// * the tie-break prefers `rejected == true`. When two answers cannot be ordered,
///   take the one that says stop; here "stop" means "do not show it".
///
/// Copying `winner()` wholesale would have made one rejection anywhere in the library
/// decide the answer for every label on every capsule.
enum SoundRejectionStore {

    // MARK: The one door every SoundRejection fetch goes through

    /// Every read of this table, in one place.
    ///
    /// It exists to make a claim countable. M18 §4B argues that the display paths do
    /// **one scoped fetch per operation, never one per capsule** — and that argument
    /// has until now been a paragraph in a doc comment, which is exactly the kind of
    /// thing this project has repeatedly discovered to be false while everything
    /// stayed green. Routing every fetch through one function turns it into an
    /// integer a test can assert on (M19 §4B).
    private static func fetchRows(_ descriptor: FetchDescriptor<SoundRejection>,
                                  in context: ModelContext) throws -> [SoundRejection] {
        #if DEBUG
        fetchCounter?.increment()
        #endif
        return try context.fetch(descriptor)
    }

    #if DEBUG
    /// Test instrument: how many times this table has been read, counted **per task
    /// tree** rather than per process.
    ///
    /// The first version of this was a `nonisolated(unsafe) static var` on the
    /// grounds that it is "touched from one place at a time". That was wrong, and an
    /// external review caught it: Swift Testing runs distinct suites concurrently,
    /// and `SoundRejectionTests`, `SayingNoTests`, `HonouringRejectionsTests` and a
    /// `@ModelActor` exporter all drive this store. A process-wide counter would be
    /// incremented by whatever happened to be running beside the measurement — a
    /// genuine data race, and an assertion that fails for reasons having nothing to
    /// do with the code under test. Exactly the flakiness M19 §4B set out to avoid,
    /// reintroduced through the instrument meant to avoid it.
    ///
    /// `@TaskLocal` scopes the counter to the tree that bound it, which is the same
    /// answer `SoundAnalysisPreferences.defaultsSuiteName` already uses for the same
    /// problem. Unbound — which is every Release build and every non-measuring test —
    /// this is `nil` and costs one optional check.
    @TaskLocal static var fetchCounter: Counter?

    /// How many times the table has been **resolved** into a `RejectionIndex`, on the
    /// same task-local terms.
    ///
    /// A separate question from the fetch count, and M19 §4B named it as its own
    /// guard: "`RejectionIndex` is built once per gallery pass, not once per card."
    /// The fetch counter cannot answer it — the gallery holds its rows in a `@Query`
    /// and never fetches at all, so a body that resolved those rows once per card
    /// would show a fetch count of zero and look perfect. That is exactly the bug
    /// this counter found in `ContentView` (§4B-ii).
    @TaskLocal static var resolveCounter: Counter?

    /// `@unchecked Sendable` because it holds a mutable count, with a lock rather than
    /// an argument.
    ///
    /// The argument it used to carry — "`withValue`'s body is synchronous, so the only
    /// writer is the task that bound it" — is true of every caller today and is not a
    /// property of the type. A measured body that awaited anything, or bound the
    /// counter around a `TaskGroup`, would race, and the failure would be a wrong
    /// count rather than a crash: an instrument that lies quietly. A lock costs
    /// nothing in a DEBUG-only counter, and removes the caveat instead of documenting
    /// it.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        init() {}
    }
    #endif

    // MARK: Resolution

    /// A timestamp clamped to the present.
    ///
    /// The same reasoning as `ListeningConsentStore.effectiveDate`, and it is genuinely
    /// the same problem rather than an analogy: "last writer wins" is only as good as
    /// the clocks writing it, and a device whose clock runs fast would pin an answer
    /// for as long as its date is in the future.
    static func effectiveDate(_ date: Date, now: Date = .now) -> Date {
        min(date, now)
    }

    /// The winning row **among rows that share one key**.
    ///
    /// Callers must group first; passing the whole table would give a single answer
    /// for the entire library, which is precisely the bug this type exists not to
    /// have. `winners(among:)` is the safe entry point.
    static func winner(amongRowsForOneKey rows: [SoundRejection],
                       now: Date = .now) -> SoundRejection? {
        rows.max { a, b in
            let aAt = effectiveDate(a.changedAt, now: now)
            let bAt = effectiveDate(b.changedAt, now: now)
            if aAt != bAt { return aAt < bAt }
            // Unorderable: prefer the answer that says stop.
            if a.rejected != b.rejected { return !a.rejected && b.rejected }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// One winner per key, from any set of rows.
    static func winners(among rows: [SoundRejection],
                        now: Date = .now) -> [SoundRejection.Key: SoundRejection] {
        var grouped: [SoundRejection.Key: [SoundRejection]] = [:]
        for row in rows { grouped[row.key, default: []].append(row) }
        return grouped.compactMapValues { winner(amongRowsForOneKey: $0, now: now) }
    }

    /// The winners, as the value type every display path takes.
    ///
    /// **Build this once per render pass.** It walks every row in the table, and the
    /// gallery's `@Query` holds all of them, so a view that resolves it per card pays
    /// the whole table per card — a cost no fetch counter can see, because there is no
    /// fetch. `GalleryPass` is the shape that makes it once, and
    /// `aGalleryPassResolvesTheIndexOnce` is the assertion.
    static func index(among rows: [SoundRejection], now: Date = .now) -> RejectionIndex {
        #if DEBUG
        resolveCounter?.increment()
        #endif
        var byCapsule: [UUID: Set<String>] = [:]
        for (key, row) in winners(among: rows, now: now) where row.rejected {
            byCapsule[key.capsuleID, default: []].insert(key.identifier)
        }
        return RejectionIndex(byCapsule)
    }

    // MARK: Reading

    /// Every rejection in the store, resolved.
    ///
    /// For the gallery, which already holds the whole library in a `@Query` and would
    /// gain nothing from a narrower fetch.
    static func index(in context: ModelContext, now: Date = .now) throws -> RejectionIndex {
        index(among: try fetchRows(FetchDescriptor<SoundRejection>(), in: context), now: now)
    }

    /// The rejections for a known set of capsules — **one fetch, not one per capsule**.
    ///
    /// For the path that is not a view and has no query: `RemoteChangeReconciler`
    /// builds notification copy outside any view, and reads exactly the capsules it
    /// is about to render copy for — one scoped fetch per operation (§4B).
    ///
    /// **`CapsuleBulkExporter` deliberately does not use this one**, and an earlier
    /// version of this comment claimed it did. The export covers the whole library,
    /// so the whole table *is* its scope and it calls `index(in:)`; narrowing to a
    /// list of every capsule id would be the same fetch with a longer predicate.
    ///
    /// An empty list fetches nothing rather than everything, which is the direction a
    /// mistake here should fail in.
    static func index(forCapsules capsuleIDs: [UUID],
                      in context: ModelContext,
                      now: Date = .now) throws -> RejectionIndex {
        guard !capsuleIDs.isEmpty else { return .none }
        let wanted = Set(capsuleIDs)
        let rows = try fetchRows(
            FetchDescriptor<SoundRejection>(
                predicate: #Predicate { wanted.contains($0.capsuleID) }), in: context)
        return index(among: rows, now: now)
    }

    /// Every row for one key, oldest first. The unit compaction and settlement work on.
    static func rows(for key: SoundRejection.Key, in context: ModelContext) throws -> [SoundRejection] {
        let capsuleID = key.capsuleID
        let identifier = key.identifier
        return try fetchRows(
            FetchDescriptor<SoundRejection>(
                predicate: #Predicate { $0.capsuleID == capsuleID && $0.identifier == identifier },
                sortBy: [SortDescriptor(\.changedAt)]), in: context)
    }

    // MARK: Writing

    /// Record an answer about one label on one capsule.
    ///
    /// **Every answer is a new row; nothing is ever edited in place** — see
    /// `SoundRejection` for why editing a synced row loses whichever answer CloudKit
    /// decides came second.
    ///
    /// **The save-failure bug is not inherited.** `ListeningConsentStore.set` deletes
    /// superseded rows and inserts the new answer in one save, and on failure removes
    /// only the *new* row — leaving the pending deletes on a shared main context for
    /// the next unrelated save to commit, so correctness depends on the caller
    /// rolling back. Codex found it while reading the code this was to be modelled on.
    ///
    /// So the answer is made durable **first**, and only then is anything removed. A
    /// failed write leaves the table exactly as it was; a failed compaction leaves
    /// some superseded rows behind, which costs storage and changes no answer, and its
    /// pending deletes are undone rather than left lying on the context.
    ///
    /// - Parameter save: injected so a test can drive the failure path. Production
    ///   uses the real `context.save()` — the same seam `AudioMigrator.backfill` uses.
    static func set(
        _ rejected: Bool,
        identifier: String,
        forCapsule capsuleID: UUID,
        in context: ModelContext,
        now: Date = .now,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let answer = SoundRejection(capsuleID: capsuleID, identifier: identifier,
                                    rejected: rejected, changedAt: now)
        context.insert(answer)
        do {
            try save(context)
        } catch {
            // `rollback()` does not restore already-materialised objects (this project
            // learned that in the backfill's first consent fix), so the pending insert
            // is dropped by hand. Nothing else has been touched yet — that is the
            // whole reason the removal comes second.
            context.delete(answer)
            throw error
        }
        compact(key: SoundRejection.Key(capsuleID: capsuleID, identifier: identifier),
                keeping: answer, in: context, now: now, save: save)
    }

    /// Remove rows for one key that a newer answer has superseded.
    ///
    /// Strictly older than the answer we just stored, and only for this key. That
    /// cannot lose intent: a newer answer from another device is a *newer* row, which
    /// this never touches, and an older one has already been overruled.
    ///
    /// Best-effort by design. It runs after the answer is durable, so a failure here
    /// cannot lose one — `winner` still picks the same row out of a longer list.
    private static func compact(
        key: SoundRejection.Key,
        keeping answer: SoundRejection,
        in context: ModelContext,
        now: Date,
        save: (ModelContext) throws -> Void
    ) {
        guard let existing = try? rows(for: key, in: context) else { return }
        let superseded = existing.filter { $0.id != answer.id && $0.changedAt < now }
        guard !superseded.isEmpty else { return }
        // Everything needed to put them back, read before they are deleted.
        let restorable = superseded.map {
            ($0.id, $0.capsuleID, $0.identifier, $0.rejected, $0.changedAt)
        }
        for row in superseded { context.delete(row) }
        do {
            try save(context)
        } catch {
            // Undo the pending deletes by re-inserting equivalents, field for field.
            // Leaving them pending would hand the next unrelated save a deletion this
            // one failed to make — the half-applied state `SettingsView` has to
            // `rollback()` around today.
            for (id, capsuleID, identifier, rejected, changedAt) in restorable {
                context.insert(SoundRejection(id: id, capsuleID: capsuleID,
                                              identifier: identifier, rejected: rejected,
                                              changedAt: changedAt))
            }
            Diagnostics.notice("Could not compact superseded sound rejections; the answer itself is stored")
        }
    }

    /// Settle answers that arrived dated in the future, **per key**, so which one wins
    /// stops depending on what time it happens to be.
    ///
    /// The reasoning is `ListeningConsentStore.settleFutureDatedAnswers`'s and it is
    /// worth reading there in full: clamping only at read time is momentary, and once
    /// the local clock passes the future date, an answer that lost while clamped wins
    /// by itself — the label the person dismissed comes back on its own.
    ///
    /// Rewriting the future date to `now` does not fix it; it hands the row an
    /// ordering it has not earned. So a key whose answers disagree is replaced with
    /// one trustworthy **rejection**, which is what the tie-break would have said
    /// while the clamp held. A key whose answers agree has nothing to arbitrate and is
    /// simply brought back to the present.
    ///
    /// Scoped per key, unlike consent's: one device's bad clock must not delete
    /// another label's history.
    ///
    /// Returns how many keys were settled.
    @discardableResult
    static func settleFutureDatedAnswers(in context: ModelContext, now: Date = .now) throws -> Int {
        let all = try fetchRows(FetchDescriptor<SoundRejection>(), in: context)
        var grouped: [SoundRejection.Key: [SoundRejection]] = [:]
        for row in all { grouped[row.key, default: []].append(row) }

        var settled = 0
        var replacements: [SoundRejection] = []
        for (key, rows) in grouped where rows.contains(where: { $0.changedAt > now }) {
            settled += 1
            if let first = rows.first, rows.allSatisfy({ $0.rejected == first.rejected }) {
                // A repair, not an answer. Two devices clamping the same row both
                // write roughly their own `now`, so whichever version CloudKit keeps
                // says the same thing — losing a version of this loses nothing.
                for row in rows where row.changedAt > now { row.changedAt = now }
                continue
            }
            // Unorderable *and* disagreeing. Replace this key's rows with one
            // trustworthy rejection — deleting rather than adding, because an added
            // row could not win: it would be dated `now` while the untrustworthy
            // answer sits in the future, and would be overtaken the moment the clock
            // reached it.
            for row in rows { context.delete(row) }
            replacements.append(SoundRejection(capsuleID: key.capsuleID,
                                               identifier: key.identifier,
                                               rejected: true, changedAt: now))
        }
        guard settled > 0 else { return 0 }
        for replacement in replacements { context.insert(replacement) }
        do {
            try context.save()
        } catch {
            for replacement in replacements { context.delete(replacement) }
            throw error
        }
        if !replacements.isEmpty {
            Diagnostics.notice("A sound rejection arrived dated in the future and the answers disagree — honouring the rejection")
        }
        return settled
    }

    // MARK: Removal

    /// Drop every rejection belonging to one capsule.
    ///
    /// Called from the one site that knows a capsule is going away (§4F). Blind
    /// pruning elsewhere is not an option: CloudKit can deliver a rejection before the
    /// capsule it belongs to, so "no capsule for this id" does not mean "orphan".
    ///
    /// Does **not** save — the caller deletes the capsule in the same save, so the row
    /// and its rejections leave together or not at all.
    @discardableResult
    static func removeAll(forCapsule capsuleID: UUID, in context: ModelContext) throws -> Int {
        let rows = try fetchRows(
            FetchDescriptor<SoundRejection>(predicate: #Predicate { $0.capsuleID == capsuleID }), in: context)
        for row in rows { context.delete(row) }
        return rows.count
    }

    /// Erase every rejection, for withdrawal of listening consent (§4F).
    ///
    /// A rejection row records that the classifier proposed a particular label for a
    /// particular capsule. It *is* derived from what Soundpost heard, so keeping it
    /// after the Settings footer promises to erase "what it has already heard,
    /// everywhere" would make shipped copy untrue.
    ///
    /// **The cost, stated rather than argued away:** turning listening off and on
    /// again re-analyses the library and the corrections are gone. Rejections are rare
    /// and deliberate, so this will be felt. The alternative is amending copy that is
    /// currently true to carve out an exception; this project's habit is to keep the
    /// promise and pay the cost (M18 §8 item 0 — the one product call Jason may want
    /// to overturn).
    @discardableResult
    static func eraseAll(in context: ModelContext) throws -> Int {
        let rows = try fetchRows(FetchDescriptor<SoundRejection>(), in: context)
        guard !rows.isEmpty else { return 0 }
        for row in rows { context.delete(row) }
        try context.save()
        return rows.count
    }
}
