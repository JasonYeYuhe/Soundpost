import Testing
import Foundation
@testable import Soundpost

/// The cardinal rule (M11 §1.2/§4D, acceptance §10.3): a lapsed annual — or any
/// non-Pro state, including right after a delete+reinstall before the entitlement
/// restores — never locks an already-made capsule, its (Pro-length) audio, or an
/// applied non-base theme. Gates only ever guard the START of a new Pro action.
@MainActor
struct LapseSafetyTests {
    @Test func proMadeLongCapsuleAndThemeStayUsableWhenNotPro() throws {
        // A long clip with real, decodable audio — only Pro could have recorded
        // past 60s, so this stands in for a "made while Pro" capsule.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "LapseTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let audioStore = AudioStore(directory: dir)
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: 1.0)
        let audioData = try Data(contentsOf: audioStore.url(for: fileName))

        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(
            capsule,
            audioFileName: fileName,
            audioData: audioData,
            durationSeconds: 300,            // Pro-length
            waveformSamples: [0.2, 0.7, 0.5]
        )
        try store.save()

        // The user is now NOT Pro (lapse / fresh reinstall, entitlement unknown).
        let lapsed = ProGate(isPro: false)

        // 1) Audio is intact and still on the durable (playable) data path.
        #expect(capsule.audioSource == .data)
        #expect(capsule.durationSeconds == 300)
        // 2) It stays visible — visibility is a function of state, never the gate.
        #expect(capsule.isContentVisible())
        // 3) An applied Pro theme keeps rendering, though it can't be newly chosen.
        #expect(Theme.resolved(fromStored: "outlined") == .outlined)
        #expect(!lapsed.canUse(.outlined))
        // 4) The only thing the lapse changes: the cap on the NEXT recording.
        #expect(lapsed.maxRecordingDuration == 60)
        #expect(lapsed.canExport == false)

        try? FileManager.default.removeItem(at: dir)
    }
}
