import Testing
import Foundation
import UIKit
@testable import Soundpost

/// Export produces a faithful card image + the capsule's own audio, and nothing
/// more (M11 §4G/§7). The exporter is pure; gating lives in the view.
@MainActor
struct CapsuleExporterTests {
    private func captured(audioData: Data?, duration: Double = 7) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.audioData = audioData
        capsule.durationSeconds = duration
        capsule.waveformSamples = [0.2, 0.9, 0.4, 0.6]
        capsule.note = "morning rain"
        capsule.mood = .calm
        return capsule
    }

    @Test func audioFileMirrorsCapsuleDataExactly() throws {
        // The exported audio is the capsule's own bytes — nothing added/altered.
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02])
        let capsule = try captured(audioData: bytes)

        let url = try #require(try CapsuleExporter.audioFileURL(for: capsule))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "m4a")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func audioFileIsNilWhenCapsuleHasNoAudio() throws {
        let capsule = try captured(audioData: nil)
        // No audioData and no on-disk file → nothing to export, handled gracefully.
        #expect(try CapsuleExporter.audioFileURL(for: capsule) == nil)
    }

    @Test func audioFallsBackToLegacyFile() throws {
        // Pre-backfill capsule: audio only on disk, no audioData blob.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ExportTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let audioStore = AudioStore(directory: dir)
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: 1.0)
        let fileBytes = try Data(contentsOf: audioStore.url(for: fileName))

        let capsule = try captured(audioData: nil)
        capsule.audioFileName = fileName

        let url = try #require(try CapsuleExporter.audioFileURL(for: capsule, audioStore: audioStore))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == fileBytes)

        try? FileManager.default.removeItem(at: dir)
    }

    @Test func cardImageRendersAtRequestedScale() throws {
        let capsule = try captured(audioData: Data([1, 2, 3]))
        let image = try #require(CapsuleExporter.cardImage(for: capsule, scale: 3))
        // ShareCardView is 360pt wide → 1080px at @3x; a real, non-empty raster.
        #expect(image.scale == 3)
        #expect(image.size.width == 360)
        #expect(image.size.height > 0)
    }

    @Test func payloadBundlesImageAndAudio() throws {
        let capsule = try captured(audioData: Data([4, 5, 6]))
        let payload = try #require(CapsuleExporter.payload(for: capsule))
        // Exactly two artifacts: the card image and the audio URL — no more.
        #expect(payload.items.count == 2)
        #expect(payload.items.contains { $0 is UIImage })
        #expect(payload.items.contains { ($0 as? URL)?.pathExtension == "m4a" })
        if let url = payload.items.compactMap({ $0 as? URL }).first {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
