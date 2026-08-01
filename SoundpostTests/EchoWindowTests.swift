import Testing
import Foundation
@testable import Soundpost

/// The custom echo window (M14 §4D/§4E), and the asymmetry that is the whole
/// difficulty of this milestone:
///
/// * a custom **mood colour** is a rendered preference → **lapse-safe**, keeps
///   applying forever (see `MoodPaletteTests`);
/// * a custom **echo window** seeds a *new* capture → **not** lapse-safe, read at
///   capture-start like `maxRecordingDuration`, so a lapsed user's next recording
///   quietly returns to 7–30 while everything already scheduled is untouched.
///
/// Implementing either one with the other's semantics is the bug M14 must not
/// ship, so both directions are pinned here.
@MainActor
struct EchoWindowTests {
    private let pro = ProGate(isPro: true)
    private let free = ProGate(isPro: false)

    // MARK: - The gate

    @Test func proGetsTheWindowTheyChose() {
        #expect(pro.echoWindow(preferred: 3...10) == 3...10)
        #expect(pro.echoWindow(preferred: 90...180) == 90...180)
    }

    @Test func proWithNoStoredChoiceGetsTheDefault() {
        #expect(pro.echoWindow(preferred: nil) == ProGate.defaultEchoWindow)
        #expect(ProGate.defaultEchoWindow == 7...30)
    }

    /// The asymmetry, stated as a test: the *stored preference survives*, but a
    /// lapsed user's next capture does not use it.
    @Test func aLapsedUserFallsBackToTheDefaultWindow() {
        #expect(free.echoWindow(preferred: 3...10) == ProGate.defaultEchoWindow)
        #expect(free.echoWindow(preferred: 200...300) == ProGate.defaultEchoWindow)
        #expect(free.echoWindow(preferred: nil) == ProGate.defaultEchoWindow)
    }

    @Test func windowsAreClampedIntoSaneBounds() {
        // Never today — an echo that fires immediately defeats the surprise.
        #expect(pro.echoWindow(preferred: 0...10).lowerBound >= 1)
        #expect(pro.echoWindow(preferred: -5...(-1)).lowerBound >= 1)
        // Never so far out that it is really a seal.
        #expect(pro.echoWindow(preferred: 1...5000).upperBound == 365)
        // Lower never exceeds upper after clamping.
        let clamped = ProGate.clampEchoWindow(400...500)
        #expect(clamped.lowerBound <= clamped.upperBound)
        #expect(clamped.upperBound <= 365)
    }

    // MARK: - The store

    @Test func theStoreRoundTripsAndForgetsCleanly() {
        let originalLower = UserDefaults.standard.object(forKey: EchoPreferences.lowerKey)
        let originalUpper = UserDefaults.standard.object(forKey: EchoPreferences.upperKey)
        defer {
            UserDefaults.standard.set(originalLower, forKey: EchoPreferences.lowerKey)
            UserDefaults.standard.set(originalUpper, forKey: EchoPreferences.upperKey)
            if originalLower == nil { UserDefaults.standard.removeObject(forKey: EchoPreferences.lowerKey) }
            if originalUpper == nil { UserDefaults.standard.removeObject(forKey: EchoPreferences.upperKey) }
        }

        EchoPreferences.storedWindow = nil
        #expect(EchoPreferences.storedWindow == nil)

        EchoPreferences.storedWindow = 4...12
        #expect(EchoPreferences.storedWindow == 4...12)

        // Out-of-bounds input is clamped on the way in, never stored raw.
        EchoPreferences.storedWindow = 0...9999
        #expect(EchoPreferences.storedWindow == 1...365)

        // A half-written pair reads as "never chosen" rather than as a bad window.
        UserDefaults.standard.removeObject(forKey: EchoPreferences.upperKey)
        #expect(EchoPreferences.storedWindow == nil)

        EchoPreferences.storedWindow = nil
        #expect(EchoPreferences.storedWindow == nil)
    }

    @Test func theEffectiveWindowRespectsTheEntitlementNotJustTheStore() {
        let originalLower = UserDefaults.standard.object(forKey: EchoPreferences.lowerKey)
        let originalUpper = UserDefaults.standard.object(forKey: EchoPreferences.upperKey)
        defer {
            if let originalLower { UserDefaults.standard.set(originalLower, forKey: EchoPreferences.lowerKey) }
            else { UserDefaults.standard.removeObject(forKey: EchoPreferences.lowerKey) }
            if let originalUpper { UserDefaults.standard.set(originalUpper, forKey: EchoPreferences.upperKey) }
            else { UserDefaults.standard.removeObject(forKey: EchoPreferences.upperKey) }
        }

        EchoPreferences.storedWindow = 2...5
        #expect(EchoPreferences.effectiveWindow(gate: pro) == 2...5)
        // Same stored preference, no entitlement → the default. The preference is
        // deliberately KEPT, so resubscribing restores their choice.
        #expect(EchoPreferences.effectiveWindow(gate: free) == ProGate.defaultEchoWindow)
        #expect(EchoPreferences.storedWindow == 2...5)
    }

    // MARK: - Date seeding

    @Test func aSeededEchoLandsInsideItsWindow() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        for window in [1...1, 3...10, 7...30, 90...120] {
            for _ in 0..<40 {
                let date = CaptureViewModel.randomEchoDate(from: reference, in: window)
                let days = Calendar.current.dateComponents([.day], from: reference, to: date).day ?? -1
                #expect(window.contains(days), "\(days) outside \(window)")
            }
        }
    }

    @Test func theDefaultSeedingWindowIsStillSevenToThirty() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<40 {
            let date = CaptureViewModel.randomEchoDate(from: reference)
            let days = Calendar.current.dateComponents([.day], from: reference, to: date).day ?? -1
            #expect((7...30).contains(days))
        }
    }

    @Test func aCaptureDrawsItsEchoFromTheWindowItWasGiven() {
        let viewModel = CaptureViewModel()
        viewModel.echoWindow = 3...4
        viewModel.seedEchoIfNeeded()

        let echo = viewModel.echoAt
        #expect(echo != nil)
        let days = Calendar.current.dateComponents([.day], from: .now, to: echo!).day ?? -1
        #expect((2...4).contains(days), "seeded \(days) days out, expected the 3…4 window")

        // Idempotent: seeding again must not re-roll (the §S2 picker-jitter fix).
        viewModel.seedEchoIfNeeded()
        #expect(viewModel.echoAt == echo)
    }

    /// A lapse must never reach back and change an echo that is already set — the
    /// counterpart to "a lapsed user's *next* capture uses the default".
    @Test func anEchoAlreadySetOnACapsuleIsNeverRecomputed() throws {
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "clip.m4a", audioData: Data([1]),
                               durationSeconds: 6, waveformSamples: [0.4])
        let chosen = Date(timeIntervalSinceNow: 3 * 86_400)
        store.setEcho(capsule, at: chosen)
        try store.save()

        let before = capsule.echoAt
        #expect(before != nil)

        // The entitlement disappears. Nothing consults it over stored content.
        #expect(free.echoWindow(preferred: 3...4) == ProGate.defaultEchoWindow)
        #expect(capsule.echoAt == before)
        #expect(capsule.isContentVisible())
    }
}
