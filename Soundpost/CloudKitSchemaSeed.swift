import Foundation
import SwiftData

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
    @MainActor
    static func run(in container: ModelContainer) async {
        let context = container.mainContext
        print("SCHEMA-SEED entities: \(container.schema.entities.map(\.name).sorted())")

        // One row per entity that is not `Capsule` — a capsule needs audio to be
        // meaningful, and `CD_Capsule` has existed in both environments since M9.
        let consent = ListeningConsent(enabled: true, changedAt: .distantPast)
        context.insert(consent)
        do {
            try context.save()
            print("SCHEMA-SEED inserted + saved; waiting for the CloudKit export")
        } catch {
            print("SCHEMA-SEED save failed: \(error)")
            return
        }

        // CloudKit exports asynchronously after the save. Give it room; there is no
        // completion callback to wait on that SwiftData exposes.
        try? await Task.sleep(for: .seconds(20))

        context.delete(consent)
        try? context.save()
        print("SCHEMA-SEED cleaned up. Now run: scripts/cloudkit-schema.sh status")
    }
}
#endif
