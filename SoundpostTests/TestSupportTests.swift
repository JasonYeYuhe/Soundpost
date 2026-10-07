import Foundation
import SwiftData
import Testing
@testable import Soundpost

/// The shared fixture clears every entity the app stores (M20 §4B).
///
/// `freshStore()` deletes a list of models, and the list had fallen one behind:
/// `SoundRejection` rows survived from one test into the next.
@MainActor
@Suite("The shared test store starts empty")
struct TestSupportTests {
    /// The list is held to the schema, not to itself: seeding and counting three named
    /// entities could never fail for a fourth nobody added.
    @Test func freshStoreClearsEveryEntityTheAppShips() {
        let shipped = Set(SoundpostModelContainer.productionSchema.entities.map(\.name))
        let cleared = Set(TestSupport.clearedModels.map { String(describing: $0) })
        #expect(cleared == shipped, "a new entity: add it to TestSupport.clearedModels")
    }

    @Test func freshStoreLeavesNoRowOfAnyEntity() throws {
        let seeding = ModelContext(TestSupport.container)
        seeding.insert(Capsule())
        seeding.insert(ListeningConsent())
        seeding.insert(SoundRejection(capsuleID: UUID(), identifier: "rain"))
        try seeding.save()

        let store = try TestSupport.freshStore()

        #expect(try store.context.fetchCount(FetchDescriptor<Capsule>()) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<ListeningConsent>()) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<SoundRejection>()) == 0)
    }
}
