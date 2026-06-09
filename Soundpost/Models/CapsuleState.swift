import Foundation

/// Lifecycle of a capsule. Raw values are persisted — **do not rename**.
///
/// Legal transitions (the core state machine — the riskiest, most foundational
/// piece per docs/PROJECT.md §3):
///
/// ```
/// draft ──▶ recording ──▶ captured ──▶ sealed ──▶ resurfaced ──▶ opened
///              │              ▲           │
///              └── draft ─────┘           └── captured  (cancel the seal)
/// ```
///
/// A `captured` capsule that is never sealed is simply viewable forever.
/// `opened` is terminal: a sealed capsule that has been revealed.
enum CapsuleState: String, Codable, CaseIterable, Sendable {
    /// Created, nothing recorded yet.
    case draft
    /// Actively recording audio.
    case recording
    /// Audio saved; a normal, viewable memory card (not sealed).
    case captured
    /// Sealed until a future date; content hidden, a notification is scheduled.
    case sealed
    /// The seal date passed and the user was notified, but hasn't opened it yet.
    case resurfaced
    /// A resurfaced capsule the user has revealed. Terminal.
    case opened
}

extension CapsuleState {
    /// The set of states this state may legally transition into.
    var allowedTransitions: Set<CapsuleState> {
        switch self {
        case .draft: [.recording]
        case .recording: [.captured, .draft]
        case .captured: [.sealed]
        case .sealed: [.resurfaced, .captured]
        case .resurfaced: [.opened]
        case .opened: []
        }
    }

    func canTransition(to next: CapsuleState) -> Bool {
        allowedTransitions.contains(next)
    }

    /// True when no further transitions are possible.
    var isTerminal: Bool { allowedTransitions.isEmpty }
}

/// Error thrown when an illegal lifecycle transition is attempted.
enum CapsuleStateError: Error, Equatable {
    case illegalTransition(from: CapsuleState, to: CapsuleState)
}
