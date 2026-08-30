import Foundation
import SwiftData
import CloudKit

#if DEBUG
/// Debug-only: write one row of every entity the schema declares, so CloudKit's
/// **Development** environment materialises the record types.
///
/// `NSPersistentCloudKitContainer` creates `CD_<Entity>` types on first export and
/// only in Development — Production is read-only from the client, and Production is
/// what App Store builds talk to. So a new entity needs a device run before it can be
/// promoted, and until it is promoted the feature silently does not sync
/// (docs/M15-DEVPLAN.md §11B-i).
///
/// Getting `CD_ListeningConsent` to exist previously meant "run a signed build on a
/// device signed into iCloud and toggle Listening once" — a step that depends on
/// someone tapping the right switch, and one that cannot create a record type for an
/// entity with no UI at all. This does it directly, and will keep doing it for
/// whatever entities the schema grows next.
///
/// Wrapped in `#if DEBUG` and reachable only via `-initializeCloudKitSchema`: it is
/// not in a Release build, and cannot run by accident.
enum CloudKitSchemaSeed {

    /// Insert a throwaway row per entity, save so CloudKit exports it, then delete
    /// the rows and save again.
    ///
    /// The record **type** survives the deletion — that is the whole point. Schema is
    /// what we are creating; the rows are the means, and leaving them behind would
    /// put a stray consent record into whichever account ran this.
    ///
    /// Every step reports what actually happened. This is the tool the release is
    /// gated on, and a seed that prints "cleaned up" whether or not it worked is a
    /// false green in the one place we cannot afford one.
    @MainActor
    static func run(in container: ModelContainer) async {
        let context = container.mainContext
        let entities = container.schema.entities.map(\.name).sorted()
        print("SCHEMA-SEED entities in schema: \(entities)")

        // **Checked before anything is inserted, and it ABORTS** (M18 §4H).
        //
        // It used to print a line and `continue`, so an entity with no seed row cost
        // one message in the middle of a long log and the run still ended with
        // `SCHEMA-SEED cleaned up` — a success line over a record type that was never
        // created. That is the same false green as the fixed 20-second wait and the
        // promote that could not promote (M17 §15A), in the tool the whole release is
        // gated on. A seed that cannot cover the schema has not half worked.
        //
        // Ahead of the iCloud check because it is a defect in this source rather than
        // in the machine: it is true on every device, so someone whose simulator is
        // signed out should still learn about it on the run where it exists.
        let missing = Self.entitiesWithoutASeedRow(in: container.schema)
        guard missing.isEmpty else {
            print("""
                SCHEMA-SEED ✗ no seed row defined for: \(missing.joined(separator: ", ")). \
                NOTHING was seeded by this run. Add a case to \
                CloudKitSchemaSeed.seedRow(for:) for each — without one its CD_ record \
                type is never created in CloudKit Development, so it can never be \
                promoted to Production, and the feature silently does not sync there.
                """)
            return
        }

        // Without an iCloud account there is no export, so no record type is created —
        // and every other line below still prints exactly as it does on a good run.
        // That is worth failing loudly for: this seed was verified on a simulator with
        // no account signed in, and it reported a clean run that had accomplished
        // nothing. The whole release is gated on this step; it must not be possible to
        // walk away from it believing it worked.
        let status = try? await CKContainer(identifier: SoundpostModelContainer.cloudKitContainerID)
            .accountStatus()
        guard status == .available else {
            print("""
                SCHEMA-SEED ✗ iCloud is not available on this device (accountStatus: \
                \(status.map(String.init(describing:)) ?? "unreadable")). Nothing can be \
                exported, so NO record type will be created. Sign in to iCloud in \
                Settings — a Simulator signed into iCloud is enough, a physical device \
                is not required — and run this again.
                """)
            return
        }

        // Driven off the schema, not a hard-coded list. The previous version seeded
        // exactly one entity while its own doc promised it would keep working "for
        // whatever entities the schema grows next" — so the next entity added would
        // have got no seed at all, and the failure would have looked identical to
        // this one: a record type missing from Development for no visible reason.
        var inserted: [any PersistentModel] = []
        for name in Self.seedableEntities(in: container.schema) {
            guard let model = seedRow(for: name) else { continue }   // ruled out above
            context.insert(model)
            inserted.append(model)
            print("SCHEMA-SEED inserted \(name)")
        }
        guard !inserted.isEmpty else {
            print("SCHEMA-SEED ✗ nothing to seed; no record types will be created")
            return
        }
        do {
            try context.save()
            print("SCHEMA-SEED saved \(inserted.count) row(s); waiting for the CloudKit export")
        } catch {
            print("SCHEMA-SEED ✗ save failed: \(error)")
            return
        }

        // CloudKit exports asynchronously after the save and SwiftData exposes no
        // completion to await, so this waits. `Task.sleep` throws on cancellation and
        // that must NOT be swallowed: this runs in a SwiftUI `.task`, which is
        // cancelled when the view goes away or the app is backgrounded, and a
        // cancelled sleep returns instantly — the delete would then land before the
        // export, the two would coalesce, no record type would be created, and the
        // old `try?` would have printed success anyway. Leave the rows in place and
        // say so instead; a stray row is recoverable, a silent no-op is not.
        do {
            try await Task.sleep(for: .seconds(20))
        } catch {
            print("SCHEMA-SEED ✗ interrupted before the export could finish — rows left in place, DO NOT trust this run. Keep the app foregrounded and try again.")
            return
        }

        for model in inserted { context.delete(model) }
        do {
            try context.save()
            print("SCHEMA-SEED cleaned up. Now run: scripts/cloudkit-schema.sh status")
        } catch {
            print("SCHEMA-SEED ✗ cleanup failed: \(error) — a seeded row may remain in this iCloud account; delete it in the CloudKit Console")
        }
    }

    /// The one entity the seed is allowed not to cover.
    ///
    /// `Capsule` needs real audio to be meaningful, and `CD_Capsule` has existed in
    /// both environments since M9. Named rather than written inline in a `where`
    /// clause, so a test can assert it is the *only* exemption — an unexplained skip
    /// is how a second one gets added quietly.
    static let seedExemptEntity = "Capsule"

    /// The entities this seed is responsible for creating record types for.
    static func seedableEntities(in schema: Schema) -> [String] {
        schema.entities.map(\.name).filter { $0 != seedExemptEntity }.sorted()
    }

    /// Which of those it cannot build a row for — the question `run` asks before it
    /// inserts anything, and the one `ModelRegistrationTests` asks of the shipping
    /// schema without needing an iCloud account or a device.
    static func entitiesWithoutASeedRow(in schema: Schema) -> [String] {
        seedableEntities(in: schema).filter { seedRow(for: $0) == nil }
    }

    /// One throwaway row per entity the seed knows how to create.
    ///
    /// A `nil` here **aborts the run**, so adding an entity without adding its seed
    /// row fails loudly instead of leaving a record type uncreated behind a line
    /// saying `cleaned up`.
    private static func seedRow(for entityName: String) -> (any PersistentModel)? {
        switch entityName {
        case "ListeningConsent":
            // `.distantPast` so that if cleanup ever fails, the stray row loses to
            // every dated answer and cannot decide consent for whoever ran this.
            return ListeningConsent(enabled: true, changedAt: .distantPast)
        default:
            return nil
        }
    }
}
#endif
