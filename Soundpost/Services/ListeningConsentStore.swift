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
