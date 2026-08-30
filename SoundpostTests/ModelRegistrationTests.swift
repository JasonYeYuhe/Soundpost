import Testing
import Foundation
import SwiftData
import ObjectiveC.runtime
@testable import Soundpost

/// M18 §4H / S1 — **a `@Model` that never reaches `productionSchema` is invisible to
/// every gate this project has, simultaneously.**
///
/// This is not a hypothetical, it is a trap that was already set in the exact file
/// M18 has to edit, and two reviewers found it independently. Declare
/// `@Model final class SoundRejection` and forget the `Schema([...])` line, and:
///
/// * the container never mirrors it, so CloudKit never creates the record type;
/// * `cloudkit-schema.sh`'s `expected_types()` is derived from that same array, so
///   it compares only what is listed and reports green;
/// * `CloudKitSchemaSeed` iterates `container.schema.entities`, so it has nothing to
///   seed — and, until S1, printed a line and carried on when a row was missing,
///   still ending with `cleaned up`;
/// * `CloudKitSchemaTests` asserted `contains("Capsule")` and
///   `contains("ListeningConsent")`, a containment check a third entity cannot fail.
///
/// Four gates green, feature silently not syncing. That is this project's recurring
/// shape — *a check that iterates an artefact cannot fail for what is missing from
/// the artefact* — and the answer has to read a **different** artefact.
///
/// So this one reads the built binary. It asks the Objective-C runtime for every
/// class the app image actually contains, keeps the ones that are SwiftData models,
/// and requires each to be in the schema the app ships. Nothing about it can be kept
/// in step by hand, because it is not a list.
///
/// `scripts/cloudkit-schema.sh check-models` asks the same question of the **source
/// tree** and runs in CI before anything is compiled. Two checks over two different
/// artefacts, deliberately: an answer to this failure shape cannot itself be a single
/// list that someone has to remember to update.
@Suite(.serialized)
struct ModelRegistrationTests {

    /// Every SwiftData model compiled into the app, found by asking the runtime
    /// rather than by naming them.
    private func modelClassesInTheApp() -> [String] {
        // Restricted to the app's own image: the test bundle, SwiftData itself and
        // every system framework are loaded in this process too, and their internal
        // models are not ours to register.
        guard let image = class_getImageName(Capsule.self) else {
            Issue.record("could not locate the app image — this check would pass over anything")
            return []
        }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
        defer { names.deallocate() }

        var found: [String] = []
        for index in 0..<Int(count) {
            // `NSClassFromString` takes the runtime name, which for a Swift class is
            // the mangled one this list already holds.
            guard let cls = NSClassFromString(String(cString: names[index])) else { continue }
            // A metatype conformance check — it reads conformance records and sends
            // the class no messages, so nothing here can run foreign `+initialize`.
            guard cls is any PersistentModel.Type else { continue }
            found.append(String(describing: cls))
        }
        return found
    }

    /// The check itself. Adding a `@Model` and forgetting `productionSchema` fails
    /// here, before it can reach CloudKit and be discovered by a user whose feature
    /// does not sync.
    @Test func everyModelCompiledIntoTheAppIsInTheShippingSchema() throws {
        let compiled = Set(modelClassesInTheApp())
        // The premise. If the runtime scan silently found nothing, every assertion
        // below would hold vacuously — which is the failure this whole suite exists
        // to refuse to make.
        #expect(compiled.contains("Capsule"),
                "the runtime scan found no models at all, so it is proving nothing")

        let registered = Set(SoundpostModelContainer.productionSchema.entities.map(\.name))
        let unregistered = compiled.subtracting(registered).sorted()
        #expect(unregistered.isEmpty, """
            \(unregistered.joined(separator: ", ")) is a @Model the app compiles and \
            SoundpostModelContainer.productionSchema does not list. CloudKit will \
            never create its record type, the schema gate derives its expectations \
            from that same array so it cannot notice, and the feature will simply not \
            sync — in Production only. Add it to Schema([...]) and to \
            CloudKitSchemaSeed.seedRow(for:).
            """)
    }

    /// The other direction, which is a different mistake: a schema naming an entity
    /// the binary does not have.
    @Test func theShippingSchemaNamesNothingTheAppDoesNotDefine() {
        let compiled = Set(modelClassesInTheApp())
        guard compiled.contains("Capsule") else { return }   // premise checked above
        let registered = Set(SoundpostModelContainer.productionSchema.entities.map(\.name))
        #expect(registered.subtracting(compiled).isEmpty)
    }

    // MARK: The seed, which is the second half of the same failure

    /// A record type exists in CloudKit Development only once a row of it has been
    /// exported. An entity the seed cannot build a row for therefore has no route
    /// into Development at all, no route into Production after that, and no symptom
    /// anywhere except a feature that does not sync.
    ///
    /// `scripts/cloudkit-schema.sh check-seed` asks this of the source in CI. This
    /// asks it of the schema the app will actually load, which is the thing the seed
    /// iterates.
    @Test func theSeedCanCreateARowForEveryEntityInTheShippingSchema() {
        let missing = CloudKitSchemaSeed.entitiesWithoutASeedRow(
            in: SoundpostModelContainer.productionSchema)
        #expect(missing.isEmpty, """
            \(missing.joined(separator: ", ")) has no case in \
            CloudKitSchemaSeed.seedRow(for:), so -initializeCloudKitSchema cannot \
            create its CD_ record type in Development and it can never be promoted.
            """)
    }

    /// `Capsule` is the one deliberate exemption, and it is named rather than
    /// implied — an unexplained exemption is how a second one gets added quietly.
    @Test func capsuleIsTheOnlyEntityTheSeedIsAllowedToSkip() {
        #expect(CloudKitSchemaSeed.seedExemptEntity == "Capsule")
        let schema = SoundpostModelContainer.productionSchema
        #expect(schema.entities.map(\.name).contains(CloudKitSchemaSeed.seedExemptEntity),
                "the exemption names an entity that is not in the schema, so it exempts nothing")
    }
}
