import Foundation
import Observation

/// Drives the capture flow: record → review (mood / note / place) → save.
/// Owns the audio services; persistence is handed in at save time so this stays
/// testable with an in-memory `CapsuleStore`.
@MainActor
@Observable
final class CaptureViewModel {
    enum Phase: Equatable { case idle, recording, review }

    private(set) var phase: Phase = .idle
    var permissionDenied = false
    /// Surfaced to the user via an alert when recording or saving fails, so
    /// failures are never silent.
    var errorMessage: String?

    // Produced by recording.
    private(set) var fileName: String?
    private(set) var duration: TimeInterval = 0
    private(set) var waveform: [Float] = []

    // Review fields, edited by the user.
    var mood: Mood?
    var note: String = ""
    private(set) var place: Place?
    var includePlace = false
    private(set) var isFetchingPlace = false

    /// The gentle echo reminder: picked at random when a recording is kept
    /// ("this capsule will remind you of today in N days"), user-editable and
    /// removable in the review step.
    var echoAt: Date?
    var echoEnabled = true

    /// What the on-device classifier heard, once it finishes (M15 §4K).
    /// Deliberately **not** awaited before the review screen appears: a 5-minute
    /// clip takes seconds to classify, and a memory must never wait on a guess.
    /// If it is not ready by the time the user saves, the capsule simply has no
    /// soundprint and the backfill picks it up later.
    private(set) var soundprint: Soundprint?
    private var classificationTask: Task<Void, Never>?

    let recorder: AudioRecorder
    let player: AudioPlayer
    private let audioStore: AudioStore
    private let location: LocationProvider
    private let waveformBuckets: Int
    /// Clips shorter than this are treated as accidental taps and discarded.
    private let minDuration: TimeInterval

    init(audioStore: AudioStore = AudioStore(),
         maxDuration: TimeInterval = 60,
         minDuration: TimeInterval = 1,
         waveformBuckets: Int = 56) {
        self.audioStore = audioStore
        self.recorder = AudioRecorder(store: audioStore, maxDuration: maxDuration)
        self.player = AudioPlayer(store: audioStore)
        self.location = LocationProvider()
        self.waveformBuckets = waveformBuckets
        self.minDuration = minDuration
        // When the recorder finalizes on its own (max duration, interruption, or
        // audio-route loss), move to review so the clip is never silently lost.
        self.recorder.onAutoFinish = { [weak self] fileName, duration in
            self?.handleFinishedRecording(fileName: fileName, duration: duration)
        }
    }

    // MARK: Recording

    /// `maxDuration` is read from `ProGate.maxRecordingDuration` by the view at
    /// the moment the user taps record (M11 §4D) — so the cap reflects the
    /// *current* entitlement, and a clip recorded while Pro is unaffected by a
    /// later lapse. There is no "record past the cap" gesture (the recorder hard-
    /// stops), so the longer-clip upsell is an explicit affordance in the view.
    func startRecording(maxDuration: TimeInterval = 60) async {
        recorder.maxDuration = maxDuration
        guard await AudioRecorder.requestPermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        do {
            try recorder.start()
            phase = .recording
        } catch {
            phase = .idle
            errorMessage = String(localized: "Couldn't start recording. Please try again.")
        }
    }

    func stopRecording() {
        guard let result = recorder.stop() else {
            phase = .idle
            return
        }
        handleFinishedRecording(fileName: result.fileName, duration: result.duration)
    }

    /// Shared by the manual stop and the recorder's automatic finalization.
    /// Discards too-short (accidental) clips; otherwise extracts the waveform
    /// and moves to the review step.
    private func handleFinishedRecording(fileName: String, duration: TimeInterval) {
        guard duration >= minDuration else {
            try? audioStore.delete(fileName)
            phase = .idle
            errorMessage = String(localized: "That recording was too short. Try holding a moment longer.")
            return
        }
        self.fileName = fileName
        self.duration = duration
        let clipURL = audioStore.url(for: fileName)
        let extraction = try? WaveformExtractor.extract(from: clipURL, buckets: waveformBuckets)
        waveform = extraction?.samples ?? []
        startClassifying(clipAt: clipURL, duration: duration, peak: extraction?.absolutePeak ?? 0)
        echoAt = Self.randomEchoDate(in: echoWindow)
        echoEnabled = true
        phase = .review
    }

    /// Seed `echoAt` with a random date if it is unset (idempotent). The echo
    /// picker binds to this, so it must be a *stable* value — re-rolling a fresh
    /// random date on every SwiftUI body evaluation made the picker jitter (the
    /// §S2 picker-getter purity fix). Call before presenting the picker.
    func seedEchoIfNeeded() {
        if echoAt == nil { echoAt = Self.randomEchoDate(in: echoWindow) }
    }

    /// The window this capture draws its echo from, decided **at capture-start**
    /// from the entitlement (M14 §4D) — exactly like `maxRecordingDuration`. The
    /// view sets it before recording; the default keeps every existing call site
    /// (and every test) on the free 7–30 window.
    var echoWindow: ClosedRange<Int> = ProGate.defaultEchoWindow

    /// Pick the surprise echo date: a uniformly random day inside `range`, keeping
    /// the recording's own time of day (poetic: "exactly N days later").
    /// `nonisolated` — a pure function over its arguments, so the view can seed the
    /// picker's stable fallback (`@State` default) without an actor hop.
    nonisolated static func randomEchoDate(
        from reference: Date = .now,
        in range: ClosedRange<Int> = ProGate.defaultEchoWindow
    ) -> Date {
        let days = Int.random(in: range)
        return Calendar.current.date(byAdding: .day, value: days, to: reference)
            ?? reference.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// How a finished recording becomes a soundprint. Swappable **only** so a test
    /// can drive the real arrival path.
    ///
    /// A review pointed out that setting `soundprint` directly from a test proves
    /// nothing about this method: a regression that added `note = …` or `mood = …`
    /// *inside* the completion below would pass every suggestion test. That is the
    /// rule the release notes state outright — "nothing is ever filled in for you" —
    /// so the seam belongs where the assignment happens, not beside it.
    typealias Classifying = @Sendable (URL, TimeInterval, Float) async -> Soundprint?
    var classify: Classifying = { url, duration, peak in
        await SoundprintService.soundprint(forClipAt: url, duration: duration, peak: peak).soundprint
    }

    /// Classify off the critical path (M15 §4K). Never blocks capture, never
    /// throws into it, and is cancelled if the user discards or re-records.
    private func startClassifying(clipAt url: URL, duration: TimeInterval, peak: Float) {
        classificationTask?.cancel()
        soundprint = nil
        let classify = self.classify
        classificationTask = Task { [weak self] in
            let result = await classify(url, duration, peak)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // The one assignment. A guess lands here and nowhere else — not on
                // `note`, not on `mood`.
                self?.soundprint = result
            }
        }
    }

    /// Test seam: wait for the in-flight classification to land, so a test can assert
    /// on what the *real* completion did rather than on a value it set itself.
    func awaitClassificationForTesting() async {
        await classificationTask?.value
    }

    func discard() {
        player.stop()
        if let fileName { try? audioStore.delete(fileName) }
        reset()
    }

    // MARK: Review

    func togglePlayback() {
        guard let fileName else { return }
        switch player.state {
        case .idle: try? player.play(fileName: fileName)
        case .playing: player.pause()
        case .paused: player.resume()
        }
    }

    func fetchPlace() async {
        isFetchingPlace = true
        let resolved = await location.requestPlace()
        isFetchingPlace = false
        place = resolved
        includePlace = (resolved != nil)
    }

    func clearPlace() {
        place = nil
        includePlace = false
    }

    /// Persist the reviewed recording as a `Capsule`. Returns it, or nil if
    /// there's nothing recorded. Leaves the file in place (now owned by the capsule).
    @discardableResult
    func save(using store: CapsuleStore) throws -> Capsule? {
        guard let fileName else { return nil }
        let capsule = store.create()
        try store.markRecording(capsule)
        // Read the just-recorded clip into the canonical `audioData` store so the
        // capsule is durable (and CloudKit-mirrorable) the moment it's saved. The
        // file stays as a fallback; the §S2 backfill reclaims it on a later launch.
        let recordedData = try? Data(contentsOf: audioStore.url(for: fileName))
        try store.markCaptured(
            capsule,
            audioFileName: fileName,
            audioData: recordedData,
            durationSeconds: duration,
            waveformSamples: waveform
        )
        capsule.mood = mood
        // Consent is checked again here, not only where the classifier ran. The two
        // are separated by an `await`, and consent is account-wide now: the user can
        // withdraw on another device while this clip is still being classified, the
        // merge erases every stored label, and then this save would write a fresh one
        // straight back — a label appearing after a withdrawal, with no later merge
        // needed to explain it. `applyToDevice` keeps this mirror current, so asking
        // it at the moment of writing is the check that matches when the data lands.
        capsule.soundprintRaw = SoundAnalysisPreferences.isEnabled ? soundprint?.stored : nil
        // This install has now recorded something, so its listening preference is a
        // real answer rather than an untouched default — which is what gives the
        // launch backfill standing to analyse the rest of the library. See
        // `SoundAnalysisPreferences.hasRecordedHere`.
        SoundAnalysisPreferences.hasRecordedHere = true
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        capsule.note = trimmed.isEmpty ? nil : trimmed
        capsule.place = includePlace ? place : nil
        // Normalize the echo day to a humane hour (09:00 device-local) on save —
        // `echoAt` carries the recording's raw time-of-day, which would otherwise
        // ring back at, say, 2:47 AM (M12 §S2).
        capsule.echoAt = echoEnabled ? echoAt.map { SealClock.normalize($0) } : nil
        try store.save()
        reset(deleteFile: false)
        return capsule
    }

    private func reset(deleteFile: Bool = true) {
        player.stop()
        if deleteFile, let fileName { try? audioStore.delete(fileName) }
        fileName = nil
        duration = 0
        waveform = []
        mood = nil
        note = ""
        place = nil
        includePlace = false
        echoAt = nil
        classificationTask?.cancel()
        classificationTask = nil
        soundprint = nil
        echoEnabled = true
        phase = .idle
    }
}

#if DEBUG
extension CaptureViewModel {
    /// Test seam: inject a "recorded" clip so `save()` can be exercised without
    /// touching the microphone. Same-file extension so it can set private state.
    func setReviewStateForTesting(fileName: String, duration: TimeInterval, waveform: [Float]) {
        self.fileName = fileName
        self.duration = duration
        self.waveform = waveform
        self.phase = .review
    }

    /// Test seam: drive the finalize path (shared by manual stop and the
    /// recorder's automatic finish) without a microphone.
    func finishRecordingForTesting(fileName: String, duration: TimeInterval) {
        handleFinishedRecording(fileName: fileName, duration: duration)
    }
}
#endif
