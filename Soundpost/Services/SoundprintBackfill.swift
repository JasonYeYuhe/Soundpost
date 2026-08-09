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
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) async -> Int {
        await Self.backfill(in: modelContext, limit: limit, audioStore: audioStore,
                            classifier: classifier, isEnabled: isEnabled)
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
    @discardableResult
    func drain(
        batchSize: Int = 20,
        maximumBatches: Int = 100,
        pauseBetweenBatches: Duration = .milliseconds(250),
        audioStore: AudioStore = AudioStore(),
        classifier: some SoundClassifying = SoundAnalysisClassifier(),
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
    ) async -> Int {
        var total = 0
        for batch in 0..<maximumBatches {
            if Task.isCancelled { return total }
            let written = await backfill(limit: batchSize, audioStore: audioStore,
                                         classifier: classifier, isEnabled: isEnabled)
            total += written
            // A batch that wrote nothing means either "nothing left" or "consent was
            // withdrawn mid-run" — both are reasons to stop, and neither benefits
            // from another pass.
            if written == 0 { return total }
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
        consentStillGranted: @Sendable () -> Bool = { SoundAnalysisPreferences.isEnabled }
    ) async -> Int {
        // Consent is checked here too, not only at capture: a user who turned
        // listening off must not have their back catalogue quietly analysed instead.
        guard isEnabled else { return 0 }

        var descriptor = FetchDescriptor<Capsule>(
            predicate: #Predicate { $0.soundprintRaw == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let pending = try? modelContext.fetch(descriptor), !pending.isEmpty else { return 0 }

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
        for capsule in pending {
            if Task.isCancelled { break }
            guard consentStillGranted() else {
                Diagnostics.info("M15 backfill: consent withdrawn mid-batch, discarded")
                return 0
            }
            guard let outcome = await Self.analyse(capsule, audioStore: audioStore,
                                                   classifier: classifier, isEnabled: isEnabled) else {
                continue
            }
            switch outcome {
            case .analysed(let soundprint):
                staged.append((capsule, soundprint.stored))
            case .skipped(.tooShort), .skipped(.tooQuiet):
                // A terminal answer, and it must be *recorded* — otherwise every
                // launch re-examines the same silent clip forever. An empty
                // soundprint is exactly the "we listened, nothing to say" marker.
                staged.append((capsule, Soundprint(classifier: classifier.classifierIdentifier).stored))
            case .skipped(.failed), .skipped(.notPermitted):
                // Leave `nil` so a later launch can try again — a transient failure
                // or a withdrawn consent is not a verdict about the audio.
                continue
            }
        }
        // The last `await` above is where a withdrawal lands most often, and this
        // save is the only thing that would make the batch durable.
        guard consentStillGranted() else {
            Diagnostics.info("M15 backfill: consent withdrawn before save, discarded")
            return 0
        }
        guard !staged.isEmpty else { return 0 }
        for entry in staged { entry.capsule.soundprintRaw = entry.stored }
        try? modelContext.save()
        return staged.count
    }

    /// Read one capsule's clip and classify it. Returns `nil` when there is no audio
    /// to read at all — that capsule is simply not backfillable.
    private nonisolated static func analyse(
        _ capsule: Capsule,
        audioStore: AudioStore,
        classifier: some SoundClassifying,
        isEnabled: Bool
    ) async -> SoundprintOutcome? {
        // Reuse the on-disk clip when there is one; otherwise spill the blob to a
        // temp file, because the analyzer is file-driven. One capsule at a time, so
        // peak memory stays one clip regardless of library size (the M9 rule).
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "soundprint-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        var url: URL?
        var isScratch = false
        if let name = capsule.audioFileName, audioStore.fileExists(name) {
            url = audioStore.url(for: name)
        } else if let data = capsule.audioData, (try? data.write(to: scratch, options: .atomic)) != nil {
            url = scratch
            isScratch = true
        }
        guard let url else { return nil }
        defer { if isScratch { try? FileManager.default.removeItem(at: scratch) } }

        // The amplitude gate needs the absolute peak, which only the extractor knows.
        // `buckets` shapes the waveform, not the gate — `absolutePeak` is a
        // per-frame maximum and does not move with it, so this no longer has to
        // agree with whatever the capture screen asked for.
        guard let extraction = try? WaveformExtractor.extract(from: url, buckets: 32) else { return nil }
        // Forward the consent decision the caller already made. Letting this
        // re-read the global preference would let the inner call disagree with the
        // outer guard — which is exactly what happened: the backfill checked consent,
        // then the service silently re-read it and skipped everything.
        return await SoundprintService.soundprint(
            forClipAt: url,
            duration: capsule.durationSeconds,
            peak: extraction.absolutePeak,
            classifier: classifier,
            isEnabled: isEnabled
        )
    }
}
