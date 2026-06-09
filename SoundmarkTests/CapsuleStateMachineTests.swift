import Testing
import Foundation
@testable import Soundmark

/// Tests for the capsule lifecycle state machine — the riskiest, most
/// foundational piece (docs/PROJECT.md §3, M1).
struct CapsuleStateMachineTests {

    @Test func startsInDraft() {
        #expect(Capsule().state == .draft)
    }

    @Test func happyPathToOpened() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        try capsule.transition(to: .sealed)
        try capsule.transition(to: .resurfaced)
        try capsule.transition(to: .opened)
        #expect(capsule.state == .opened)
        #expect(capsule.state.isTerminal)
    }

    @Test func illegalTransitionThrowsAndPreservesState() {
        let capsule = Capsule()
        #expect(throws: CapsuleStateError.illegalTransition(from: .draft, to: .sealed)) {
            try capsule.transition(to: .sealed)
        }
        #expect(capsule.state == .draft)
    }

    @Test func recordingCanCancelBackToDraft() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .draft)
        #expect(capsule.state == .draft)
    }

    @Test func sealedCanUnsealToCaptured() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        try capsule.transition(to: .sealed)
        try capsule.transition(to: .captured)
        #expect(capsule.state == .captured)
    }

    @Test func openedIsTerminal() throws {
        let capsule = Capsule()
        for next in [CapsuleState.recording, .captured, .sealed, .resurfaced, .opened] {
            try capsule.transition(to: next)
        }
        #expect(capsule.state.allowedTransitions.isEmpty)
        #expect(throws: CapsuleStateError.self) {
            try capsule.transition(to: .captured)
        }
    }

    /// Every state's declared transitions must be self-consistent with `canTransition`.
    @Test func transitionTableIsConsistent() {
        for state in CapsuleState.allCases {
            for candidate in CapsuleState.allCases {
                #expect(state.canTransition(to: candidate) == state.allowedTransitions.contains(candidate))
            }
        }
    }

    @Test func contentHiddenWhileSealedBeforeDate() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.sealUntil = Date(timeIntervalSince1970: 2_000_000_000)
        try capsule.transition(to: .sealed)

        #expect(capsule.isContentVisible(now: Date(timeIntervalSince1970: 1_000_000_000)) == false)
        #expect(capsule.isContentVisible(now: Date(timeIntervalSince1970: 2_000_000_001)) == true)
    }

    @Test func dueToResurfaceOnlyWhenSealedAndPast() throws {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        #expect(capsule.isDueToResurface(now: .now) == false) // not sealed yet
        capsule.sealUntil = Date(timeIntervalSince1970: 1_000)
        try capsule.transition(to: .sealed)
        #expect(capsule.isDueToResurface(now: Date(timeIntervalSince1970: 2_000)) == true)
        #expect(capsule.isDueToResurface(now: Date(timeIntervalSince1970: 500)) == false)
    }
}
