import Foundation
import SwiftData

/// One entry per capsule in the bulk export manifest — the user's own data, in a
/// portable, self-describing form (M12 §S7/§4E).
struct ExportManifestEntry: Codable, Equatable {
    let id: String
    let createdAt: Date
    let durationSeconds: Double
    let state: String
    let mood: String?
    let note: String?
    let place: String?
    let sealUntil: Date?
    let echoAt: Date?
    /// The `.m4a` filename in the bundle, or nil if the capsule had no audio.
    let audioFile: String?
}

struct ExportManifest: Codable, Equatable {
    let app: String
    let formatVersion: Int
    let capsuleCount: Int
    let capsules: [ExportManifestEntry]
}

/// **Export-your-data**: a streaming bundle of every capsule as a per-clip `.m4a`
/// plus a `manifest.json` of its metadata, zipped for the system share sheet
/// (M12 §S7/§4E). Nothing new leaves the device — it's the user's own data.
///
/// **P1 (§4E): a dedicated streaming actor, NOT a loop around `CapsuleExporter`**
/// (which faults the whole `audioData` blob and is `@MainActor`). Audio is written
/// **one capsule at a time** via a *fresh* `ModelContext` per clip, so each blob
/// is released before the next is loaded — peak memory is one clip, not the whole
/// library. The manifest is built from a metadata-only snapshot pass that never
/// faults audio (the M9 gallery-memory rule). Total size is preflighted from clip
/// durations so the UI can warn first.
@ModelActor
actor CapsuleBulkExporter {
    /// Lightweight metadata for the manifest + audio refetch — no `audioData`.
    private struct Snapshot {
        let id: UUID
        let createdAt: Date
        let durationSeconds: Double
        let state: CapsuleState
        let mood: Mood?
        let note: String?
        let placeName: String?
        let sealUntil: Date?
        let echoAt: Date?
        let audioFileName: String?
    }

    /// Estimate the export's audio size from clip durations alone (the gallery's
    /// ~8 KB/s estimate — never reads file sizes or faults blobs), so the UI can
    /// warn before a large export. Nonisolated + context-taking so the view can
    /// call it on the main context synchronously.
    nonisolated static func estimatedBytes(in context: ModelContext) -> Int64 {
        let rows = (try? context.fetch(FetchDescriptor<Capsule>())) ?? []
        return rows.reduce(Int64(0)) { $0 + Int64($1.durationSeconds * 8_000) }
    }

    /// Build the export bundle and zip it; returns the `.zip` URL for the share
    /// sheet. Runs on the actor's isolated background context.
    func export(audioStore: AudioStore = AudioStore()) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "Soundpost-Export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = base.appending(path: "Soundpost", directoryHint: .isDirectory)
        try Self.writeBundle(in: modelContext, container: modelContainer, to: folder, audioStore: audioStore)
        let zipURL = base.appending(path: "Soundpost.zip", directoryHint: .notDirectory)
        try Self.zip(folder: folder, to: zipURL)
        return zipURL
    }

    /// The streaming bundle core, `nonisolated`/synchronous so it can be unit-tested
    /// against any context + container without crossing an actor boundary.
    static func writeBundle(
        in context: ModelContext,
        container: ModelContainer,
        to folder: URL,
        audioStore: AudioStore = AudioStore(),
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Pass 1 — metadata-only snapshot (no audio faulted).
        let rows = try context.fetch(
            FetchDescriptor<Capsule>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        let snapshots = rows.map { capsule in
            Snapshot(
                id: capsule.id,
                createdAt: capsule.createdAt,
                durationSeconds: capsule.durationSeconds,
                state: capsule.state,
                mood: capsule.mood,
                note: capsule.note,
                placeName: capsule.place?.name,
                sealUntil: capsule.sealUntil,
                echoAt: capsule.echoAt,
                audioFileName: capsule.audioFileName
            )
        }

        // Pass 2 — write each clip via a FRESH context so its blob is released
        // before the next is loaded (the §4E streaming guarantee).
        var entries: [ExportManifestEntry] = []
        var usedNames = Set<String>()
        for snap in snapshots {
            let audioName = Self.audioFileName(for: snap, taken: &usedNames)
            let wrote = autoreleasepool { () -> Bool in
                let scratch = ModelContext(container)
                let id = snap.id
                var descriptor = FetchDescriptor<Capsule>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                guard let capsule = try? scratch.fetch(descriptor).first else { return false }
                let dest = folder.appending(path: audioName, directoryHint: .notDirectory)
                if let data = capsule.audioData {
                    return (try? data.write(to: dest, options: .atomic)) != nil
                }
                if let file = snap.audioFileName, audioStore.fileExists(file) {
                    return (try? fileManager.copyItem(at: audioStore.url(for: file), to: dest)) != nil
                }
                return false
            }
            entries.append(ExportManifestEntry(
                id: snap.id.uuidString,
                createdAt: snap.createdAt,
                durationSeconds: snap.durationSeconds,
                state: snap.state.rawValue,
                mood: snap.mood?.rawValue,
                note: snap.note,
                place: snap.placeName,
                sealUntil: snap.sealUntil,
                echoAt: snap.echoAt,
                audioFile: wrote ? audioName : nil
            ))
        }

        let manifest = ExportManifest(
            app: "Soundpost",
            formatVersion: 1,
            capsuleCount: entries.count,
            capsules: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: folder.appending(path: "manifest.json", directoryHint: .notDirectory), options: .atomic)
    }

    /// A readable, collision-free clip filename: `yyyy-MM-dd-<uuid8>.m4a`.
    private static func audioFileName(for snap: Snapshot, taken: inout Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: snap.createdAt)
        let short = snap.id.uuidString.prefix(8)
        var name = "\(stamp)-\(short).m4a"
        var n = 2
        while taken.contains(name) { name = "\(stamp)-\(short)-\(n).m4a"; n += 1 }
        taken.insert(name)
        return name
    }

    /// Zip a directory using `NSFileCoordinator`'s `.forUploading` intent — the
    /// first-party way to produce a `.zip` of a folder with zero dependencies.
    static func zip(folder: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var thrown: Error?
        coordinator.coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { tempZip in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: tempZip, to: destination)
            } catch {
                thrown = error
            }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }
}
