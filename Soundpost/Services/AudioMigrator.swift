import Foundation
import SwiftData
import AVFoundation

/// One-shot, background **file → `audioData` backfill** for the M9 durability
/// migration (docs/M9-DEVPLAN.md §S2 — the single riskiest step).
///
/// Pre-M9 capsules stored their clip as an on-disk `.m4a` referenced by
/// `audioFileName`. M9 makes the external-storage `audioData` blob canonical so
/// the clip rides CloudKit as a `CKAsset`. This actor copies each source file
/// into `audioData`, **verifies** the bytes are real and decodable, **saves**,
/// then **deletes** the now-redundant source file — in that order, never the
/// reverse, so a crash mid-flush can never lose audio.
///
/// It is a `@ModelActor` with its own isolated background `ModelContext`:
/// `@Model` is **not** `Sendable`, so a `Capsule` or the main `ModelContext`
/// must never cross an actor boundary (that crashes SwiftData). The UI keeps the
/// main context; this actor only ever touches its own.
///
/// Designed to **coexist with an active CloudKit sync** (App Store users skip
/// versions, so the backfill can run alongside the very first CloudKit import):
/// it is idempotent, resumable, batched, and writes `audioData` **only** with
/// real decodable bytes — CloudKit therefore uploads the real asset once and
/// never an empty blob first then a large overwrite.
@ModelActor
actor AudioMigrator {

    /// Migrate every file-backed clip into `audioData`, then reclaim the source
    /// file. Runs the migration core on this actor's isolated background context.
    func backfillAudio(batchSize: Int = 10, audioStore: AudioStore = AudioStore()) {
        Self.backfill(in: modelContext, batchSize: batchSize, audioStore: audioStore)
    }

    /// The migration core, deliberately **`nonisolated` / synchronous** so it can
    /// be unit-tested against any `ModelContext` without crossing an actor
    /// boundary (the test suite shares one in-memory container and relies on
    /// synchronous bodies to avoid interleaving). Production calls it on the
    /// actor's background context; tests call it directly on the main context.
    ///
    /// Safe to interrupt and re-run; no-ops once every capsule is migrated.
    /// - Parameters:
    ///   - context: the SwiftData context to migrate within.
    ///   - batchSize: capsules to migrate between saves — bounds in-memory audio
    ///     to one batch and keeps CloudKit uploads incremental.
    ///   - audioStore: the on-disk clip store.
    ///   - save: the persist step (injected so tests can drive the save-failure
    ///     recovery path; production uses the real `context.save()`).
    static func backfill(
        in context: ModelContext,
        batchSize: Int = 10,
        audioStore: AudioStore,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) {
        // Fetch rows (NOT the external-storage audio blobs, which fault lazily)
        // and filter in memory — consistent with the store's enum-predicate
        // avoidance, and cheap for a personal-scale library.
        guard let all = try? context.fetch(FetchDescriptor<Capsule>()) else { return }
        let candidates = all.filter { $0.audioFileName != nil }
        guard !candidates.isEmpty else { return }

        var pendingDeletes: [String] = []
        // What this batch mutated, so we can hand-revert it if the save fails.
        // (capsule, original audioFileName, whether we also set audioData this batch)
        var pendingUndo: [(capsule: Capsule, fileName: String, setData: Bool)] = []
        var dirty = 0

        // Persist the batch's canonical `audioData` FIRST, then delete the now-
        // redundant source files. Returns false if the save failed (caller stops;
        // everything retries next launch).
        //
        // On failure we MANUALLY REVERT the batch's in-memory mutations.
        // SwiftData's `context.rollback()` does not reliably undo property updates,
        // and the mutations would otherwise stay dirty: a later successful save in
        // the same run (or context reuse) could commit `audioFileName = nil` while
        // the (dropped) source file survives — permanently doubling storage for a
        // capsule that, with `audioFileName` now nil, would never re-qualify as a
        // candidate. Reverting restores `audioFileName` (and clears any `audioData`
        // we set) so the capsule cleanly re-migrates next launch. We also drop the
        // pending deletes so a source file is never removed without its blob saved.
        func flush() -> Bool {
            guard dirty > 0 else { pendingDeletes.removeAll(); pendingUndo.removeAll(); return true }
            do {
                if context.hasChanges { try save(context) }
            } catch {
                Diagnostics.notice("M9 backfill: batch save failed, reverted; retrying next launch")
                for item in pendingUndo {
                    item.capsule.audioFileName = item.fileName
                    if item.setData { item.capsule.audioData = nil }
                }
                pendingUndo.removeAll()
                pendingDeletes.removeAll()
                dirty = 0
                return false
            }
            for fileName in pendingDeletes { try? audioStore.delete(fileName) }
            pendingUndo.removeAll()
            pendingDeletes.removeAll()
            dirty = 0
            return true
        }

        for capsule in candidates {
            guard let fileName = capsule.audioFileName else { continue }

            if capsule.audioData == nil {
                // Pre-M9 capsule: copy file → data, committing ONLY if the bytes
                // are non-empty and decodable. A missing / zero-byte / corrupt
                // source can't be recovered — log and skip, leaving `audioFileName`
                // set so a later run can retry rather than blindly orphaning it.
                let url = audioStore.url(for: fileName)
                guard let data = try? Data(contentsOf: url),
                      !data.isEmpty,
                      (try? AVAudioPlayer(data: data)) != nil else {
                    Diagnostics.notice("M9 backfill: unreadable source clip, skipped")
                    continue
                }
                capsule.audioData = data
                capsule.audioFileName = nil          // migrated — drop the stale ref
                pendingDeletes.append(fileName)
                pendingUndo.append((capsule, fileName, true))
                dirty += 1
            } else {
                // `audioData` is already canonical (a clip captured by the M9 build,
                // or one imported via CloudKit): the on-disk file is redundant
                // doubling. Drop the stale ref and reclaim the file. `audioData` is
                // untouched, so there's no empty-blob upload risk.
                capsule.audioFileName = nil
                if audioStore.fileExists(fileName) { pendingDeletes.append(fileName) }
                pendingUndo.append((capsule, fileName, false))
                dirty += 1
            }

            if dirty >= batchSize {
                if !flush() { return } // stop on save failure; clean retry next launch
            }
        }
        _ = flush()
    }
}
