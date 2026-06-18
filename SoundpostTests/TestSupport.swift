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
            for: Capsule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    /// A `CapsuleStore` over a fresh context with all prior data cleared.
    static func freshStore() throws -> CapsuleStore {
        let context = ModelContext(container)
        try context.delete(model: Capsule.self)
        try context.save()
        return CapsuleStore(context: context)
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
