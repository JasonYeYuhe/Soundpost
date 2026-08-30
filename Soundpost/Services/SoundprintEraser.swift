import Foundation
import SwiftData

/// Deleting everything Soundpost heard when the user withdraws listening consent
/// (M15 §4I, extended M18 §4F).
///
/// This lived as a private method inside `SettingsView`, which put the one
/// behaviour the release notes promise by name — "turning this off also erases
/// what it has already heard" — out of reach of the test target. Every other M15
/// rule (the gates, the confidence floor, the deny-list, the copy, the backfill's
/// idempotence) is tested against a stub through a seam; the deletion was the sole
/// exception, and it is the half most likely to be read as a privacy commitment.
///
/// Deliberately synchronous and immediate: when someone withdraws consent, "we'll
/// get to it" is not an acceptable answer.
enum SoundprintEraser {

    /// What one erase removed, so a caller (or a test) can tell a real erase from a
    /// no-op — and can tell the two kinds apart.
    struct Erased: Equatable {
        /// Capsules whose stored labels were cleared.
        let soundprints: Int
        /// Rejection rows removed (M18 §4F).
        let rejections: Int

        var total: Int { soundprints + rejections }
        var isEmpty: Bool { total == 0 }
    }

    /// Clear every stored soundprint **and every correction made to one**.
    ///
    /// Writing `nil` rather than the analysed-but-empty marker is deliberate: `nil`
    /// means *never analysed*, which is the truthful state to return to, and it is
    /// also what lets the backfill pick these capsules up again if the user changes
    /// their mind and turns listening back on.
    ///
    /// **The rejections go too, and that is a product decision rather than a tidy-up**
    /// (M18 §4F, §8 item 0). The Settings footer promises, in three languages, that
    /// turning listening off "erases what it has already heard, everywhere". A
    /// rejection row records that the classifier proposed a particular label for a
    /// particular capsule — it *is* derived from what Soundpost heard — so keeping it
    /// would make shipped copy untrue, which is rule 3.
    ///
    /// **The cost, stated rather than argued away:** turning listening off and back on
    /// re-analyses the library and every correction is gone. Corrections are rare and
    /// deliberate, so this will be felt. The alternative is amending copy that is
    /// currently true to carve out an exception; this project's habit is to keep the
    /// promise and pay the cost. It is the one call in M18 the owner may want to
    /// overturn, and overturning it is this function plus one test.
    ///
    /// One save, so the labels and the corrections leave together — a half-applied
    /// erase is the state the Settings alert would then be lying about.
    @discardableResult
    static func eraseAll(in context: ModelContext) throws -> Erased {
        let capsules = try context.fetch(FetchDescriptor<Capsule>())
        var soundprints = 0
        for capsule in capsules where capsule.soundprintRaw != nil {
            capsule.soundprintRaw = nil
            soundprints += 1
        }
        let rejections = try context.fetch(FetchDescriptor<SoundRejection>())
        for row in rejections { context.delete(row) }
        let erased = Erased(soundprints: soundprints, rejections: rejections.count)
        if !erased.isEmpty { try context.save() }
        return erased
    }
}
