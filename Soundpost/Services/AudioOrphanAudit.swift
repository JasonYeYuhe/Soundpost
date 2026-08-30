import Foundation
import SwiftData

/// Counts audio clips on disk that no capsule points at — and **deletes nothing**
/// (M17 §4E).
///
/// The leak was real and, worse, invisible. Until §S0, `CaptureViewModel.discard()`
/// never stopped the recorder, so a capture sheet dismissed mid-take left an `.m4a`
/// behind with no `Capsule` row naming it. Nothing in the app could see such a file:
/// `AudioMigrator` fetches capsule rows and filters `audioFileName != nil`, and the
/// gallery's storage footer estimates from `durationSeconds` rather than reading the
/// directory. That is the M15 §11P shape exactly — *a check that iterates the
/// artefact cannot fail for what is missing from the artefact* — so this iterates
/// the **directory** and asks the rows about it, never the other way round.
///
/// **Why it counts and does not sweep, which is the whole design.** The clip is
/// created when recording *starts*; the `Capsule` row is inserted only on *save*
/// (`CaptureViewModel.save`). So "every file no capsule references" is a set that
/// contains the take the user is recording right now, and a sweep on that rule
/// deletes it out from under a running `AVAudioRecorder`. Two independent reviewers
/// named that as the most dangerous line in M17's draft, and a plausible test — drop
/// a stray file beside a saved capsule, run the sweep, assert the stray is gone —
/// passes green without ever simulating a take in flight.
///
/// **M18 proposed the sweep with exactly those two guards and cut it** (M18 §4E).
/// Three reviewers found three different holes, and none is answered by the guards:
/// the launch audit runs from `SoundpostApp` holding no `AudioRecorder`, so
/// `currentFileName` is not reachable where the sweep would run; jetsam defeats the
/// age window (start a take, get killed, come back a day later — the file is
/// unreferenced, old, and the recorder that knew about it died with the process);
/// and a fetch on one context is not the whole truth. The cost of the leak is disk
/// space; the cost of a wrong sweep is somebody's recording.
///
/// So the price of entry is now named rather than assumed: an **app-scoped recording
/// lease that outlives the process**, so "is this file live?" is answerable from a
/// launch task holding no recorder at all. Until that exists, this counts.
enum AudioOrphanAudit {

    /// What one pass found. No filenames: a count is all anyone can act on, and
    /// `Diagnostics` could not carry a name anyway.
    struct Count: Equatable {
        /// Clips in the audio directory.
        let files: Int
        /// Of those, how many no capsule references.
        let orphans: Int
    }

    /// Which of `files` no capsule refers to.
    ///
    /// Pure, so the rule is testable without a directory or a store — and so that
    /// the direction of the question (files asked about rows) is visible in the
    /// signature rather than buried in a fetch.
    static func orphans(files: [String], referenced: Set<String>) -> [String] {
        files.filter { !referenced.contains($0) }
    }

    /// Count unreferenced clips. **Read-only**: it opens no file, reads no bytes and
    /// removes nothing.
    static func count(
        in context: ModelContext,
        audioStore: AudioStore = AudioStore(),
        fileManager: FileManager = .default
    ) -> Count {
        let files = ((try? fileManager.contentsOfDirectory(atPath: audioStore.directory.path)) ?? [])
            .filter { $0.hasSuffix(".m4a") }
        guard !files.isEmpty else { return Count(files: 0, orphans: 0) }
        // The filename column only — never `audioData`, which would fault every
        // clip's external-storage blob into memory (the M9 gallery-memory rule).
        let referenced = Set(
            ((try? context.fetch(FetchDescriptor<Capsule>())) ?? []).compactMap(\.audioFileName)
        )
        return Count(files: files.count, orphans: orphans(files: files, referenced: referenced).count)
    }

    /// Count, and log if there is anything to report.
    ///
    /// `Diagnostics` takes a `StaticString` so no capsule-derived text can reach
    /// Sentry; `notice(_:code:)` is the one door for a numeric detail, and a count of
    /// stranded files is exactly the shape it was opened for. Silent when the number
    /// is zero — a healthy install should say nothing.
    static func report(
        in context: ModelContext,
        audioStore: AudioStore = AudioStore(),
        fileManager: FileManager = .default
    ) {
        let result = count(in: context, audioStore: audioStore, fileManager: fileManager)
        guard result.orphans > 0 else { return }
        Diagnostics.notice("Audio clips on disk that no capsule references", code: result.orphans)
    }
}
