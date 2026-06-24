import Testing
import Foundation
@testable import Soundpost

/// The pure entitlement→features seam (M11 §4C) and the structural lapse-safety
/// invariant (M11 §1.2/§4D): a `ProGate` only ever caps *new* Pro actions and is
/// never an input to whether already-created content stays usable.
@MainActor
struct ProGateTests {

    // MARK: - Free mapping

    @Test func freeGateCapsAtSixtySeconds() {
        #expect(ProGate(isPro: false).maxRecordingDuration == 60)
    }

    @Test func freeGateCannotExport() {
        #expect(ProGate(isPro: false).canExport == false)
    }

    @Test func freeGateOnlyOffersClassicTheme() {
        let gate = ProGate(isPro: false)
        #expect(gate.availableThemes == [.classic])
        #expect(gate.canUse(.classic))
        #expect(!gate.canUse(.tinted))
        #expect(!gate.canUse(.outlined))
        #expect(!gate.canUse(.graphite))
    }

    // MARK: - Pro mapping

    @Test func proGateExtendsToFiveMinutes() {
        #expect(ProGate(isPro: true).maxRecordingDuration == 300)
    }

    @Test func proGateCanExport() {
        #expect(ProGate(isPro: true).canExport == true)
    }

    @Test func proGateOffersEveryTheme() {
        let gate = ProGate(isPro: true)
        #expect(gate.availableThemes == Theme.allCases)
        for theme in Theme.allCases {
            #expect(gate.canUse(theme))
        }
    }

    // MARK: - Identity

    @Test func gateIsEquatableAndDeterministic() {
        #expect(ProGate(isPro: true) == ProGate(isPro: true))
        #expect(ProGate(isPro: false) == ProGate(isPro: false))
        #expect(ProGate(isPro: true) != ProGate(isPro: false))
    }

    /// `.classic` is the free base and must always be available, so a free user
    /// (or a lapsed Pro user) can never be stranded without a usable theme.
    @Test func classicThemeIsAlwaysAvailable() {
        #expect(ProGate(isPro: false).canUse(.classic))
        #expect(ProGate(isPro: true).canUse(.classic))
    }

    // MARK: - Lapse-safety invariant (the cardinal rule)

    /// A capsule created while Pro — here a 5-minute clip that only Pro could have
    /// recorded — stays fully usable when the gate reports `isPro == false`.
    /// `ProGate` is not even an input to `isContentVisible()`; visibility is a
    /// function of capsule *state*, never entitlement. This is what guarantees a
    /// lapsed annual can never lock a memory (M11 §1.2/§4D).
    @Test func proMadeCapsuleStaysVisibleAndIntactAfterLapse() throws {
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(
            capsule,
            audioFileName: "long.m4a",
            durationSeconds: 300,            // a Pro-length clip
            waveformSamples: [0.1, 0.8, 0.4]
        )
        try store.save()

        let lapsed = ProGate(isPro: false)

        // The gate caps only the *next* recording — the stored 300s clip is
        // untouched, plays at full length, and remains visible.
        #expect(lapsed.maxRecordingDuration == 60)
        #expect(capsule.durationSeconds == 300)
        #expect(capsule.waveformSamples == [0.1, 0.8, 0.4])
        #expect(capsule.isContentVisible() == true)
        #expect(capsule.state == .captured)
    }
}
