import Foundation
import SwiftData
import AVFoundation
@testable import Soundpost

/// One in-memory SwiftData container shared by ALL test suites: creating more
/// than one `ModelContainer` for the same model in a single process crashes the
/// test runner. Each test gets a clean store via `freshStore()`. Test bodies are
/// `@MainActor` and synchronous, so they run to completion on the main actor
/// without interleaving on the shared store.
@MainActor
enum TestSupport {
    static let container: ModelContainer = {
        try! ModelContainer(
            for: Capsule.self, ListeningConsent.self,
            // `cloudKitDatabase: .none`: the default is `.automatic`, which — because
            // the app carries the CloudKit entitlement — makes even this in-memory
            // store spin up a mirroring delegate that then fails with
            // "CKAccountStatusNoAccount" on a simulator. Harmless but noisy in CI
            // logs, and a pointless piece of async work inside every test run.
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }()

    /// A `CapsuleStore` over a fresh context with all prior data cleared.
    ///
    /// The `delete(model:)` is container-wide, so this is only safe under the
    /// assumption in this type's doc: synchronous `@MainActor` tests that run to
    /// completion. Anything `async` must use `isolatedStore()` instead.
    static func freshStore() throws -> CapsuleStore {
        let context = ModelContext(container)
        try context.delete(model: Capsule.self)
        // ListeningConsent too, or a row written by one test resolves for the next
        // one and silently decides its consent for it.
        try context.delete(model: ListeningConsent.self)
        try context.save()
        return CapsuleStore(context: context)
    }

    /// Run `body` with `SoundAnalysisPreferences` pointed at storage nobody else
    /// shares, seeded to `enabled`.
    ///
    /// Three suites drive that one key and Swift Testing runs suites in parallel, so
    /// save-and-restore is not enough: another suite can read between this one's
    /// write and its restore. A private `UserDefaults` suite removes the contention
    /// rather than ordering it.
    /// `nonisolated` because it touches only `UserDefaults` and a task-local — the
    /// suites that need it are not all `@MainActor`.
    nonisolated static func withIsolatedListeningPreference<T>(
        _ enabled: Bool,
        _ body: () throws -> T
    ) rethrows -> T {
        let name = "soundpost.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return try SoundAnalysisPreferences.$defaultsSuiteName.withValue(name) {
            SoundAnalysisPreferences.isEnabled = enabled
            return try body()
        }
    }

    /// A `CapsuleStore` over its **own** container, isolated from every other suite.
    ///
    /// M15's backfill tests broke the shared-container assumption above: they are
    /// `async`, so they suspend, and another suite's `freshStore()` — a
    /// container-wide `delete(model:)` — can remove the capsule under test during
    /// an `await`. The backfill then finds nothing to label and the assertion reads
    /// as a *product* failure ("it did not label the capsule") when the capsule had
    /// simply been deleted out from under it. An async test must own its store.
    static func isolatedStore() throws -> CapsuleStore {
        // `ModelContext` retains its container, so the store keeps it alive.
        let container = try ModelContainer(
            for: Capsule.self, ListeningConsent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return CapsuleStore(context: ModelContext(container))
    }

    /// Write a real ~`seconds`-long mono AAC/m4a clip into `store` and return its
    /// file name. Produces genuinely decodable audio offline (no microphone), so
    /// the backfill's `AVAudioPlayer(data:)` verify step runs for real. Same
    /// generator as `WaveformExtractorTests`.
    @discardableResult
    static func writeSineClip(into store: AudioStore, seconds: Double = 1.0) throws -> String {
        try store.ensureDirectory()
        let fileName = store.newFileName()
        let url = store.url(for: fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(44_100.0 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { channel[i] = sin(Float(i) * 0.05) * 0.5 }
        try file.write(from: buffer)
        return fileName
    }
}
