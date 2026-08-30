import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// Does the schema the app actually ships still load on a **CloudKit-backed**
/// configuration?
///
/// Every other test container passes `cloudKitDatabase: .none`, deliberately —
/// `.automatic` spins up a mirroring delegate that fails with
/// `CKAccountStatusNoAccount` on a signed-out simulator, which is noise. But that
/// left the CloudKit rung itself untested, and the way it fails is the problem:
/// `makeProductionContainer()` catches *any* throw from rung 1 and falls through to
/// a local store. No crash, no error, no user-visible signal — just an app that has
/// silently stopped syncing. `CloudSyncMonitor` would report the local rung
/// honestly, but nothing would say *why*, and nobody would be looking.
///
/// A CloudKit-illegal schema is the most likely way to trip that: a `@Attribute(.unique)`,
/// a non-optional property with no default, a required relationship. Those are
/// rejected when the store loads, which is exactly what this exercises.
///
/// **What this does not prove.** Schema *legality* is a local check. It says nothing
/// about whether the matching record type exists in the CloudKit **Production**
/// environment — that is a server-side deployment, it cannot be reached from a test,
/// and it is `scripts/cloudkit-schema.sh` plus the §11B-i checklist that covers it.
/// Passing here and failing there looks identical from inside the app.
@Suite(.serialized)
struct CloudKitSchemaTests {

    /// The real schema, not a copy. A rebuilt entity list would drift the moment
    /// someone adds a model, and this check would keep passing over a broken app.
    @Test func theShippingSchemaLoadsOnACloudKitBackedStore() throws {
        let schema = SoundpostModelContainer.productionSchema
        let config = ModelConfiguration(schema: schema,
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .automatic)
        // Throwing here is the failure mode that matters: in production it is caught
        // and downgraded to a local store, so the app keeps working and stops syncing.
        let container = try ModelContainer(for: schema, configurations: config)
        #expect(container.schema.entities.count == schema.entities.count)
    }

    /// The schema is **exactly** these entities — so a schema that silently lost one
    /// cannot pass the load test above by loading less, and one that silently gained
    /// one cannot pass this.
    ///
    /// It was two `contains` assertions, which is a containment check: a third entity
    /// could not fail it, and neither could a fourth (M18 §4H). That mattered because
    /// three other gates are blind in the same direction at the same time — the
    /// CloudKit schema script, the seed, and the container itself all derive their
    /// idea of the app from `Schema([...])`, so nothing anywhere could fail for an
    /// entity missing from it.
    ///
    /// The set is written out on purpose. Adding an entity has to be a deliberate
    /// edit here, next to a comment explaining that the CloudKit Development →
    /// Production deploy is a **human step in the Console** that this test cannot
    /// perform and no CLI can (M17 §14D).
    @Test func theShippingSchemaContainsExactlyTheEntitiesWeExpect() {
        let names = Set(SoundpostModelContainer.productionSchema.entities.map(\.name))
        #expect(names == ["Capsule", "ListeningConsent", "SoundRejection"])
    }

    /// The CloudKit rules the schema comment claims, checked rather than asserted in
    /// prose: no unique constraints anywhere, and every attribute either optional or
    /// carrying a default. These are precisely what the store rejects at load.
    @Test func everyEntityObeysTheCloudKitRules() {
        for entity in SoundpostModelContainer.productionSchema.entities {
            #expect(entity.uniquenessConstraints.isEmpty,
                    "\(entity.name) has a uniqueness constraint, which CloudKit forbids")
            for attribute in entity.attributes {
                let ok = attribute.isOptional || attribute.defaultValue != nil
                #expect(ok, "\(entity.name).\(attribute.name) is neither optional nor defaulted")
            }
            for relationship in entity.relationships {
                #expect(relationship.isOptional,
                        "\(entity.name).\(relationship.name) is a required relationship, which CloudKit forbids")
            }
        }
    }

    /// `ListeningConsent` is the entity this suite was added for — pin its shape
    /// directly, since a change to it is what would break consent syncing.
    @Test func listeningConsentIsShapedTheWayCloudKitNeeds() throws {
        let entity = try #require(
            SoundpostModelContainer.productionSchema.entities.first { $0.name == "ListeningConsent" })
        let attributes = Set(entity.attributes.map(\.name))
        #expect(attributes.isSuperset(of: ["id", "enabled", "changedAt"]))
        #expect(entity.uniquenessConstraints.isEmpty,
                "id must not be unique — CloudKit forbids it, and duplicates are resolved by changedAt instead")
    }
}
