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

    /// The one schema the app ships.
    ///
    /// Exposed rather than built inline so a test can exercise **this** schema against
    /// a CloudKit-backed configuration. A test that rebuilt the entity list would be
    /// testing its own copy: the next entity added here would not appear there, and
    /// the check that matters — does the CloudKit rung still load — would keep
    /// passing while production quietly dropped to local.
    ///
    /// `Capsule` is CloudKit-legal by construction: no `@Attribute(.unique)`, every
    /// property optional or defaulted (incl. `waveformSamples: [Float] = []`).
    /// CONTINGENCY (docs/M9-DEVPLAN.md §S3 / risks): SwiftData maps `[Float]` to a
    /// transformable; some CloudKit-backed stores reject a schema-level default for
    /// it. If that ever throws a schema-validation error, make `waveformSamples` an
    /// optional `[Float]?`.
    ///
    /// **1.6.1 deliberately ships one entity.** Account-wide listening consent adds a
    /// `ListeningConsent` model, and a new entity is a new CloudKit record type that
    /// only exists in Production once it has been promoted by hand (§11B-i). That
    /// promotion needs a device run nobody could do in time, and this release exists
    /// to get the §11C amplitude-gate remediation to users sooner rather than to wait
    /// on it. The feature is intact on `master` for the version that follows.
    static var productionSchema: Schema { Schema([Capsule.self]) }

    static func makeProductionContainer() -> ProductionStore {
        let schema = productionSchema

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
