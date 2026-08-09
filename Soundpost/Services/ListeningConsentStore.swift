import Foundation
import SwiftData

/// Reading and writing account-wide listening consent, and keeping this device's
/// fast local mirror (`SoundAnalysisPreferences`) in step with it.
///
/// Everything that gates on consent — the classifier, the backfill, the resurface
/// sentence, the notification content version — reads `SoundAnalysisPreferences`
/// synchronously, often as a defaulted parameter. That stays true: this type is the
/// only thing that knows consent is account-wide, and its job is to keep the mirror
/// honest so nothing else has to change or reach for a `ModelContext`.
enum ListeningConsentStore {

    /// The record that counts: most recent answer wins.
    ///
    /// Two devices can each create a record while offline, so more than one can
    /// exist. Ties go to **off** — clocks differ between devices, and when we cannot
    /// tell which answer came last, the privacy-preserving one is the safer thing to
    /// honour. A final tie-break on `id` keeps the outcome deterministic rather than
    /// dependent on fetch order.
    static func winner(in context: ModelContext, now: Date = .now) throws -> ListeningConsent? {
        let all = try context.fetch(FetchDescriptor<ListeningConsent>())
        return all.max { a, b in
            let aAt = Self.effectiveDate(a.changedAt, now: now)
            let bAt = Self.effectiveDate(b.changedAt, now: now)
            if aAt != bAt { return aAt < bAt }
            if a.enabled != b.enabled { return a.enabled && !b.enabled }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// A timestamp clamped to the present.
    ///
    /// "Last writer wins" is only as good as the clocks writing it. A device whose
    /// clock runs fast records an answer dated into the future, and every correctly
    /// dated answer after it loses — a grant written a year ahead would pin listening
    /// on for a year, which is the wrong side to fail on. Clamping costs nothing for
    /// honest timestamps and turns a future-dated record into "as recent as now",
    /// where the tie-break already prefers off.
    static func effectiveDate(_ date: Date, now: Date = .now) -> Date {
        min(date, now)
    }

    /// The effective account-wide answer. Falls back to this device's mirror when
    /// nobody has ever touched the switch — see `ListeningConsent` for why no row is
    /// seeded at launch.
    static func resolve(in context: ModelContext) throws -> Bool {
        try winner(in: context)?.enabled ?? SoundAnalysisPreferences.isEnabled
    }

    /// Record a deliberate answer from this device and mirror it locally.
    ///
    /// Collapses to a single record: any losers are deleted, so two offline writes
    /// reconcile to one row rather than accumulating.
    static func set(_ enabled: Bool, in context: ModelContext, now: Date = .now) throws {
        let all = try context.fetch(FetchDescriptor<ListeningConsent>())
        let keeper = all.first ?? {
            let fresh = ListeningConsent(enabled: enabled, changedAt: now)
            context.insert(fresh)
            return fresh
        }()
        for extra in all.dropFirst() { context.delete(extra) }
        let previousEnabled = keeper.enabled
        let previousAt = keeper.changedAt
        keeper.enabled = enabled
        keeper.changedAt = now
        do {
            try context.save()
        } catch {
            // `rollback()` does not restore already-materialised objects — this
            // project learned that when the backfill's first consent fix passed its
            // own assertion and still left the capsule mutated. Put the values back
            // by hand so a later unrelated save cannot commit a half-applied answer.
            keeper.enabled = previousEnabled
            keeper.changedAt = previousAt
            throw error
        }
        // Only after the write lands. The mirror is what every gate reads, so moving
        // it before the record is durable is how a device ends up acting on an answer
        // that was never stored.
        SoundAnalysisPreferences.isEnabled = enabled
    }

    /// Carry a pre-account-wide "off" into the synced record, once.
    ///
    /// Someone who turned listening off before this build has their answer only as a
    /// local `UserDefaults` mirror. Without this, that intent never becomes a record:
    /// they add a second device, it starts with the default (on) and finds no record,
    /// and it happily analyses the whole library they had opted out of — the very
    /// failure account-wide consent exists to prevent, just one device removed.
    ///
    /// Only a **non-default** mirror is adopted. `false` can only have got there by
    /// someone deliberately switching it off, so there is real intent to preserve.
    /// Seeding a `true` would be seeding the default — no intent, and every device
    /// racing to write one, which is what `ListeningConsent` deliberately avoids.
    ///
    /// Recorded **once per device**, so an adoption cannot keep re-asserting itself
    /// against later answers from anywhere.
    static let adoptionKey = "sound.consentAdoptedFromDevice"

    /// Dated `.now`, not `.distantPast`, and it does not stand aside for an existing
    /// record. Both of those were wrong in the first version.
    ///
    /// `.distantPast` loses to every dated answer, and skipping when a record already
    /// exists loses the opt-out entirely: device A upgrades and records "on"; device B
    /// stays on 1.6.0 and the user switches listening **off** there *afterwards*; B
    /// upgrades, finds A's record, skips — and B silently resumes listening, against
    /// the most recent thing the user actually did.
    ///
    /// So a local opt-out is carried across as a present-tense answer. It can, in
    /// principle, outrank a genuinely newer grant from another device, and that
    /// direction is the deliberate one: when two answers cannot be ordered, §1.2 says
    /// take the one that says stop. The one-shot flag keeps it to a single assertion.
    private static func adoptPreAccountWithdrawal(in context: ModelContext, now: Date = .now) throws {
        guard !SoundAnalysisPreferences.defaults.bool(forKey: adoptionKey) else { return }
        // Marked regardless of outcome: if this device's answer was the default at
        // upgrade there is nothing to carry across, now or ever.
        defer { SoundAnalysisPreferences.defaults.set(true, forKey: adoptionKey) }
        guard !SoundAnalysisPreferences.isEnabled else { return }
        try set(false, in: context, now: now)
        Diagnostics.info("Carried this device's existing listening opt-out into the account-wide answer")
    }

    /// Bring this device into line with the account-wide answer.
    ///
    /// Call at launch and on every remote merge. Returns the effective value.
    ///
    /// When consent is off, this erases unconditionally rather than only on a
    /// transition. The invariant worth holding is "consent off ⇒ no stored labels
    /// here", and it has to survive a device that was switched off elsewhere while
    /// this one was closed, an erase that synced before the consent record, and a
    /// batch that landed in between. The erase is a no-op when there is nothing to
    /// clear, so paying for it on every merge costs a fetch.
    @discardableResult
    static func applyToDevice(in context: ModelContext) throws -> Bool {
        try adoptPreAccountWithdrawal(in: context)
        let effective = try resolve(in: context)
        SoundAnalysisPreferences.isEnabled = effective
        if !effective {
            let erased = try SoundprintEraser.eraseAll(in: context)
            if erased > 0 {
                Diagnostics.info("Listening is off account-wide — erased soundprints that arrived here")
            }
        }
        return effective
    }
}
