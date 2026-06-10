import Testing
import Foundation
@testable import Soundpost

/// The "echo" mechanic: every saved capsule picks a random future day to remind
/// the user what today sounded like. Unlike a seal it hides nothing; sealing
/// supersedes it. Echoes share the nearest-64 notification window with seals.
@Suite(.serialized)
@MainActor
struct EchoTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func captured(echoOffset: TimeInterval?) throws -> Capsule {
        let capsule = Capsule(createdAt: now.addingTimeInterval(-86_400))
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.echoAt = echoOffset.map { now.addingTimeInterval($0) }
        return capsule
    }

    // MARK: Planner

    @Test func plannerIncludesFutureEchoesAsEchoKind() throws {
        let capsule = try captured(echoOffset: 5_000)
        let plan = NotificationPlanner.plan(capsules: [capsule], now: now)
        #expect(plan.count == 1)
        #expect(plan.first?.kind == .echo)
        #expect(plan.first?.capsuleID == capsule.id)
        #expect(plan.first?.fireDate == now.addingTimeInterval(5_000))
    }

    @Test func plannerExcludesPastEchoesAndEcholessCapsules() throws {
        let past = try captured(echoOffset: -5_000)
        let none = try captured(echoOffset: nil)
        #expect(NotificationPlanner.plan(capsules: [past, none], now: now).isEmpty)
    }

    @Test func echoesAndSealsShareTheNearestWindow() throws {
        let echoCapsule = try captured(echoOffset: 100)
        let sealedCapsule = try captured(echoOffset: nil)
        sealedCapsule.sealUntil = now.addingTimeInterval(200)
        try sealedCapsule.transition(to: .sealed)

        let plan = NotificationPlanner.plan(capsules: [sealedCapsule, echoCapsule], now: now)
        #expect(plan.map(\.kind) == [.echo, .seal]) // nearest-first across kinds
    }

    // MARK: Store

    @Test func sealingSupersedesEcho() throws {
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "x.m4a", durationSeconds: 3, waveformSamples: [])
        store.setEcho(capsule, at: now.addingTimeInterval(10_000))
        #expect(capsule.echoAt != nil)

        try store.seal(capsule, until: now.addingTimeInterval(99_000))
        #expect(capsule.echoAt == nil) // a sealed capsule never also echoes
    }

    // MARK: Capture flow

    @Test func finishingARecordingDrawsARandomEchoInRange() {
        let viewModel = CaptureViewModel()
        viewModel.finishRecordingForTesting(fileName: "e.m4a", duration: 5)
        #expect(viewModel.echoEnabled)
        #expect(viewModel.echoAt != nil)
        let days = Calendar.current.dateComponents([.day], from: .now, to: viewModel.echoAt ?? .now).day ?? 0
        #expect((6...30).contains(days)) // 7–30 calendar days out (6 allows same-time rounding)
    }

    @Test func saveAppliesEchoOnlyWhenEnabled() throws {
        let store = try TestSupport.freshStore()

        let keep = CaptureViewModel()
        keep.finishRecordingForTesting(fileName: "k.m4a", duration: 5)
        let chosen = keep.echoAt
        let kept = try keep.save(using: store)
        #expect(kept?.echoAt == chosen)

        let off = CaptureViewModel()
        off.finishRecordingForTesting(fileName: "o.m4a", duration: 5)
        off.echoEnabled = false
        let removed = try off.save(using: store)
        #expect(removed?.echoAt == nil)
    }

    @Test func randomEchoDateRespectsCustomRange() {
        for _ in 0..<20 {
            let date = CaptureViewModel.randomEchoDate(from: now, in: 3...3)
            let days = Calendar.current.dateComponents([.day], from: now, to: date).day
            #expect(days == 3)
        }
    }
}
