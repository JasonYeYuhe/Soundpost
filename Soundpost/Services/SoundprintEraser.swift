import Foundation
import SwiftData

/// Deleting every stored soundprint when the user withdraws listening consent
/// (M15 §4I).
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

    /// Clear every stored soundprint. Returns how many capsules were changed, so a
    /// caller (or a test) can tell a real erase from a no-op.
    ///
    /// Writing `nil` rather than the analysed-but-empty marker is deliberate: `nil`
    /// means *never analysed*, which is the truthful state to return to, and it is
    /// also what lets the backfill pick these capsules up again if the user changes
    /// their mind and turns listening back on.
    @discardableResult
    static func eraseAll(in context: ModelContext) throws -> Int {
        let capsules = try context.fetch(FetchDescriptor<Capsule>())
        var erased = 0
        for capsule in capsules where capsule.soundprintRaw != nil {
            capsule.soundprintRaw = nil
            erased += 1
        }
        if erased > 0 { try context.save() }
        return erased
    }
}
