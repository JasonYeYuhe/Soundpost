import Foundation
import SwiftData

/// One-shot, background **soundprint backfill** for capsules recorded before M15.
///
/// Without it the feature looks broken to exactly the people who have most to gain:
/// a long-time user's search returns nothing for their whole back catalogue, and
/// their oldest, most valuable capsules keep the generic resurface copy — while a
/// brand-new user sees it work perfectly (Codex F5).
///
/// Modelled on `AudioMigrator`: a `@ModelActor` with its own isolated background
/// context, because `@Model` is not `Sendable` and a `Capsule` must never cross an
/// actor boundary. Batched and resumable — it does a bounded amount of work per
/// launch rather than trying to chew through a 500-capsule library at once, since
/// classification is cheap per clip but not free in aggregate.
///
/// **Idempotent by construction**, which is what the analysed-but-empty soundprint
/// is for: `nil` means never analysed, `1/version1|` means analysed with nothing
/// confident to say. Without that distinction every silent capsule would be retried
/// on every launch, forever.
@ModelActor
actor SoundprintBackfill {

    /// Classify up to `limit` un-analysed capsules on this actor's own background
    /// context.
    @discardableResult
    func backfill(
        limit: Int = 20,
        audioStore: AudioStore = AudioStore(),
        classifier: some SoundClassifying = SoundAnalysisClassifier(),
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled,
        ledger: SoundprintRetryLedger = SoundprintRetryLedger()
    ) async -> Int {
        await Self.backfill(in: modelContext, limit: limit, audioStore: audioStore,
                            classifier: classifier, isEnabled: isEnabled, ledger: ledger)
    }

    /// Keep running batches until there is nothing left to analyse.
    ///
    /// One batch per launch was too literal a reading of "bounded". The bound exists
    /// for *memory* — one clip in flight at a time, the M9 rule — and for not
    /// competing with capture. Neither requires stopping after twenty.
    ///
    /// What stopping after twenty did require was patience the release notes did not
    /// ask for: they say "Search 'rain' and your rainy mornings come back", and a
    /// long-time user with three hundred capsules needed roughly fifteen separate
    /// launches before that was true, with search quietly returning partial results
    /// the whole time. Measured cost is 0.02–0.05 s for a three-second clip, so the
    /// same library is some tens of seconds of background work — once, because it
    /// converges.
    ///
    /// Batching stays: it is what keeps peak memory at one clip and lets the loop
    /// yield between batches instead of holding the actor. `maximumBatches` is a
    /// runaway guard, not a quota, and hitting it is **logged** rather than passed
    /// off as completion.
    ///
    /// **One try per capsule per run** (M20 §4D). A capsule that fails is left out of
    /// the rest of this run's batches, and one this device has failed on
    /// `SoundprintRetryLedger.cap` times is left out of every fetch. Without that, a
    /// batch made entirely of clips that cannot be read writes nothing, the loop below
    /// stops, and every older capsule behind them goes unanalysed on every launch.
    @discardableResult
    func drain(
        batchSize: Int = 20,
        maximumBatches: Int = 100,
        pauseBetweenBatches: Duration = .milliseconds(250),
        audioStore: AudioStore = AudioStore(),
        classifier: some SoundClassifying = SoundAnalysisClassifier(),
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled,
        ledger: SoundprintRetryLedger = SoundprintRetryLedger(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) async -> Int {
        var total = 0
        var failedThisRun: Set<UUID> = []
        for batch in 0..<maximumBatches {
            if Task.isCancelled { return total }
            let result = await Self.batch(in: modelContext, limit: batchSize,
                                          excluding: ledger.capped.union(failedThisRun),
                                          audioStore: audioStore, classifier: classifier,
                                          isEnabled: isEnabled, ledger: ledger,
                                          scratchDirectory: scratchDirectory)
            total += result.written
            failedThisRun.formUnion(result.failed)
            // Stop when there is nothing left, consent was withdrawn mid-run (a batch
            // that neither wrote nor failed), or the device itself is in trouble.
            if result.written == 0 && result.failed.isEmpty { return total }
            if result.deviceTrouble { return total }
            // **A batch where every clip failed is a circuit breaker** (M20 §4D review).
            // That is what a device-wide failure looks like — a classifier that cannot
            // start, media services resetting — and running on would spend a try on
            // every unanalysed capsule in the library, three runs capping all of them
            // for good. Stopping limits it to one batch. The cost, which §4D accepted:
            // if the newest clips really are all corrupt, older ones wait until those
            // are capped. A *mixed* batch carries on, with its failures left out of
            // the rest of the run.
            if result.written == 0 && result.failed.count == result.fetched { return total }
            if batch == maximumBatches - 1 {
                Diagnostics.notice("M15 backfill: stopped at the batch ceiling with work remaining")
                return total
            }
            // Let capture and the UI have the device between batches.
            try? await Task.sleep(for: pauseBetweenBatches)
        }
        return total
    }

    /// The backfill core, deliberately **`nonisolated`** so it can be unit-tested
    /// against any `ModelContext` without crossing an actor boundary — the same
    /// arrangement `AudioMigrator` uses, and for the same reason: the suite shares one
    /// in-memory container, and asserting across two contexts turns a behaviour test
    /// into a SwiftData-propagation test.
    ///
    /// Returns how many capsules were written, so a caller (or a test) can tell
    /// progress from a no-op.
    @discardableResult
    nonisolated static func backfill(
        in modelContext: ModelContext,
        limit: Int = 20,
        audioStore: AudioStore = AudioStore(),
        classifier: some SoundClassifying = SoundAnalysisClassifier(),
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled,
        consentStillGranted: @Sendable () -> Bool = { SoundAnalysisPreferences.isEnabled },
        ledger: SoundprintRetryLedger = SoundprintRetryLedger()
    ) async -> Int {
        await batch(in: modelContext, limit: limit, excluding: ledger.capped,
                    audioStore: audioStore, classifier: classifier, isEnabled: isEnabled,
                    consentStillGranted: consentStillGranted, ledger: ledger).written
    }

    /// What one batch did: capsules written, and capsules this device could not listen
    /// to (recorded in the ledger).
    struct BatchResult: Sendable {
        var written = 0
        var failed: [UUID] = []
        /// How many capsules the batch fetched.
        var fetched = 0
        /// The device could not stage a clip to read it (a full disk) — not the clip's
        /// fault, so nothing was counted against it and the run should end.
        var deviceTrouble = false
    }

    /// One batch of the backfill, leaving out `excluded` capsules.
    nonisolated static func batch(
        in modelContext: ModelContext,
        limit: Int,
        excluding excluded: Set<UUID>,
        audioStore: AudioStore,
        classifier: some SoundClassifying,
        isEnabled: Bool,
        consentStillGranted: @Sendable () -> Bool = { SoundAnalysisPreferences.isEnabled },
        ledger: SoundprintRetryLedger,
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) async -> BatchResult {
        // Consent is checked here too, not only at capture: a user who turned
        // listening off must not have their back catalogue quietly analysed instead.
        guard isEnabled else { return BatchResult() }

        // The plain predicate when there is nothing to leave out — the `contains` form
        // is the one `SoundRejectionStore` already uses.
        let unanalysed: Predicate<Capsule> = excluded.isEmpty
            ? #Predicate<Capsule> { $0.soundprintRaw == nil }
            : #Predicate<Capsule> { $0.soundprintRaw == nil && !excluded.contains($0.id) }
        var descriptor = FetchDescriptor<Capsule>(
            predicate: unanalysed,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let pending = try? modelContext.fetch(descriptor), !pending.isEmpty else { return BatchResult() }

        // Results are held here and applied only once consent has been confirmed to
        // still hold. Consent can be withdrawn *while* this batch runs — it is up to
        // `limit` clips long and every one is an `await`, nothing cancels the task
        // when the switch flips, and the erase writes on a different context. A
        // batch that started before the flip would otherwise land fresh labels on
        // capsules the user had just cleared, seconds after asking us to stop.
        //
        // Staged rather than written-then-rolled-back on purpose: `rollback()` does
        // not restore already-materialised objects, so a mutated `Capsule` stays
        // mutated in memory and any later `save()` on this long-lived context would
        // make it durable after all.
        var staged: [(capsule: Capsule, stored: String?)] = []
        // Capsules whose clip this device could not listen to (M20 §4D): no readable
        // audio, an extraction that threw, or an analysis that failed. Counted in the
        // ledger once the batch is known to stand; never written as "nothing heard".
        var failed: [UUID] = []
        var deviceTrouble = false
        listening: for capsule in pending {
            if Task.isCancelled { break }
            guard consentStillGranted() else {
                Diagnostics.info("M15 backfill: consent withdrawn mid-batch, discarded")
                return BatchResult()
            }
            let outcome: SoundprintOutcome
            switch await Self.analyse(capsule, audioStore: audioStore, classifier: classifier,
                                      isEnabled: isEnabled, scratchDirectory: scratchDirectory) {
            case .heard(let heard):
                outcome = heard
            case .unreadable:
                failed.append(capsule.id)
                continue
            case .couldNotStage:
                Diagnostics.info("M20 backfill: could not stage a clip; ending this run")
                deviceTrouble = true
                break listening
            }
            switch outcome {
            case .analysed(let soundprint):
                staged.append((capsule, soundprint.stored))
            case .skipped(.tooShort), .skipped(.tooQuiet):
                // A terminal answer, and it must be *recorded* — otherwise every
                // launch re-examines the same silent clip forever. An empty
                // soundprint is exactly the "we listened, nothing to say" marker.
                staged.append((capsule, Soundprint(classifier: classifier.classifierIdentifier).stored))
            case .skipped(.failed):
                // Leave `nil` so a later launch can try again — a failure is not a
                // verdict about the audio — but count it, so a clip that always fails
                // stops being re-read on every launch (`SoundprintRetryLedger`).
                failed.append(capsule.id)
            case .skipped(.notPermitted):
                // A withdrawn consent is not a failure to listen; nothing is counted.
                continue
            }
        }
        // The last `await` above is where a withdrawal lands most often, and this
        // save is the only thing that would make the batch durable. A batch dropped
        // for consent counts nothing against any clip.
        guard consentStillGranted() else {
            Diagnostics.info("M15 backfill: consent withdrawn before save, discarded")
            return BatchResult()
        }
        ledger.recordFailures(failed)
        let result = BatchResult(written: staged.count, failed: failed, fetched: pending.count,
                                 deviceTrouble: deviceTrouble)
        guard !staged.isEmpty else { return result }
        for entry in staged { entry.capsule.soundprintRaw = entry.stored }
        try? modelContext.save()
        ledger.clear(staged.map(\.capsule.id))
        return result
    }

    /// What reading one capsule's clip came to.
    private enum Listening {
        case heard(SoundprintOutcome)
        /// This clip cannot be read on this device: no audio here, or audio that does
        /// not decode. About the clip — counted.
        case unreadable
        /// The clip could not be staged to a file for the analyzer (the scratch write
        /// failed — a full disk). About the device — not counted, and the run ends.
        case couldNotStage
    }

    /// Read one capsule's clip and classify it.
    private nonisolated static func analyse(
        _ capsule: Capsule,
        audioStore: AudioStore,
        classifier: some SoundClassifying,
        isEnabled: Bool,
        scratchDirectory: URL
    ) async -> Listening {
        // Reuse the on-disk clip when there is one; otherwise spill the blob to a
        // temp file, because the analyzer is file-driven. One capsule at a time, so
        // peak memory stays one clip regardless of library size (the M9 rule).
        let scratch = scratchDirectory
            .appending(path: "soundprint-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        let url: URL
        var isScratch = false
        if let name = capsule.audioFileName, audioStore.fileExists(name) {
            url = audioStore.url(for: name)
        } else if let data = capsule.audioData {
            // A clip held in the store that cannot be written out says nothing about
            // the clip — the disk is full, or tmp is unwritable — and every other clip
            // would fail the same way.
            guard (try? data.write(to: scratch, options: .atomic)) != nil else { return .couldNotStage }
            url = scratch
            isScratch = true
        } else {
            return .unreadable   // no audio on this device at all
        }
        defer { if isScratch { try? FileManager.default.removeItem(at: scratch) } }

        // The amplitude gate needs the absolute peak, which only the extractor knows.
        // `buckets` shapes the waveform, not the gate — `absolutePeak` is a
        // per-frame maximum and does not move with it, so this no longer has to
        // agree with whatever the capture screen asked for.
        guard let extraction = try? WaveformExtractor.extract(from: url, buckets: 32) else { return .unreadable }
        // Forward the consent decision the caller already made. Letting this
        // re-read the global preference would let the inner call disagree with the
        // outer guard — which is exactly what happened: the backfill checked consent,
        // then the service silently re-read it and skipped everything.
        return .heard(await SoundprintService.soundprint(
            forClipAt: url,
            duration: capsule.durationSeconds,
            peak: extraction.absolutePeak,
            classifier: classifier,
            isEnabled: isEnabled
        ))
    }
}
