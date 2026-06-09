import Testing
import Foundation
@testable import Soundmark

struct AudioStoreTests {
    /// A store rooted in a unique temp directory, cleaned by the OS.
    private func makeStore() -> AudioStore {
        let dir = URL.temporaryDirectory.appending(path: "SoundmarkTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        return AudioStore(directory: dir)
    }

    @Test func ensureDirectoryCreatesIt() throws {
        let store = makeStore()
        #expect(FileManager.default.fileExists(atPath: store.directory.path) == false)
        try store.ensureDirectory()
        #expect(FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func newFileNameIsUniqueM4A() {
        let store = makeStore()
        let a = store.newFileName()
        let b = store.newFileName()
        #expect(a != b)
        #expect(a.hasSuffix(".m4a"))
    }

    @Test func urlIsInsideDirectory() {
        let store = makeStore()
        let name = store.newFileName()
        #expect(store.url(for: name).deletingLastPathComponent().path == store.directory.path)
    }

    @Test func deleteRemovesFileAndIsIdempotent() throws {
        let store = makeStore()
        try store.ensureDirectory()
        let name = store.newFileName()
        try Data("hi".utf8).write(to: store.url(for: name))
        #expect(store.fileExists(name))
        try store.delete(name)
        #expect(store.fileExists(name) == false)
        try store.delete(name) // no throw on missing file
    }
}
