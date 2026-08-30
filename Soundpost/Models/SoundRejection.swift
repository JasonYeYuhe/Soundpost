import Foundation
import SwiftData

/// One person saying **no, it wasn't** about one label on one capsule (M18 §4A).
///
/// M17 put a machine's guess onto a keepsake, attributed and permanently. It had no
/// way to be wrong. Codex's post-ship review said so plainly — "record-level LWW
/// makes the tombstone unsafe, but that does not make uncorrectable assertions safe"
/// (M17 §14A) — and this is the answer to it.
///
/// **A row, not a field.** The obvious design is a tombstone inside the capsule's
/// `soundprintRaw` string. M17 §4B rejected it and the reason is the same one
/// `ListeningConsent` was rebuilt for: once a row has synced, two devices editing it
/// are editing the same CKRecord, and `NSPersistentCloudKitContainer` resolves that
/// with **record-level last-writer-wins** before either version reaches our code. The
/// losing version is simply gone. A rejection stored on the capsule would be erased
/// by any other device's edit to that capsule, silently, with nothing left for a
/// timestamp to compare — and the label would come back.
///
/// Separate rows never conflict. Each device's answer survives as its own record, and
/// resolution happens here, in code we can read, over the full set.
///
/// **Keyed by the classifier identifier, never the phrase.** A phrase is
/// language-dependent, so a rejection made in Japanese would stop applying when the
/// phone switches to English. Same argument as the gallery's sound facet (M17 §S3).
///
/// *Known limit, recorded rather than solved:* if the curated vocabulary ever renames
/// an identifier (`rain` → `precipitation`), rejections keyed to the old one stop
/// matching and the sound returns under a new name. That is a change we would be
/// making rather than one happening to us, so the migration belongs to whatever
/// milestone makes it (M18 §4A, §11).
///
/// CloudKit-legal by construction, like `Capsule` and `ListeningConsent`: no
/// `@Attribute(.unique)`, every property defaulted. **Its record type must be
/// promoted to CloudKit Production by hand, in the Console** — no CLI can do it
/// (M17 §14D), and until it is, this does not sync.
@Model
final class SoundRejection {
    /// Not a `.unique` key — CloudKit forbids those. Used only to break ties
    /// deterministically when two devices wrote at the same instant.
    var id: UUID = UUID()

    /// The capsule this is about. A plain `UUID`, not a SwiftData relationship: a
    /// required relationship is CloudKit-illegal, and an optional one would put a
    /// second mutable field on `CD_Capsule` — which §4G forbids, because the tooling
    /// cannot verify a field (M17 §14D). The join is done in code.
    var capsuleID: UUID = UUID()

    /// The classifier identifier, e.g. `rain` — never the localized phrase.
    var identifier: String = ""

    /// The answer. `false` is a real answer meaning **undo**, not an absence: a
    /// mis-tap has to be recoverable, and "no row" already means "never asked".
    var rejected: Bool = true

    /// When the person answered, on whatever device they answered from. The
    /// resolution key, per `(capsuleID, identifier)` — see `SoundRejectionStore`.
    var changedAt: Date = Date.distantPast

    init(id: UUID = UUID(),
         capsuleID: UUID = UUID(),
         identifier: String = "",
         rejected: Bool = true,
         changedAt: Date = .distantPast) {
        self.id = id
        self.capsuleID = capsuleID
        self.identifier = identifier
        self.rejected = rejected
        self.changedAt = changedAt
    }

    /// What resolution is scoped to. `ListeningConsent` answers one global question,
    /// so its winner is a single row for the whole table; this answers many
    /// independent ones, and every part of the algorithm has to say which.
    struct Key: Hashable, Sendable {
        let capsuleID: UUID
        let identifier: String
    }

    var key: Key { Key(capsuleID: capsuleID, identifier: identifier) }
}
