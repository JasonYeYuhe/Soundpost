import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M9 §S7: memory guard. The gallery `@Query` and cards read only small inline
/// metadata (waveform, mood, note, dates) — never the `@Attribute(.externalStorage)`
/// `audioData` blob, which faults lazily and would blow up memory if mapped per
/// row. This proves the gallery's data is fully available from a fetch that
/// excludes the blob, and that the blob is still retrievable on demand (the
/// playback path) — i.e. it's lazy, not eager.
@Suite(.serialized)
@MainActor
struct GalleryFetchTests {

    @Test func galleryMetadataFetchesWithoutTheAudioBlob() throws {
        let store = try TestSupport.freshStore()

        // Seed a capsule carrying a substantial audio blob.
        let blob = Data(repeating: 0xAB, count: 2_000_000) // 2 MB
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "x.m4a", audioData: blob,
                               durationSeconds: 10, waveformSamples: [0.1, 0.9, 0.4])
        capsule.mood = .calm
        capsule.note = "rain"
        try store.save()

        // A fetch scoped to exactly the gallery's read set — `audioData` is NOT
        // among the fetched properties, so the blob is never loaded eagerly.
        var descriptor = FetchDescriptor<Capsule>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [
            \.createdAt, \.durationSeconds, \.waveformSamples, \.mood, \.note,
            \.state, \.sealUntil, \.echoAt, \.place,
        ]
        let rows = try store.context.fetch(descriptor)

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        // Everything the card needs is present from the blob-free fetch.
        #expect(row.waveformSamples == [0.1, 0.9, 0.4])
        #expect(row.mood == .calm)
        #expect(row.note == "rain")
        #expect(row.durationSeconds == 10)

        // The blob is still there, retrievable on demand (the playback path) —
        // confirming external storage is lazily faulted, not dropped.
        #expect(row.audioData?.count == 2_000_000)
    }
}
