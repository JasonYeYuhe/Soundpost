import Foundation
import SwiftData
import Testing
@testable import Soundpost

/// A lock-screen notification shows a heard phrase only where a card would (M22 §4E,
/// M22-START item 5).
///
/// The notification body is baked in when it is scheduled and read on a locked phone, so
/// it must obey the same rule as every in-app surface — `SoundAnalysisPreferences.mayReveal`:
/// listening on **and** this device has standing. Before M22 the digest carried the stored
/// label whatever either said, and listening fed only the content version.
@MainActor
@Suite("Lock-screen copy reveals only what a card would")
struct LockScreenRevealTests {
    private func capsuleWithAHeardSound() throws -> (CapsuleStore, Capsule) {
        let store = try TestSupport.isolatedStore()
        let capsule = Capsule(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: [Soundprint.Label(identifier: "rain", confidence: 0.9)]
        ).stored
        store.context.insert(capsule)
        return (store, capsule)
    }

    @Test func aHeardSoundReachesTheDigestOnlyWhenItMayBeRevealed() throws {
        let (_, capsule) = try capsuleWithAHeardSound()
        let readable = RejectionIndex()
        let shown = NotificationCoordinator.digests(for: [capsule], rejections: readable, reveal: true)
        #expect(shown[capsule.id]?.soundprint != nil, "the label is withheld even when it may be shown")
        let hidden = NotificationCoordinator.digests(for: [capsule], rejections: readable, reveal: false)
        #expect(hidden[capsule.id]?.soundprint == nil, "a lock screen shows a label its cards hide")
        let unreadable = NotificationCoordinator.digests(for: [capsule], rejections: nil, reveal: true)
        #expect(unreadable[capsule.id]?.soundprint == nil, "a failed corrections read must still suppress it")
    }

    /// The body itself — what a locked phone shows — leads with nothing heard when the
    /// label may not be revealed, exactly as if the capsule had never been analysed.
    @Test func theBodyIsTheSameAsAnUnanalysedCapsulesWhenHidden() throws {
        let (_, capsule) = try capsuleWithAHeardSound()
        let item = PlannedNotification(capsuleID: capsule.id, fireDate: Date(timeIntervalSince1970: 1_800_000_000),
                                       timeZoneID: nil, kind: .echo)
        let hidden = try #require(NotificationCoordinator.digests(for: [capsule], rejections: RejectionIndex(),
                                                                  reveal: false)[capsule.id])
        var unanalysed = hidden
        unanalysed.soundprint = nil
        let shown = try #require(NotificationCoordinator.digests(for: [capsule], rejections: RejectionIndex(),
                                                                 reveal: true)[capsule.id])
        let hiddenBody = NotificationCopy.make(for: item, digest: hidden, personalized: true).body
        #expect(hiddenBody == NotificationCopy.make(for: item, digest: unanalysed, personalized: true).body)
        #expect(hiddenBody != NotificationCopy.make(for: item, digest: shown, personalized: true).body,
                "the fixture's label never reaches the body, so this test proves nothing")
    }

    /// Both halves of the cards' rule: listening off (standing kept), and listening on
    /// without standing — the phone set up as new, before it has recorded or answered.
    @Test func theRuleIsListeningAndStanding() async {
        let cases: [(listening: Bool, standing: Bool, reveal: Bool, version: String)] = [
            (true, true, true, "p1"),
            (false, true, false, "p1n"),
            (true, false, false, "p1n"),
            (false, false, false, "p1n"),
        ]
        for c in cases {
            await TestSupport.withIsolatedListening(c.listening) {
                SoundAnalysisPreferences.hasStanding = c.standing
                let reveal = NotificationCoordinator.notificationsMayRevealHeardSounds
                #expect(reveal == c.reveal, "listening \(c.listening), standing \(c.standing)")
                // The content version follows, so a body scheduled under one answer is
                // re-issued under the other.
                #expect(NotificationPreferences.contentVersion(personalized: true, listening: reveal) == c.version)
            }
        }
    }

    /// The coordinator uses the rule, in both places that need it.
    @Test func theCoordinatorAsksTheRevealRule() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/Services/NotificationCoordinator.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("let reveal = Self.notificationsMayRevealHeardSounds"))
        #expect(code.contains("static var notificationsMayRevealHeardSounds: Bool { SoundAnalysisPreferences.mayReveal }"))
        #expect(code.contains("contentVersion: NotificationPreferences.contentVersion(personalized: personalized, listening: reveal)"))
        #expect(code.contains("Self.digests(for: capsules, rejections: rejections, reveal: reveal)"))
        #expect(!code.contains("SoundAnalysisPreferences.isEnabled"), "the coordinator reads listening without standing")
    }
}
