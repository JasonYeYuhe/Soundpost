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
        // `Capsule` is excluded deliberately: it needs real audio to be meaningful,
        // and `CD_Capsule` has existed in both environments since M9.
        var inserted: [any PersistentModel] = []
        for entity in container.schema.entities where entity.name != "Capsule" {
            guard let model = seedRow(for: entity.name) else {
                print("SCHEMA-SEED ✗ no seed row defined for \(entity.name) — add one here or its record type will never be created")
                continue
            }
            context.insert(model)
            inserted.append(model)
            print("SCHEMA-SEED inserted \(entity.name)")
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

    /// One throwaway row per entity the seed knows how to create.
    ///
    /// A `nil` here is reported loudly rather than skipped quietly, so adding an
    /// entity without adding its seed row fails visibly instead of leaving a record
    /// type uncreated.
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
