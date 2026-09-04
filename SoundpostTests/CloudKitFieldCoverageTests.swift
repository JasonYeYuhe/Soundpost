import Testing
import Foundation
import SwiftData
@testable import Soundpost

/// M19 §4C / S2 — **a field the app declares but the server does not have.**
///
/// M18 §4H stopped an entity from never reaching `productionSchema`. This is the same
/// failure one level down: the entity is registered, the record type exists, and a
/// single *field* is missing server-side. Nothing throws. `NSPersistentCloudKitContainer`
/// mirrors what it can and drops the rest, so the feature that field carries silently
/// does not sync while every other gate stays green.
///
/// ### The premise this rests on, and why it needed an experiment
///
/// M17 §14D concluded that `cktool export-schema` "omits unindexed fields", on the
/// evidence that `CD_soundprintRaw` was missing from both exports while the CloudKit
/// Console listed it as a field to deploy. Every gate built on the export was written
/// off as untrustworthy on that basis. **That conclusion was wrong**, and M19 §4C
/// required an experiment before building anything on top of it:
///
/// * `CD_audioData` is `BYTES` and is present in the export, carrying
///   `QUERYABLE SORTABLE`. Every field in the export carries an index annotation —
///   there are no unindexed fields for it to omit. CoreData indexes everything it
///   mirrors.
/// * Read field by field against the CloudKit Console's own Development schema on
///   2026-09-05, the export matches **exactly**: same fifteen fields on `CD_Capsule`,
///   same index sets, and the same one missing.
///
/// So the export is field-complete for what the server holds. What it cannot tell you
/// — and what M17 mistook for an export defect — is whether the server holds
/// everything the *app* declares. CoreData creates a Development field the first time
/// a record carrying a value for it is written; a field nothing has ever written does
/// not exist server-side, and no diff between two server environments can see that,
/// because it is absent from both. `CD_soundprintRaw` appeared in Development at some
/// point between M17's export and M18's deploy for exactly that reason.
///
/// That is why this gate compares the **app's own schema** against the server, rather
/// than one environment against the other. The two environments are byte-identical
/// today and would be no matter how much they were both missing.
@Suite(.serialized)
struct CloudKitFieldCoverageTests {

    /// **A finding, not an exemption.**
    ///
    /// `Capsule.serverJobSyncedAt` (M10 §4D) does not exist in the CloudKit schema in
    /// either environment. Its own doc comment says it is "synced to the user's other
    /// devices via M9 CloudKit", and `NotificationPlanner` drops a device's local
    /// backstop when it is non-nil — the mechanism that makes exactly one notification
    /// fire per resurfacing across a person's devices.
    ///
    /// It has never been written, which is consistent with M10 server delivery never
    /// having worked in a shipped build, and that is why it was never created. The
    /// consequence is latent rather than live: while the field is nil everywhere, every
    /// device keeps its backstop, which is the safe direction. **The moment server
    /// delivery starts working it becomes a duplicate-notification bug** — one device
    /// sets the flag, the others never learn, and both a push and a local backstop
    /// fire.
    ///
    /// Closing it needs a write of a non-nil value into Development and a human deploy
    /// in the CloudKit Console (§4G). Until then it is recorded here **exactly**, not
    /// as an allow-list: the assertion is equality, so a second missing field fails and
    /// so does this one being fixed. A gap that can be forgotten is the shape this
    /// project keeps rediscovering.
    static let knownAbsent: Set<String> = ["CD_Capsule.CD_serverJobSyncedAt"]

    /// The checked-in export, so this runs offline and in CI.
    /// `scripts/cloudkit-schema.sh check-fields` is what stops it going stale.
    private func snapshot(_ environment: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/cloudkit-schema/\(environment).ckdb")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "no checked-in \(environment) schema — run cloudkit-schema.sh check-fields")
    }

    /// Record type → **every** field name, parsed out of a `.ckdb` export.
    ///
    /// The first version kept only lines beginning with `CD_`, which was the whole
    /// vocabulary of the question it was written for — the CoreData-mirrored entities.
    /// It also meant `DeliveryIdentity`, this container's one hand-made record type
    /// (M10 §S1), parsed as having **no fields at all**, so `userKey` could vanish from
    /// Production and `productionHoldsEveryFieldDevelopmentDoes` would report green
    /// over an empty set. That is this file's own subject, committed inside the file
    /// about it.
    ///
    /// So it keeps every field line and rejects only what is structurally not one: the
    /// `GRANT` clauses and the type's opening and closing lines. Quotes are stripped
    /// because the metadata fields are spelled `"___etag"`, and splitting is on any
    /// whitespace rather than on a literal space, so a tab-separated export cannot
    /// fold a field name together with its type into one token that matches nothing.
    private func recordTypes(in schema: String) -> [String: Set<String>] {
        var types: [String: Set<String>] = [:]
        var current: String?
        for line in schema.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("RECORD TYPE ") {
                // Trimmed again after the prefix: `RECORD TYPE  Foo (` with two spaces
                // would otherwise leave the name empty and file every one of that
                // type's fields under "", which reads as a type with no fields —
                // exactly the failure this parser was rewritten to stop having.
                current = String(trimmed.dropFirst("RECORD TYPE ".count)
                    .trimmingCharacters(in: .whitespaces)
                    .prefix { $0 != " " && $0 != "(" })
                types[current!] = []
            } else if trimmed.hasPrefix(");") {
                current = nil
            } else if let type = current, !trimmed.isEmpty, !trimmed.hasPrefix("GRANT ") {
                if let name = trimmed.split(whereSeparator: \.isWhitespace).first {
                    types[type]?.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
            }
        }
        return types
    }

    @Test func everyDeclaredFieldExistsInTheCloudKitSchema() throws {
        let development = recordTypes(in: try snapshot("DEVELOPMENT"))
        // The premise: the snapshot parsed into something. A parser that returned
        // nothing would make every assertion below vacuously true — this file's whole
        // subject is a check that could not fail for what was missing from it.
        #expect(development["CD_Capsule"]?.contains("CD_soundprintRaw") == true,
                "the snapshot did not parse — got \(development.keys.sorted())")
        // And it parsed the hand-made type too, whose fields carry no `CD_` prefix.
        // This is the premise the first parser could not have stated, because it was
        // the thing it got wrong.
        //
        // Named from `CloudKitDeliveryIdentity`'s own constants rather than as string
        // literals: this record type has no `Schema` to reflect over, so the names
        // here would otherwise be a second copy of a decision, and renaming the field
        // in the actor would leave this asserting the old one and passing.
        #expect(development[CloudKitDeliveryIdentity.recordType]?
            .contains(CloudKitDeliveryIdentity.keyField) == true,
                "the parser is blind to record types CoreData did not create")

        var missing: Set<String> = []
        for entity in SoundpostModelContainer.productionSchema.entities {
            let recordType = "CD_\(entity.name)"
            let fields = try #require(development[recordType],
                                      "\(recordType) is not in the CloudKit schema at all")
            for property in entity.properties {
                // `CD_<name>` holds for attributes, the composite ones (`mood`,
                // `place`, `state`) included — those mirror as a single BYTES column.
                // It does NOT hold for relationships: CloudKit mirrors a to-many as an
                // auxiliary record type, not as a field, so this loop would demand a
                // `CD_` column that is never going to exist and report a phantom gap.
                // The model has no relationships today. This fails loudly on the day
                // one is added rather than confusingly.
                #expect(!(property is Schema.Relationship), """
                    \(recordType).\(property.name) is a relationship. CloudKit mirrors \
                    those as auxiliary record types rather than as a CD_ field, so this \
                    gate's derivation does not describe them and needs extending before \
                    that relationship ships.
                    """)
                if !fields.contains("CD_\(property.name)") {
                    missing.insert("\(recordType).CD_\(property.name)")
                }
            }
        }

        #expect(missing == Self.knownAbsent, """
            The CloudKit schema does not match what the app declares.
              missing server-side: \(missing.sorted())
              recorded as known:   \(Self.knownAbsent.sorted())
            A field only in `missing` will not sync and nothing will say so. A field \
            only in `knownAbsent` has been fixed — remove it from that set and say when.
            """)
    }

    /// Production must not lag Development. This is the check the promote flow needs
    /// and the one M17 §14D thought it had: it is trustworthy now only because the
    /// experiment above established that the export is field-complete for server state.
    @Test func productionHoldsEveryFieldDevelopmentDoes() throws {
        let development = recordTypes(in: try snapshot("DEVELOPMENT"))
        let production = recordTypes(in: try snapshot("PRODUCTION"))
        #expect(!development.isEmpty && !production.isEmpty)

        for (type, fields) in development.sorted(by: { $0.key < $1.key }) {
            let deployed = try #require(production[type],
                                        "\(type) exists in Development and not in Production")
            #expect(fields.subtracting(deployed).isEmpty, """
                \(type) has fields in Development that Production does not: \
                \(fields.subtracting(deployed).sorted()). They need a deploy in the \
                CloudKit Console — cktool has no deploy subcommand (M17 §14D).
                """)
        }
    }
}
