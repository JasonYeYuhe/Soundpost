import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// Bulk export-your-data (§S7/§4E): a streaming per-capsule `.m4a` bundle + a
/// metadata manifest, built one clip at a time (never faulting all audio at once).
@Suite(.serialized)
@MainActor
struct CapsuleBulkExporterTests {

    private func seed(_ store: CapsuleStore, note: String, mood: Mood, blobByte: UInt8, bytes: Int) throws -> Capsule {
        let c = store.create()
        try store.markRecording(c)
        try store.markCaptured(c, audioFileName: "f.m4a", audioData: Data(repeating: blobByte, count: bytes),
                               durationSeconds: 6, waveformSamples: [0.3])
        c.note = note; c.mood = mood
        try store.save()
        return c
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "bulk-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func bundleHasPerCapsuleAudioAndAManifest() throws {
        let store = try TestSupport.freshStore()
        let a = try seed(store, note: "rain", mood: .calm, blobByte: 0xA1, bytes: 4000)
        let b = try seed(store, note: "birds", mood: .joyful, blobByte: 0xB2, bytes: 5000)
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        try CapsuleBulkExporter.writeBundle(in: store.context, container: TestSupport.container, to: folder)

        // Manifest decodes and describes both capsules.
        let manifestURL = folder.appending(path: "manifest.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.capsuleCount == 2)
        #expect(Set(manifest.capsules.map(\.note)) == ["rain", "birds"])
        #expect(Set(manifest.capsules.compactMap(\.mood)) == [Mood.calm.rawValue, Mood.joyful.rawValue])

        // Each clip is written and its bytes match that capsule's blob exactly —
        // proving the per-capsule streaming read produced correct, distinct audio.
        for (capsule, byte, count) in [(a, UInt8(0xA1), 4000), (b, UInt8(0xB2), 5000)] {
            let entry = try #require(manifest.capsules.first { $0.id == capsule.id.uuidString })
            let file = try #require(entry.audioFile)
            let data = try Data(contentsOf: folder.appending(path: file))
            #expect(data == Data(repeating: byte, count: count))
        }
    }

    @Test func capsuleWithoutAudioHasNilEntryAndNoFile() throws {
        let store = try TestSupport.freshStore()
        let c = store.create()
        try store.markRecording(c)
        // Captured with no audioData and a file that doesn't exist on disk.
        try store.markCaptured(c, audioFileName: "missing.m4a", audioData: nil, durationSeconds: 3, waveformSamples: [])
        try store.save()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        try CapsuleBulkExporter.writeBundle(in: store.context, container: TestSupport.container, to: folder)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
        #expect(manifest.capsuleCount == 1)
        #expect(manifest.capsules.first?.audioFile == nil)
        // No stray .m4a written.
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!contents.contains { $0.hasSuffix(".m4a") })
    }

    @Test func estimatedBytesSumsFromDurations() throws {
        let store = try TestSupport.freshStore()
        _ = try seed(store, note: "a", mood: .calm, blobByte: 1, bytes: 100)     // duration 6s
        _ = try seed(store, note: "b", mood: .tender, blobByte: 2, bytes: 100)   // duration 6s
        // 2 × 6s × 8000 B/s = 96_000.
        #expect(CapsuleBulkExporter.estimatedBytes(in: store.context) == 96_000)
    }

    @Test func exportProducesANonEmptyZip() async throws {
        let store = try TestSupport.freshStore()
        _ = try seed(store, note: "zip me", mood: .nostalgic, blobByte: 0xC3, bytes: 3000)
        let exporter = CapsuleBulkExporter(modelContainer: TestSupport.container)
        let url = try await exporter.export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.pathExtension == "zip")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 0)
    }
}
