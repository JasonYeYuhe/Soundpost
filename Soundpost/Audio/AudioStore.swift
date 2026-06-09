import Foundation

/// Owns the on-disk location of capsule audio clips.
///
/// Clips live in Application Support (app-managed, not user-browsable). The
/// `Capsule` model stores only the *filename*; this maps it to a URL so the
/// audio directory can move (e.g. to an iCloud container) later without a data
/// migration. See docs/PROJECT.md §1e.6.
struct AudioStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? URL.applicationSupportDirectory.appending(path: "SoundpostAudio", directoryHint: .isDirectory)
    }

    /// Create the audio directory if needed and return it.
    @discardableResult
    func ensureDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A fresh unique filename (not a path) for a new recording.
    func newFileName() -> String { "\(UUID().uuidString).m4a" }

    func url(for fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    func fileExists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    /// Delete a clip if present. Missing files are a no-op (idempotent cleanup).
    func delete(_ fileName: String) throws {
        let fileURL = url(for: fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
