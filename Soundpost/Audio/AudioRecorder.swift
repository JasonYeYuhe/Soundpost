import Foundation
import AVFoundation
import Observation

/// Foreground audio capture for a capsule: mono AAC/m4a at ~64 kbps
/// (docs/PROJECT.md §1e.4/§1e.6). No background mode — recording is finalized if
/// the app leaves the foreground or is interrupted, so a clip is never silently
/// lost or left half-open.
@MainActor
@Observable
final class AudioRecorder: NSObject {
    enum State: Equatable { case idle, recording, finished }

    enum RecorderError: Error { case permissionDenied, couldNotStart }

    private(set) var state: State = .idle
    /// Metered input level, 0...1, for the live recording UI.
    private(set) var level: Float = 0
    /// Rolling recent levels (newest last) for drawing a live waveform.
    private(set) var levels: [Float] = []
    /// Elapsed recording time in seconds.
    private(set) var duration: TimeInterval = 0
    private(set) var currentFileName: String?

    /// Called on the main actor when recording finalizes on its own — max
    /// duration reached, an interruption, or the input route disappearing —
    /// *not* on an explicit `stop()`. Lets the owner move to review so a clip is
    /// never silently lost.
    @ObservationIgnored var onAutoFinish: ((_ fileName: String, _ duration: TimeInterval) -> Void)?

    /// How many recent level samples to retain for the live waveform.
    private let levelHistory = 80

    /// Max clip length; recording auto-stops here. Settable (M11 §4D) so the
    /// capture VM can raise it to the Pro cap at record-start, read from
    /// `ProGate.maxRecordingDuration`. Read each metering tick, so it must be set
    /// before `start()`; changing it mid-recording is not supported.
    var maxDuration: TimeInterval

    private let store: AudioStore
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    /// The interruption + route-change observer tokens, retained so `deinit` can
    /// remove them. Block-based `addObserver` returns a token that must be removed
    /// explicitly; without storing them each recorder leaked two permanent
    /// registrations (one per capture VM) — the §S8 observer-leak fix.
    /// `nonisolated(unsafe)`: only mutated on the main actor (init), and `deinit`
    /// has exclusive access when it reads them, so there is no race.
    @ObservationIgnored private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    init(store: AudioStore = AudioStore(), maxDuration: TimeInterval = 60) {
        self.store = store
        self.maxDuration = maxDuration
        super.init()
        registerForInterruptions()
        registerForRouteChanges()
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Ask for microphone permission (iOS 17+ API).
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    func start() throws {
        guard state != .recording else { return }
        guard Self.permission != .denied else { throw RecorderError.permissionDenied }
        try store.ensureDirectory()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let fileName = store.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        let recorder = try AVAudioRecorder(url: store.url(for: fileName), settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }

        self.recorder = recorder
        currentFileName = fileName
        duration = 0
        level = 0
        levels = []
        state = .recording
        startMetering()
    }

    /// Stop and keep the recording. Returns the saved filename + duration.
    @discardableResult
    func stop() -> (fileName: String, duration: TimeInterval)? {
        guard let recorder, state == .recording, let fileName = currentFileName else { return nil }
        let finalDuration = recorder.currentTime
        recorder.stop()
        finishSession()
        duration = finalDuration
        state = .finished
        return (fileName, finalDuration)
    }

    /// Stop and discard the recording + its file.
    func cancel() {
        recorder?.stop()
        if let fileName = currentFileName { try? store.delete(fileName) }
        finishSession()
        currentFileName = nil
        duration = 0
        level = 0
        state = .idle
    }

    // MARK: Metering

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        // Map dBFS (-60...0) to a 0...1 level.
        let power = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (power + 60) / 60))
        levels.append(level)
        if levels.count > levelHistory { levels.removeFirst(levels.count - levelHistory) }
        duration = recorder.currentTime
        if duration >= maxDuration { finishAutomatically() }
    }

    /// Finalize from an automatic trigger and hand the clip back via `onAutoFinish`.
    private func finishAutomatically() {
        guard let result = stop() else { return }
        onAutoFinish?(result.fileName, result.duration)
    }

    private func finishSession() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Interruptions & route changes

    private func registerForInterruptions() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        observerTokens.append(token)
    }

    private func registerForRouteChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
        observerTokens.append(token)
    }

    /// Whether an interruption notification means we should finalize the clip — an
    /// interruption that *began* (a call, Siri, another app). Pure, so the "never
    /// lose a clip" trigger is unit-testable without a live recording (§S8).
    nonisolated static func shouldFinalizeForInterruption(_ note: Notification) -> Bool {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return false }
        return type == .began
    }

    /// Whether a route change means we should finalize — the input device went away
    /// (`oldDeviceUnavailable`), e.g. a Bluetooth or wired mic unplugged. Pure.
    nonisolated static func shouldFinalizeForRouteChange(_ note: Notification) -> Bool {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return false }
        return reason == .oldDeviceUnavailable
    }

    private func handleInterruption(_ note: Notification) {
        guard state == .recording, Self.shouldFinalizeForInterruption(note) else { return }
        // Finalize rather than risk a corrupt/half clip (no background recording).
        finishAutomatically()
    }

    private func handleRouteChange(_ note: Notification) {
        guard state == .recording, Self.shouldFinalizeForRouteChange(note) else { return }
        // The input device (e.g. a Bluetooth or wired mic) went away mid-record —
        // finalize the clip cleanly instead of leaving it half-open (PROJECT.md §1e.4).
        finishAutomatically()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if self.state == .recording { self.finishSession() }
        }
    }
}
