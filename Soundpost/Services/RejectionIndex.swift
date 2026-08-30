import Foundation

/// The resolved answer to "which labels has this person dismissed?", as a value
/// (M18 §4B).
///
/// **Built once, asked many times.** Resolving a winner means ordering every row for
/// a key, clamping its date and applying a tie-break; a gallery card must not do that
/// while it renders, and the gallery renders on a path the 20 Hz playback progress
/// already drives (M16 §7). So resolution happens once, in `SoundRejectionStore`, and
/// what reaches a display path is a `Set` lookup.
///
/// It is also why the display APIs take *this* rather than a `ModelContext`: a fetch
/// per capsule is the other way to get this wrong, and the type makes it impossible
/// to write by accident.
struct RejectionIndex: Equatable, Sendable {

    /// Capsule → the identifiers whose winning answer is "rejected".
    ///
    /// Only rejections are stored. An undo is an *answer*, and it matters to the
    /// store — a `false` row is what beats an older `true` — but by the time it gets
    /// here it has already won, and what a screen needs to know is only which labels
    /// to leave out. Keeping undos in the index would mean every caller had to know
    /// the difference between "not rejected" and "un-rejected", which is a
    /// distinction with no consequence at a render site.
    private let rejectedIdentifiersByCapsule: [UUID: Set<String>]

    init(_ rejectedIdentifiersByCapsule: [UUID: Set<String>] = [:]) {
        self.rejectedIdentifiersByCapsule = rejectedIdentifiersByCapsule.filter { !$0.value.isEmpty }
    }

    /// **No rejections, said deliberately.**
    ///
    /// M18 §4B removes the zero-argument display APIs so the compiler enumerates
    /// every call site, and this is how a site that genuinely has none says so. It is
    /// spelled at the call site with a reason, never defaulted — a default is exactly
    /// what let seven consumers drift apart in the first place.
    static let none = RejectionIndex()

    var isEmpty: Bool { rejectedIdentifiersByCapsule.isEmpty }

    func isRejected(_ identifier: String, for capsuleID: UUID) -> Bool {
        rejectedIdentifiersByCapsule[capsuleID]?.contains(identifier) ?? false
    }

    func rejectedIdentifiers(for capsuleID: UUID) -> Set<String> {
        rejectedIdentifiersByCapsule[capsuleID] ?? []
    }

    /// Every capsule with at least one rejection. For tests and diagnostics; no
    /// display path needs it.
    var capsuleIDs: Set<UUID> { Set(rejectedIdentifiersByCapsule.keys) }

    /// This capsule's slice, in the form `Soundprint` takes.
    func sounds(for capsuleID: UUID) -> RejectedSounds {
        RejectedSounds(rejectedIdentifiers(for: capsuleID))
    }
}

/// The identifiers **one capsule's** owner has dismissed (M18 §4B).
///
/// A separate type from `RejectionIndex` because `Soundprint` is a value parsed out
/// of one capsule's stored string and knows nothing about capsule ids; handing it the
/// whole index would mean handing it a `capsuleID` too, and the one honest caller
/// that has neither — the capture sheet, where the capsule does not exist yet —
/// would have had to invent one.
///
/// It exists so `.none` can be **spelled**. `Soundprint.showable*` take this with no
/// default, so the compiler enumerates every consumer; a `Set<String>` would have
/// worked identically except that `rejecting: []` says nothing about why, and this
/// project's recurring failure is precisely a silence that reads as a decision.
struct RejectedSounds: Equatable, Sendable {
    let identifiers: Set<String>

    init(_ identifiers: Set<String> = []) {
        self.identifiers = identifiers
    }

    /// **Nothing to apply, said deliberately.** Every use is expected to carry a
    /// comment saying why — see `CaptureViewModel.suggestedPhrases`, the one place in
    /// the app where it is structurally true rather than merely convenient.
    static let none = RejectedSounds()

    var isEmpty: Bool { identifiers.isEmpty }

    func contains(_ identifier: String) -> Bool { identifiers.contains(identifier) }
}
