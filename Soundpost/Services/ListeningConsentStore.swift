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

    /// Settle an answer that arrived dated in the future, so which one wins stops
    /// depending on what time it happens to be.
    ///
    /// Clamping only at read time turned out to be momentary, and the gap is reachable.
    /// Device A's clock runs five minutes fast and records "on" at its 12:05; at true
    /// 12:02 the user withdraws on device B, which records "off" at 12:02. Both rows
    /// exist — they diverged offline, which is the only way two rows ever survive. Until
    /// true 12:05, B clamps A's row to now, the two tie, and the tie-break correctly
    /// honours **off**. Then true 12:06 arrives: A's row is no longer in the future,
    /// 12:05 genuinely beats 12:02, and the next launch or merge turns listening back
    /// **on** by itself. The user switched it off, watched it go off, and minutes later
    /// it is on again with the labels re-analysed — the exact failure account-wide
    /// consent exists to prevent, arriving by a different road.
    ///
    /// **Rewriting the future date to `now` does not fix it**, which is worth saying
    /// plainly because it is the obvious move: settling A to the moment we noticed
    /// (12:02-and-a-bit) puts it *after* B's honest 12:02, so the grant wins even
    /// sooner. Any single timestamp we invent hands the record an ordering it has not
    /// earned.
    ///
    /// So we stop trying to order it. A device that dates an answer into the future has
    /// told us its clock is unusable, and no later reading will make these two
    /// orderable. That is the situation the tie-break already has a rule for (§1.2):
    /// when two answers cannot be ordered, take the one that says stop. Applying it
    /// here writes a single trustworthy "off" — which is also what the tie-break itself
    /// would have said in the window before the clamp expired, so this makes the
    /// early answer permanent rather than inventing a new one.
    ///
    /// When the answers all agree there is nothing to arbitrate, and the date is simply
    /// brought back to the present so it cannot sit in the future indefinitely.
    ///
    /// Returns whether anything was written.
    @discardableResult
    static func settleFutureDatedAnswers(in context: ModelContext, now: Date = .now) throws -> Bool {
        let all = try context.fetch(FetchDescriptor<ListeningConsent>())
        guard all.contains(where: { $0.changedAt > now }) else { return false }

        if let first = all.first, all.allSatisfy({ $0.enabled == first.enabled }) {
            // Editing a row in place is exactly what `set` refuses to do, and the
            // difference matters: this writes a repair, not an answer. Two devices
            // clamping the same row both write roughly their own `now`, so whichever
            // version CloudKit keeps says the same thing. Losing a version of an
            // *answer* would lose intent; losing a version of this loses nothing.
            for record in all where record.changedAt > now { record.changedAt = now }
            try context.save()
            return true
        }

        // Unorderable *and* disagreeing. Replace the lot with one trustworthy
        // withdrawal — deleting rather than adding, because an added row cannot win:
        // it would be dated `now` while the untrustworthy grant sits in the future,
        // and the grant would take over the moment the clock reached it. Every row
        // removed here is one this decision has already accounted for; a genuine
        // answer made after this arrives as a newer row and wins normally.
        for record in all { context.delete(record) }
        let settled = ListeningConsent(enabled: false, changedAt: now)
        context.insert(settled)
        do {
            try context.save()
        } catch {
            context.delete(settled)
            throw error
        }
        SoundAnalysisPreferences.isEnabled = false
        Diagnostics.notice("A listening answer arrived dated in the future and the answers disagree — honouring the withdrawal")
        return true
    }

    /// The effective account-wide answer. Falls back to this device's mirror when
    /// nobody has ever touched the switch — see `ListeningConsent` for why no row is
    /// seeded at launch.
    static func resolve(in context: ModelContext) throws -> Bool {
        try winner(in: context)?.enabled ?? SoundAnalysisPreferences.isEnabled
    }

    /// Record a deliberate answer from this device and mirror it locally.
    ///
    /// **Every answer is a new row. Nothing is ever edited in place** — and that is the
    /// whole design, not an implementation detail.
    ///
    /// The first version kept one row and updated it. That looks tidier and quietly
    /// throws away the ordering this type exists to compute: once a single row has
    /// synced, both devices are editing the *same* CKRecord, and
    /// `NSPersistentCloudKitContainer` resolves that conflict with its own
    /// last-writer-wins before either version reaches `winner()`. The losing version
    /// is simply gone. So a device that was offline with a stale "on" exports after a
    /// newer "off" lands, CloudKit keeps the "on" as the latest write to that record,
    /// and the user's withdrawal disappears with no trace for `changedAt` to compare.
    /// The careful tie-break above would never have run.
    ///
    /// Separate rows never conflict, so every device's answer survives as its own
    /// record and `winner()` gets to do its job on the full set. It also deletes the
    /// three-way collapse that used to live here, along with the race where two
    /// devices picked different keepers and deleted each other's rows.
    ///
    /// Rows do not accumulate without bound: an answer supersedes everything strictly
    /// older, so those are removed in the same save. That cannot lose intent — a newer
    /// answer from elsewhere is a *newer* row, which this never touches.
    static func set(_ enabled: Bool, in context: ModelContext, now: Date = .now) throws {
        let superseded = try context.fetch(FetchDescriptor<ListeningConsent>())
            .filter { $0.changedAt < now }
        let answer = ListeningConsent(enabled: enabled, changedAt: now)
        context.insert(answer)
        for old in superseded { context.delete(old) }
        do {
            try context.save()
        } catch {
            // `rollback()` does not restore already-materialised objects — this
            // project learned that when the backfill's first consent fix passed its
            // own assertion and still left the capsule mutated. Dropping the pending
            // insert by hand is what keeps a later unrelated save from committing an
            // answer this one failed to write.
            context.delete(answer)
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
        // Nothing to carry across: this device's answer was the default at upgrade,
        // so there is no intent to preserve, now or ever. Settled permanently.
        guard !SoundAnalysisPreferences.isEnabled else {
            SoundAnalysisPreferences.defaults.set(true, forKey: adoptionKey)
            return
        }
        // Marked only once the record is durable. A `defer` here would mark the
        // adoption done even when the save threw — the opt-out would then never be
        // carried across on any later launch, and the next device the user adds
        // would find no record, default to on, and analyse the library they had
        // opted out of. That is precisely the failure this function exists to
        // prevent, so the flag has to mean "the record was written", not "we tried".
        try set(false, in: context, now: now)
        SoundAnalysisPreferences.defaults.set(true, forKey: adoptionKey)
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
        // After the adoption, not before: adopting collapses every row into one, so
        // running this first would arbitrate over a picture that is about to be
        // replaced. Settle any answer that arrived dated into the future, so it
        // cannot quietly overturn a later withdrawal once this clock catches up.
        try settleFutureDatedAnswers(in: context)
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
