import Testing
import AVFoundation
import Foundation
import SwiftData
@testable import Soundpost

/// The video gate (M13 §4E) and the cardinal rule it must never break: **Soundpost
/// never charges you to receive a memory** (§1.1). Video export is a Pro *creation*
/// richness — additive, lapse-safe, gated only at the start of a *new* export — and
/// everything about receiving, revealing, browsing, playing and exporting your own
/// data stays free. These tests exist so that can't quietly regress.
@MainActor
struct VideoGateTests {

    private func captured(audioData: Data? = Data([1, 2, 3]), note: String? = "rain") throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.audioData = audioData
        capsule.durationSeconds = 7
        capsule.waveformSamples = [0.2, 0.8, 0.5]
        capsule.note = note
        capsule.mood = .calm
        return capsule
    }

    private let free = ProGate(isPro: false)
    private let pro = ProGate(isPro: true)

    // MARK: - The decision matrix

    @Test func proWithVisibleContentAndAudioMayExport() {
        #expect(VideoExportPolicy.decide(isContentVisible: true, hasAudio: true, gate: pro) == .allowed)
    }

    @Test func freeMeetsThePaywallRatherThanTheMenu() {
        #expect(VideoExportPolicy.decide(isContentVisible: true, hasAudio: true, gate: free) == .needsPro)
    }

    @Test func noAudioIsAnHonestRefusalNotAnUpsell() {
        // Pro, but there is genuinely nothing to render: say so, don't sell anything.
        #expect(VideoExportPolicy.decide(isContentVisible: true, hasAudio: false, gate: pro) == .nothingToExport)
    }

    /// Hidden content is refused *before* the entitlement is even consulted, for
    /// both tiers — a sealed capsule is never something to sell an upgrade for.
    @Test func hiddenContentIsNeverExportableForEitherTier() {
        #expect(VideoExportPolicy.decide(isContentVisible: false, hasAudio: true, gate: pro) == .nothingToExport)
        #expect(VideoExportPolicy.decide(isContentVisible: false, hasAudio: true, gate: free) == .nothingToExport)
    }

    /// A free user's tap always meets the *same* single paywall, even when the
    /// capsule happens to have no audio. Deliberate: if the answer varied with the
    /// capsule, the affordance would become a read-out of which capsules are
    /// exportable rather than a gate — and it would diverge from M11's behaviour.
    @Test func theFreePathDoesNotLeakWhichCapsulesAreExportable() {
        #expect(VideoExportPolicy.decide(isContentVisible: true, hasAudio: false, gate: free) == .needsPro)
        #expect(VideoExportPolicy.decide(isContentVisible: true, hasAudio: true, gate: free) == .needsPro)
    }

    // MARK: - Over real capsules

    @Test func aSealedNotDueCapsuleCannotBeVideoExported() throws {
        let capsule = try captured()
        try capsule.transition(to: .sealed)
        capsule.sealUntil = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)

        #expect(!capsule.isContentVisible())
        #expect(VideoExportPolicy.decide(for: capsule, gate: pro) == .nothingToExport)
        #expect(VideoExportPolicy.decide(for: capsule, gate: free) == .nothingToExport)
    }

    @Test func aSealedCapsuleWhoseDayHasComeCanBeExported() throws {
        let capsule = try captured()
        try capsule.transition(to: .sealed)
        capsule.sealUntil = Date(timeIntervalSinceNow: -60)

        #expect(capsule.isContentVisible())
        #expect(VideoExportPolicy.decide(for: capsule, gate: pro) == .allowed)
    }

    @Test func aCapsuleWithOnlyLegacyOnDiskAudioCanStillBeExported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VideoGateTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioStore = AudioStore(directory: directory)
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: 0.5)

        // Pre-backfill capsule: audio only on disk, no blob.
        let capsule = try captured(audioData: nil)
        capsule.audioFileName = fileName
        #expect(VideoExportPolicy.decide(for: capsule, gate: pro, audioStore: audioStore) == .allowed)

        // …and a dangling filename is refused honestly rather than crashing later.
        capsule.audioFileName = "gone.m4a"
        #expect(VideoExportPolicy.decide(for: capsule, gate: pro, audioStore: audioStore) == .nothingToExport)
    }

    // MARK: - Additive + lapse-safe (§1.1 / §10.4)

    /// The whole point: a lapse caps the *next* export and touches nothing already
    /// made. An exported video keeps working after Pro ends, because nothing in the
    /// render or the file re-reads `isPro`.
    @Test func anExportedVideoOutlivesTheEntitlementThatMadeIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VideoGateTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioStore = AudioStore(directory: root.appending(path: "audio", directoryHint: .isDirectory))
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: 0.5)
        let capsule = try captured(audioData: try Data(contentsOf: audioStore.url(for: fileName)))
        capsule.waveformSamples = (0..<32).map { Float(0.3 + 0.5 * abs(sin(Double($0)))) }

        // Exported while Pro.
        #expect(VideoExportPolicy.decide(for: capsule, gate: pro) == .allowed)
        let workspace = try VideoExportWorkspace.makeUnique(inTemporaryDirectory: root)
        let result = try await VideoExporter.export(
            try VideoExporter.input(for: capsule, in: workspace)
        )

        // Pro now lapses.
        #expect(VideoExportPolicy.decide(for: capsule, gate: free) == .needsPro)

        // The file is untouched and still a real, playable H.264 video.
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        let asset = AVURLAsset(url: result.url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        // And the capsule itself is as visible and as playable as it ever was.
        #expect(capsule.isContentVisible())
        #expect(capsule.audioSource == .data)
    }

    // MARK: - Free features stay free (§1.1, S3 regression tests)

    /// Receiving and revealing a memory never consults the gate. A resurfaced
    /// capsule opens, and its content is visible, with no entitlement at all.
    @Test func revealingAndOpeningAMemoryStaysFree() throws {
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "clip.m4a", audioData: Data([9]),
                               durationSeconds: 5, waveformSamples: [0.4])
        // Two days back, so `SealClock`'s normalization to 09:00 local can't land it
        // in the future.
        try store.seal(capsule, until: Date(timeIntervalSinceNow: -60 * 60 * 48))
        try store.save()

        #expect(capsule.isDueToResurface())
        try store.markResurfaced(capsule)
        #expect(capsule.isContentVisible())
        try store.open(capsule)
        try store.save()

        // Visibility is a function of state and date — the gate is not an input.
        #expect(capsule.isContentVisible())
        #expect(free.canExport == false)   // still not Pro, and it changed nothing
    }

    @Test func playbackStaysFree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VideoGateTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioStore = AudioStore(directory: directory)
        let fileName = try TestSupport.writeSineClip(into: audioStore, seconds: 0.5)

        let capsule = try captured(audioData: try Data(contentsOf: audioStore.url(for: fileName)))
        let player = AudioPlayer(store: audioStore)
        try player.play(capsule)
        #expect(player.state != .idle)
        player.stop()
    }

    @Test func browsingAndSearchStayFree() throws {
        let rain = try captured(note: "rain on the window")
        let birds = try captured(note: "birds at dawn")
        birds.mood = .joyful

        let all = [rain, birds]
        #expect(GalleryFilter.apply(all, .init(searchText: "rain")).count == 1)
        #expect(GalleryFilter.apply(all, .init(moods: [.joyful])).count == 1)
        #expect(GalleryFilter.apply(all, .init()).count == 2)
    }

    /// Export-your-data is a portability right, not a Pro feature — it must keep
    /// working for a free user, whatever the video gate says.
    @Test func exportingYourOwnDataStaysFree() throws {
        let store = try TestSupport.freshStore()
        let capsule = store.create()
        try store.markRecording(capsule)
        try store.markCaptured(capsule, audioFileName: "clip.m4a", audioData: Data(repeating: 7, count: 128),
                               durationSeconds: 4, waveformSamples: [0.5])
        capsule.note = "mine to keep"
        try store.save()

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "VideoGateTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }

        try CapsuleBulkExporter.writeBundle(
            in: store.context,
            container: TestSupport.container,
            to: folder
        )
        let manifest = try JSONDecoder.iso8601.decode(
            ExportManifest.self,
            from: Data(contentsOf: folder.appending(path: "manifest.json"))
        )
        #expect(manifest.capsuleCount == 1)
        #expect(manifest.capsules.first?.audioFile != nil)
        #expect(free.canExport == false)   // not Pro, and the bundle came out anyway
    }

    /// Video adds one capability and removes none: the free gate's other caps are
    /// exactly what they were before M13.
    @Test func theVideoFeatureIsPurelyAdditiveToTheGate() {
        #expect(free.maxRecordingDuration == 60)
        #expect(free.availableThemes == [.classic])
        #expect(free.canUse(.classic))
        // Video rides the existing `canExport` entitlement — no new product, no new
        // flag, so a lapsed user's surface is unchanged from M11.
        #expect(free.canExport == false)
        #expect(pro.canExport == true)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
