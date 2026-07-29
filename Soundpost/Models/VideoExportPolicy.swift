import Foundation

/// Whether a **new** video export may start (M13 §4E).
///
/// Pure and value-driven, so the rule is unit-testable without StoreKit, SwiftData
/// or a view — the same reason `ProGate` exists. The view asks this once and acts on
/// the answer; it never reimplements the reasoning inline.
///
/// **Decided once, at the tap.** The decision is taken before the render starts and
/// never re-consulted: a render already under way finishes even if the entitlement
/// lapses halfway through, and an exported video is the user's to keep forever.
/// Gating caps only the *start* of a new Pro action (M11 §1.2/§4D) — it never reaches
/// back over content that already exists. Nothing in the render path reads `isPro`.
enum VideoExportPolicy {
    enum Decision: Equatable, Sendable {
        /// Go ahead and render.
        case allowed
        /// Free, or lapsed: meet the one paywall. No tease, no half-open menu.
        case needsPro
        /// There is genuinely nothing to render. Say so honestly — never sell it.
        case nothingToExport
    }

    /// - Parameters:
    ///   - isContentVisible: whether the user can already see this capsule's content.
    ///   - hasAudio: whether a clip actually exists to render (video needs sound;
    ///     the M11 *image* share does not, which is why this is video-specific).
    ///   - gate: the entitlement mapping, read at the moment of the tap.
    static func decide(isContentVisible: Bool, hasAudio: Bool, gate: ProGate) -> Decision {
        // A sealed-not-due capsule cannot be exported at all. It is *also*
        // structurally unreachable — the locked detail view hosts no export
        // affordance (M11 §4G) — so this is a second, testable line of defence
        // rather than the only one.
        guard isContentVisible else { return .nothingToExport }

        // The gate is checked before the audio check on purpose: a free user's tap
        // always meets the same single paywall, exactly as in M11. Otherwise the
        // affordance would quietly become a read-out of which capsules happen to be
        // exportable, which is a different (and worse) thing than a gate.
        guard gate.canExport else { return .needsPro }

        guard hasAudio else { return .nothingToExport }
        return .allowed
    }

    /// The same decision for a concrete capsule. `@MainActor` because reading a
    /// SwiftData model is; `audioSource` is the established dual-read that prefers
    /// the durable blob and falls back to a legacy on-disk clip.
    @MainActor
    static func decide(
        for capsule: Capsule,
        gate: ProGate,
        now: Date = .now,
        audioStore: AudioStore = AudioStore()
    ) -> Decision {
        let hasAudio: Bool
        switch capsule.audioSource {
        case .data: hasAudio = true
        case .file(let name): hasAudio = audioStore.fileExists(name)
        case .none: hasAudio = false
        }
        return decide(
            isContentVisible: capsule.isContentVisible(now: now),
            hasAudio: hasAudio,
            gate: gate
        )
    }
}
