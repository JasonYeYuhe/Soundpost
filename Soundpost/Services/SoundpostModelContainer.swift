import Foundation
import SwiftData

/// Which storage rung the production container actually landed on.
enum StorageRung: String, Sendable {
    /// CloudKit-mirrored private database — the durability goal (S3/§8).
    case cloudKit
    /// On-disk only: signed-out / iCloud-disabled / CloudKit unavailable. The
    /// offline-first app is fully functional here; data mirrors up later if the
    /// user signs in (CloudKit handles that transparently).
    case local
    /// Last-ditch: even on-disk persistence failed. The app still launches and
    /// works this session, but capsules won't persist — surfaced honestly (S5).
    case inMemory
}

/// The production store: the container plus the rung it landed on.
struct ProductionStore {
    let container: ModelContainer
    let rung: StorageRung
}

/// Builds the production `ModelContainer` for `Capsule` via a fallback ladder —
/// **CloudKit-mirrored → local-only → in-memory** — logging which rung it reached.
///
/// CloudKit is a **mirror, never a gate** (docs/M9-DEVPLAN.md §C): a signed-out
/// or iCloud-disabled user transparently runs the local rung and still has a
/// fully working offline app. Init never fails the app; the worst case is the
/// in-memory rung, which the UI surfaces honestly rather than crashing.
///
/// Only the production app uses this. Unit tests keep their own in-memory
/// container, and the DEBUG demo/self-test paths are untouched (so neither ever
/// touches CloudKit or creates a second container for `Capsule`).
enum SoundpostModelContainer {
    /// The CloudKit container created in the Apple Developer portal / Xcode
    /// (human step, docs/M9-DEVPLAN.md §8). `.automatic` resolves it from the
    /// app's iCloud entitlement; recorded here for reference and account queries.
    static let cloudKitContainerID = "iCloud.com.soundpost.Soundpost"

    static func makeProductionContainer() -> ProductionStore {
        // `Capsule`'s schema is CloudKit-legal by construction: no @Attribute(.unique),
        // every property optional or defaulted (incl. `waveformSamples: [Float] = []`).
        // CONTINGENCY (docs/M9-DEVPLAN.md §S3 / risks): SwiftData maps `[Float]` to a
        // transformable; some CloudKit-backed stores reject a schema-level default for
        // it. If, once the §8 iCloud entitlement is live, this throws a schema-
        // validation error, make `waveformSamples` an optional `[Float]?`. Until then
        // the ladder simply falls through to the local rung — no crash, but also no
        // sync, so this MUST be confirmed on a real CloudKit-entitled build before ship.
        let schema = Schema([Capsule.self])

        // Rung 1 — CloudKit-mirrored private database.
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            let container = try ModelContainer(for: schema, configurations: config)
            Diagnostics.info("Durability: container on CloudKit rung")
            return ProductionStore(container: container, rung: .cloudKit)
        } catch {
            Diagnostics.notice("Durability: CloudKit container unavailable, using local rung")
        }

        // Rung 2 — local-only on-disk store. Offline-first still fully works.
        do {
            let config = ModelConfiguration(schema: schema)
            let container = try ModelContainer(for: schema, configurations: config)
            Diagnostics.info("Durability: container on local rung")
            return ProductionStore(container: container, rung: .local)
        } catch {
            Diagnostics.notice("Durability: local container failed, using in-memory rung")
        }

        // Rung 3 — in-memory last-ditch so the app still launches this session.
        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: config)
            return ProductionStore(container: container, rung: .inMemory)
        } catch {
            // In-memory creation should never fail; if it does, persistence is
            // fundamentally broken and there's nothing left to fall back to.
            fatalError("Could not create even an in-memory ModelContainer: \(error)")
        }
    }
}
