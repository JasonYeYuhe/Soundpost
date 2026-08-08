import Foundation
import SwiftData

/// Whether Soundpost may listen to recordings — **for this person, not this
/// phone** (M15 §4I, revised).
///
/// It started as a plain `UserDefaults` flag, which made the switch per-device
/// while its effect was account-wide: the erase writes `soundprintRaw = nil` into
/// the CloudKit-mirrored store, so it propagated everywhere, but a second device
/// with listening still on would backfill those same capsules and sync the labels
/// straight back. Search found them again on the very device where the user had
/// turned it off, after the app said turning it off "also erases what it has
/// already heard".
///
/// **Why it lives in the SwiftData store rather than `NSUbiquitousKeyValueStore`.**
/// KVS is the textbook home for a small synced setting, and it would have needed a
/// new entitlement — but the deciding reason is ordering, not provisioning. KVS and
/// the capsule store are two independent sync channels with no ordering guarantee
/// between them, so a device could observe "consent withdrawn" before or after the
/// erase that accompanied it, and re-analyse in the gap. Keeping consent in the
/// same store as the data it governs means the decision and its effect travel
/// together, in order, over one channel.
///
/// CloudKit-legal by construction, like `Capsule`: no `@Attribute(.unique)`, every
/// property defaulted.
///
/// **No record means nobody has ever touched the switch**, and the default (on)
/// applies. Deliberate: seeding a row at launch would have every device racing to
/// create one, and a seeded row carries no user intent to preserve. The row is
/// written only by a deliberate toggle.
@Model
final class ListeningConsent {
    /// Not a `.unique` key — CloudKit forbids those. Used only to break ties
    /// deterministically when two devices wrote at the same instant.
    var id: UUID = UUID()

    /// The user's answer. Default on — see `SoundAnalysisPreferences` for why this
    /// one is not opt-in.
    var enabled: Bool = true

    /// When the user last answered, on whatever device they answered from. The
    /// resolution key: the most recent answer is the one that counts.
    var changedAt: Date = Date.distantPast

    init(id: UUID = UUID(), enabled: Bool = true, changedAt: Date = .distantPast) {
        self.id = id
        self.enabled = enabled
        self.changedAt = changedAt
    }
}
