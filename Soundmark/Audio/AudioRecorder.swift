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
    /// Elapsed recording time in seconds.
    private(set) var duration: TimeInterval = 0
    private(set) var currentFileName: String?

    /// Max clip length; recording auto-stops here.
    let maxDuration: TimeInterval

    private let store: AudioStore
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?

    init(store: AudioStore = AudioStore(), maxDuration: TimeInterval = 60) {
        self.store = store
        self.maxDuration = maxDuration
        super.init()
        registerForInterruptions()
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
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
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
        // Map dBFS (-160...0) to a 0...1 level.
        let power = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (power + 60) / 60))
        duration = recorder.currentTime
        if duration >= maxDuration { stop() }
    }

    private func finishSession() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Interruptions

    private func registerForInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard state == .recording,
              let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .began
        else { return }
        // Finalize rather than risk a corrupt/half clip (no background recording).
        stop()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if self.state == .recording { self.finishSession() }
        }
    }
}
