#if DEBUG
import CloudKit
import Foundation
import SwiftData

/// **Does a correction actually reach CloudKit Production?** (M18 §5, M19 §8 item 2.)
///
/// M18 shipped `SoundRejection` and a release note promising "your corrections follow
/// your iCloud account". That was verified end to end in **Development** — two devices,
/// matching rows — and never in Production, which is the environment every shipped
/// build talks to. The two are separate databases with separately deployed schemas;
/// evidence from one says nothing about the other. `DeliveryIdentity` is the standing
/// proof of that: it had a deployed record type in Production and was inert in every
/// shipped build for months.
///
/// ### Why this is a launch argument rather than a tap
///
/// The tap version needs a person, a phone, and a build whose signature says
/// Production — and the last of those is exactly what went wrong the first time. This
/// runs the same code path the tap runs (`SoundRejectionStore.set`, then SwiftData's
/// mirroring), reports which environment it is actually pointed at, and can be re-run
/// by anyone in about a minute. It is the same shape as `CloudKitSchemaSeed`, for the
/// same reason: a release gated on a manual step eventually ships on an unperformed one.
///
/// ### What it writes, and why it is safe to write to a real library
///
/// One `SoundRejection` whose `capsuleID` matches no capsule that exists and whose
/// identifier is not in the sound vocabulary. It therefore reaches no display path at
/// all: `Soundprint.showable*` drops unknown identifiers, and nothing ever asks
/// `RejectionIndex` about a capsule id that is not in the library. It is a row in a
/// table, visible only to this check and to the CloudKit Console — and `clean` removes
/// it.
///
/// ### The three phases, and what each one proves
///
/// * `write` — insert, save, wait for the export. Proves the **upload** leg: the
///   entitlement resolved to Production at runtime, the mirroring delegate is alive,
///   and CoreData's field mapping matches the deployed schema. This is the leg that
///   carries almost all of the risk, and the one that failed silently for
///   `DeliveryIdentity`.
/// * `read` — after deleting and reinstalling the app, look for the row again. A local
///   store that has just been created cannot contain it, so finding it proves the
///   **download** leg — which is the half the release note actually promises.
/// * `clean` — delete it, and let that deletion export too.
enum ProductionSyncCheck {

    /// A capsule id that matches nothing, fixed so the Console query is a copy-paste
    /// rather than a hunt through a log.
    static let markerCapsuleID = UUID(uuidString: "00000000-M19-0000-0000-000000000000")
        ?? UUID(uuidString: "1D0E9F00-0000-4000-8000-000000000019")!

    /// Not in `SoundVocabulary.displayNames`, so no surface can render it even if the
    /// capsule id ever collided with a real one.
    static let markerIdentifier = "m19.production-sync-check"

    enum Phase: String { case write, read, clean }

    static var requestedPhase: Phase? {
        guard let index = CommandLine.arguments.firstIndex(of: "-verifyProductionSync"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return Phase(rawValue: CommandLine.arguments[index + 1])
    }

    @MainActor
    static func run(_ phase: Phase, in container: ModelContainer) async {
        print("PROD-SYNC ---- \(phase.rawValue) ----")
        print("PROD-SYNC container environment: \(environmentFromProfile())")

        // The guard the seed learned to need: with no account there is no export, and
        // every line below still prints as it does on a good run.
        let status = try? await CKContainer(identifier: SoundpostModelContainer.cloudKitContainerID)
            .accountStatus()
        guard status == .available else {
            print("""
                PROD-SYNC ✗ iCloud is not available (accountStatus: \
                \(status.map(String.init(describing:)) ?? "unreadable")). Nothing can \
                sync, so this run proves nothing.
                """)
            return
        }

        let context = container.mainContext
        switch phase {
        case .write:  await write(in: context)
        case .read:   read(in: context)
        case .clean:  await clean(in: context)
        }
    }

    // MARK: -

    @MainActor
    private static func write(in context: ModelContext) async {
        let existing = marker(in: context)
        if !existing.isEmpty {
            print("PROD-SYNC ! \(existing.count) marker row(s) already present — this run would not prove an upload. Run `clean` first.")
            return
        }
        do {
            // The real entry point the long-press uses, not a hand-built row: if the
            // store's write path ever stops mirroring, this has to fail with it.
            try SoundRejectionStore.set(true, identifier: markerIdentifier,
                                        forCapsule: markerCapsuleID, in: context)
        } catch {
            print("PROD-SYNC ✗ write failed: \(error)")
            return
        }
        print("PROD-SYNC wrote capsuleID=\(markerCapsuleID.uuidString) identifier=\(markerIdentifier)")
        // Same reasoning as CloudKitSchemaSeed: the export is asynchronous with no
        // completion to await, and a cancelled sleep returns instantly. If this is
        // interrupted, say so rather than reporting a run that did not finish.
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            print("PROD-SYNC ✗ interrupted before the export could finish — DO NOT trust this run.")
            return
        }
        print("""
            PROD-SYNC waited 30s for the export. Now look in the CloudKit Console:
            PROD-SYNC   PRODUCTION → Private Database → com.apple.coredata.cloudkit.zone
            PROD-SYNC   → CD_SoundRejection → expect CD_capsuleID = \(markerCapsuleID.uuidString)
            PROD-SYNC   And in DEVELOPMENT the same query must NOT show it.
            """)
    }

    @MainActor
    private static func read(in context: ModelContext) {
        let rows = marker(in: context)
        if rows.isEmpty {
            print("PROD-SYNC ✗ the marker row is NOT in this store. Either the import leg does not work, or the store has not finished syncing — wait and re-run.")
        } else {
            for row in rows {
                print("PROD-SYNC ✓ imported: rejected=\(row.rejected) changedAt=\(row.changedAt)")
            }
        }
    }

    /// Removes the marker **and any seed-shaped row**, and the second half is there
    /// because of a hazard this check discovered by falling into it.
    ///
    /// **Switching a build's CloudKit environment without wiping the container
    /// migrates the old environment's data into the new one.** Installing a
    /// Production-entitled build over a Development-entitled one keeps the app
    /// container — same bundle id, same store — and the mirroring delegate then treats
    /// everything already in that store as local changes and **exports them to
    /// Production**. A `CloudKitSchemaSeed` row that had only ever existed in
    /// Development arrived in Production that way, silently, with nothing reporting it.
    ///
    /// So: uninstall before switching environments, and clean both shapes here. An
    /// empty identifier cannot be a real correction — every real one carries a
    /// vocabulary identifier — so it is safe to match on.
    @MainActor
    private static func clean(in context: ModelContext) async {
        // Fetched whole and filtered in Swift, not with a `#Predicate`. The first
        // version used `#Predicate { $0.identifier.isEmpty }`, which matched nothing —
        // and because the fetch was wrapped in `try?`, the run printed "nothing to
        // clean" while the row it was written to remove sat in the table. A cleanup
        // that cannot fail out loud is worse than no cleanup. The table is tiny; there
        // is no reason to translate anything to SQL here.
        let all: [SoundRejection]
        do {
            all = try context.fetch(FetchDescriptor<SoundRejection>())
        } catch {
            print("PROD-SYNC ✗ could not read the table: \(error)")
            return
        }
        let markers = all.filter { $0.capsuleID == markerCapsuleID }
        let seeded = all.filter { $0.identifier.isEmpty && !markers.contains($0) }
        let rows = markers + seeded
        guard !rows.isEmpty else { print("PROD-SYNC nothing to clean"); return }
        for row in rows { context.delete(row) }
        do {
            try context.save()
        } catch {
            print("PROD-SYNC ✗ cleanup save failed: \(error)")
            return
        }
        print("PROD-SYNC deleted \(markers.count) marker + \(seeded.count) seed-shaped row(s); waiting for the export")
        do { try await Task.sleep(for: .seconds(20)) } catch {
            print("PROD-SYNC ✗ interrupted — rows may still be in CloudKit; delete them in the Console")
            return
        }
        print("PROD-SYNC clean.")
    }

    @MainActor
    private static func marker(in context: ModelContext) -> [SoundRejection] {
        let id = markerCapsuleID
        let descriptor = FetchDescriptor<SoundRejection>(
            predicate: #Predicate { $0.capsuleID == id })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Which CloudKit environment this **binary** is signed for.
    ///
    /// The one fact that made M18's verification void was that both devices were
    /// talking to Development while everyone believed otherwise, and nothing on screen
    /// said so. The entitlement is in the embedded provisioning profile, so the check
    /// can read it and state it rather than leaving it to be inferred from how the
    /// build was made.
    private static func environmentFromProfile() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else {
            return "unreadable (no embedded profile — a simulator build talks to Development)"
        }
        let plist = String(text[start.lowerBound..<end.upperBound])
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: Data(plist.utf8), format: nil) as? [String: Any],
              let entitlements = parsed["Entitlements"] as? [String: Any] else {
            return "unreadable (profile did not parse)"
        }
        let value = entitlements["com.apple.developer.icloud-container-environment"]
        if let one = value as? String { return one }
        if let many = value as? [String] {
            return "profile allows \(many.joined(separator: "/")) — the app's own entitlement decides"
        }
        return "absent from the profile (defaults to Development)"
    }
}
#endif
