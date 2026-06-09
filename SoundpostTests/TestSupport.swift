import Foundation
import SwiftData
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
}
