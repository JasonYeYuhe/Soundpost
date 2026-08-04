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
        isEnabled: Bool = SoundAnalysisPreferences.isEnabled
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

        var written = 0
        for capsule in pending {
            if Task.isCancelled { break }
            guard let outcome = await Self.analyse(capsule, audioStore: audioStore,
                                                   classifier: classifier, isEnabled: isEnabled) else {
                continue
            }
            switch outcome {
            case .analysed(let soundprint):
                capsule.soundprintRaw = soundprint.stored
                written += 1
            case .skipped(.tooShort), .skipped(.tooQuiet):
                // A terminal answer, and it must be *recorded* — otherwise every
                // launch re-examines the same silent clip forever. An empty
                // soundprint is exactly the "we listened, nothing to say" marker.
                capsule.soundprintRaw = Soundprint(classifier: classifier.classifierIdentifier).stored
                written += 1
            case .skipped(.failed), .skipped(.notPermitted):
                // Leave `nil` so a later launch can try again — a transient failure
                // or a withdrawn consent is not a verdict about the audio.
                continue
            }
        }
        if written > 0 { try? modelContext.save() }
        return written
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
        guard let extraction = try? WaveformExtractor.extract(from: url, buckets: 32) else { return nil }
        // Forward the consent decision the caller already made. Letting this
        // re-read the global preference would let the inner call disagree with the
        // outer guard — which is exactly what happened: the backfill checked consent,
        // then the service silently re-read it and skipped everything.
        return await SoundprintService.soundprint(
            forClipAt: url,
            duration: capsule.durationSeconds,
            peak: extraction.peak,
            classifier: classifier,
            isEnabled: isEnabled
        )
    }
}
