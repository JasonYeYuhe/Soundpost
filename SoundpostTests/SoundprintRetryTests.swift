import Foundation
import SwiftData
import Testing
@testable import Soundpost

private struct Unreadable: Error {}

private struct FixedClassifier: SoundClassifying {
    let classifierIdentifier = "version1"
    var labels: [Soundprint.Label] = [Soundprint.Label(identifier: "rain", confidence: 0.9)]
    var error: Error?
    func classify(clipAt url: URL) async throws -> [Soundprint.Label] {
        if let error { throw error }
        return labels
    }
}

/// A failure to listen is retried a bounded number of times, and is never stored as
/// "nothing heard" (M20 §4D).
///
/// Async, so every test owns its store (`isolatedStore()`) and its ledger (a
/// `UserDefaults` suite of its own) — the shared container and the shared defaults are
/// both reset by other suites mid-`await`.
@MainActor
@Suite("Bounded analysis retries")
struct SoundprintRetryTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func withLedger<T>(_ body: (SoundprintRetryLedger) async throws -> T) async rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RetryLedger-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(SoundprintRetryLedger(directory: directory))
    }

    private func realClip() throws -> (store: AudioStore, data: Data, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RetryTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let audioStore = AudioStore(directory: directory)
        let name = try TestSupport.writeSineClip(into: audioStore, seconds: 2.0)
        return (audioStore, try Data(contentsOf: audioStore.url(for: name)), directory)
    }

    /// A captured capsule whose audio is `audio` (bytes that are not a clip, if so).
    private func seed(_ store: CapsuleStore, audio: Data, daysAgo: Double) throws -> Capsule {
        let capsule = store.create(createdAt: epoch.addingTimeInterval(-daysAgo * 86_400))
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "not-on-disk.m4a", audioData: audio,
                               durationSeconds: 6, waveformSamples: [0.5])
        return capsule
    }

    /// What the store holds, through a context that has never seen it.
    private func stored(_ id: UUID, in store: CapsuleStore) throws -> String? {
        try ModelContext(store.context.container)
            .fetch(FetchDescriptor<Capsule>(predicate: #Predicate { $0.id == id })).first?.soundprintRaw
    }

    // MARK: The analyzer's own failure

    @Test func aFailureReportedByTheAnalyzerIsNotAnEmptyAnswer() throws {
        #expect(throws: Unreadable.self) {
            _ = try SoundAnalysisClassifier.outcome(failure: Unreadable(), labels: [])
        }
        let rain = [Soundprint.Label(identifier: "rain", confidence: 0.9)]
        #expect(throws: Unreadable.self) {
            _ = try SoundAnalysisClassifier.outcome(failure: Unreadable(), labels: rain)
        }
        #expect(try SoundAnalysisClassifier.outcome(failure: nil, labels: []) == [])
        #expect(try SoundAnalysisClassifier.outcome(failure: nil, labels: rain) == rain)
    }

    /// The classifier is real Core ML and is not run here, so its wiring is read from
    /// source: the observer records the failure and `classify` hands it to `outcome`.
    @Test func theRealClassifierRecordsAndReportsTheObserversFailure() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/Services/SoundprintService.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let observer = try #require(code.range(of: "didFailWithError error: Error) {"))
        let end = try #require(code.range(of: "\n        }\n", range: observer.upperBound..<code.endIndex))
        let body = code[observer.upperBound..<end.lowerBound]
        #expect(body.contains("recordedFailure = error"), "the observer drops the failure")
        #expect(code.contains("Self.outcome(failure: collector.failure"), "classify ignores the failure")
    }

    // MARK: The backfill

    /// The plan's case: the two newest capsules cannot be read, one older can. A batch
    /// of two that is *all* failures is the circuit breaker (it is what a device-wide
    /// failure looks like), so the older capsule waits — but only until those two are
    /// capped and left out of the fetch. A backfill that kept fetching them would fill
    /// every batch with the two that fail and never reach the older one, on any launch.
    @Test func unreadableClipsCannotStarveOlderOnesAndStopAtTheCap() async throws {
        try await withLedger { ledger in
            let clip = try realClip()
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let store = try TestSupport.isolatedStore()
            let older = try seed(store, audio: clip.data, daysAgo: 30)
            let broken = [try seed(store, audio: Data([0, 1, 2, 3]), daysAgo: 1),
                          try seed(store, audio: Data([9, 9, 9]), daysAgo: 2)]
            try store.save()
            let backfill = SoundprintBackfill(modelContainer: store.context.container)
            func launch() async -> Int {
                await backfill.drain(batchSize: 2, pauseBetweenBatches: .zero,
                                     audioStore: clip.store, classifier: FixedClassifier(),
                                     isEnabled: true, ledger: ledger)
            }

            for run in 1...SoundprintRetryLedger.cap {
                #expect(await launch() == 0)
                for capsule in broken {
                    #expect(ledger.attempts(for: capsule.id) == run, "one try per capsule per launch")
                }
            }
            #expect(await launch() == 1, "with the broken pair capped, the older capsule is reached")
            #expect(Soundprint(stored: try stored(older.id, in: store))?.contains("rain") == true)

            _ = await launch()
            for capsule in broken {
                #expect(ledger.attempts(for: capsule.id) == SoundprintRetryLedger.cap,
                        "a capped capsule was tried again")
                #expect(try stored(capsule.id, in: store) == nil,
                        "a failure must stay nil — never the empty 'nothing heard' marker")
            }
        }
    }

    /// A mixed batch carries on, and the clip that failed is left out of the rest of the
    /// run — or one launch would re-fetch it in every batch and spend all its tries.
    @Test func aBrokenClipIsTriedOncePerLaunchEvenAmongReadableOnes() async throws {
        try await withLedger { ledger in
            let clip = try realClip()
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let store = try TestSupport.isolatedStore()
            let broken = try seed(store, audio: Data([0, 1, 2]), daysAgo: 1)
            let readable = [try seed(store, audio: clip.data, daysAgo: 2),
                            try seed(store, audio: clip.data, daysAgo: 3),
                            try seed(store, audio: clip.data, daysAgo: 4)]
            try store.save()
            let backfill = SoundprintBackfill(modelContainer: store.context.container)

            let written = await backfill.drain(batchSize: 2, pauseBetweenBatches: .zero,
                                               audioStore: clip.store, classifier: FixedClassifier(),
                                               isEnabled: true, ledger: ledger)

            #expect(written == readable.count)
            #expect(ledger.attempts(for: broken.id) == 1)
        }
    }

    /// A device-wide failure (here: a classifier that fails every clip) stops the run at
    /// the first batch, so it costs one batch of tries, not one try for every capsule.
    @Test func aDeviceWideFailureCostsOneBatchNotTheWholeLibrary() async throws {
        try await withLedger { ledger in
            let clip = try realClip()
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let store = try TestSupport.isolatedStore()
            let capsules = try (1...5).map { try seed(store, audio: clip.data, daysAgo: Double($0)) }
            try store.save()
            let backfill = SoundprintBackfill(modelContainer: store.context.container)

            _ = await backfill.drain(batchSize: 2, pauseBetweenBatches: .zero,
                                     audioStore: clip.store,
                                     classifier: FixedClassifier(error: Unreadable()),
                                     isEnabled: true, ledger: ledger)

            let tried = capsules.filter { ledger.attempts(for: $0.id) > 0 }
            #expect(tried.count == 2, "the run went on past an all-failed batch: \(tried.count) tried")
        }
    }

    /// A clip that cannot even be written out for the analyzer says nothing about the
    /// clip — the disk is full — so nothing is counted and the run ends.
    @Test func aClipThatCannotBeStagedIsNotCountedAgainstIt() async throws {
        try await withLedger { ledger in
            let clip = try realClip()
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let store = try TestSupport.isolatedStore()
            let capsules = try (1...3).map { try seed(store, audio: clip.data, daysAgo: Double($0)) }
            try store.save()
            let backfill = SoundprintBackfill(modelContainer: store.context.container)
            let nowhere = FileManager.default.temporaryDirectory
                .appending(path: "RetryTest-absent-\(UUID().uuidString)/deeper", directoryHint: .isDirectory)

            let written = await backfill.drain(batchSize: 2, pauseBetweenBatches: .zero,
                                               audioStore: clip.store, classifier: FixedClassifier(),
                                               isEnabled: true, ledger: ledger,
                                               scratchDirectory: nowhere)

            #expect(written == 0)
            for capsule in capsules { #expect(ledger.attempts(for: capsule.id) == 0) }
        }
    }

    /// The caps belong to the device that counted them. Preferences travel with a backup
    /// and with Quick Start, so a restored phone inherited the old one's caps; the ledger
    /// is a file excluded from backup instead (M20 release review).
    @Test func theLedgerStaysOnTheDeviceThatWroteIt() async throws {
        try await withLedger { ledger in
            // Read from disk through a fresh URL each time: a URL caches its resource
            // values until the run loop turns, so re-reading `ledger.fileURL` would only
            // repeat the first answer.
            func excludedOnDisk() throws -> Bool? {
                try URL(filePath: ledger.fileURL.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup
            }
            ledger.recordFailures([UUID()])
            let first = try excludedOnDisk()
            #expect(first == true, "the caps would follow a backup to a new phone")
            // Still excluded after a rewrite: an atomic write replaces the file, and the
            // replacement does not keep the old one's resource values.
            ledger.recordFailures([UUID()])
            let afterRewrite = try excludedOnDisk()
            #expect(afterRewrite == true, "a rewrite put the ledger back into backups")
            // And not in the preferences a backup carries.
            #expect(UserDefaults.standard.object(forKey: "soundprint.failedAttempts") == nil)
        }
    }

    /// Switching listening off and on is the natural retry, and it must be a real one.
    @Test func switchingListeningOffForgetsEveryCap() async throws {
        try await withLedger { ledger in
            let store = try TestSupport.isolatedStore()
            let capsule = try seed(store, audio: Data([0, 1]), daysAgo: 1)
            try store.save()
            ledger.recordFailures(Array(repeating: capsule.id, count: SoundprintRetryLedger.cap))
            #expect(ledger.capped == [capsule.id])

            try SoundprintEraser.eraseAll(in: store.context, ledger: ledger)

            #expect(ledger.capped.isEmpty)
            #expect(ledger.attempts(for: capsule.id) == 0)
        }
    }

    @Test func aClassifierFailureIsCountedAndLeftNil() async throws {
        try await withLedger { ledger in
            let clip = try realClip()
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let store = try TestSupport.isolatedStore()
            let capsule = try seed(store, audio: clip.data, daysAgo: 1)
            try store.save()

            let written = await SoundprintBackfill.backfill(
                in: store.context, limit: 10, audioStore: clip.store,
                classifier: FixedClassifier(error: Unreadable()), isEnabled: true, ledger: ledger)

            #expect(written == 0)
            #expect(capsule.soundprintRaw == nil)
            #expect(ledger.attempts(for: capsule.id) == 1)
        }
    }

    @Test func aBatchDroppedForConsentCountsNothing() async throws {
        try await withLedger { ledger in
            let store = try TestSupport.isolatedStore()
            let capsule = try seed(store, audio: Data([0, 1, 2]), daysAgo: 1)
            try store.save()
            // Granted while the batch runs, withdrawn before it can be saved.
            final class Answers: @unchecked Sendable { var asked = 0 }
            let answers = Answers()

            _ = await SoundprintBackfill.backfill(
                in: store.context, limit: 10, classifier: FixedClassifier(), isEnabled: true,
                consentStillGranted: { answers.asked += 1; return answers.asked == 1 },
                ledger: ledger)

            #expect(answers.asked == 2, "the test did not reach the final consent check")
            #expect(ledger.attempts(for: capsule.id) == 0,
                    "a withdrawn consent is not a failure to listen")
        }
    }

    @Test func aCapsuleThatIsFinallyReadForgetsItsFailures() async throws {
        try await withLedger { ledger in
            let clip = try realClip()
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let store = try TestSupport.isolatedStore()
            let capsule = try seed(store, audio: clip.data, daysAgo: 1)
            try store.save()
            ledger.recordFailures([capsule.id, capsule.id])

            let written = await SoundprintBackfill.backfill(
                in: store.context, limit: 10, audioStore: clip.store,
                classifier: FixedClassifier(), isEnabled: true, ledger: ledger)

            #expect(written == 1)
            #expect(ledger.attempts(for: capsule.id) == 0)
        }
    }
}
