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
    static func winner(in context: ModelContext) throws -> ListeningConsent? {
        let all = try context.fetch(FetchDescriptor<ListeningConsent>())
        return all.max { a, b in
            if a.changedAt != b.changedAt { return a.changedAt < b.changedAt }
            if a.enabled != b.enabled { return a.enabled && !b.enabled }
            return a.id.uuidString < b.id.uuidString
        }
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
        keeper.enabled = enabled
        keeper.changedAt = now
        try context.save()
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
    /// `changedAt` is `.distantPast`: this is an answer of unknown age, so any dated
    /// answer from any device — including a later "turn it back on" — outranks it.
    private static func adoptPreAccountWithdrawal(in context: ModelContext) throws {
        guard !SoundAnalysisPreferences.isEnabled else { return }
        guard try winner(in: context) == nil else { return }
        context.insert(ListeningConsent(enabled: false, changedAt: .distantPast))
        try context.save()
        Diagnostics.info("Adopted this device's existing listening opt-out as the account-wide answer")
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
