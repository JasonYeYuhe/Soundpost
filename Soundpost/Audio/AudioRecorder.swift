import Foundation
import AVFoundation
import Observation
import UIKit

/// Foreground audio capture for a capsule: mono AAC/m4a at ~64 kbps
/// (docs/PROJECT.md §1e.4/§1e.6). No background mode — recording is finalized if
/// the app leaves the foreground or is interrupted, so a clip is never silently
/// lost or left half-open.
///
/// **Until 1.13.1 the first half of that sentence was not true** (M23 H4). Nothing
/// observed the app leaving the foreground. iOS suspends an app without the audio
/// background mode, deactivates its session, and tells it so only when it runs
/// again; by then `AVAudioRecorder.currentTime` reads 0 on the stopped recorder,
/// so the take was deleted as "too short", or the delegate left the screen frozen
/// on a take that `stop()` would no longer return. Three changes close it:
/// `didEnterBackground` finishes the take *synchronously* while the recorder still
/// runs; `stop()` never reports less than the metered elapsed time; and a recorder
/// that stops on its own finishes the take instead of stranding it.
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
    /// duration reached, the app leaving the foreground, an interruption, the input
    /// route disappearing, or the recorder stopping by itself — *not* on an explicit
    /// `stop()`. Lets the owner move to review so a clip is never silently lost.
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
    /// Where the observers are registered. `.default` in the app — it is where UIKit
    /// and `AVAudioSession` post. A test passes its own, so a lifecycle notification
    /// it posts reaches this recorder and nothing else in the test host.
    private let center: NotificationCenter
    private let backend: Backend

    /// What `start()` and `finishSession()` ask of AVFoundation. The app only ever
    /// uses `.live`. A test passes its own, so a start can fail on cue and the test
    /// can see whether the shared audio session was closed again (after 1.13.1).
    struct Backend {
        var activateSession: () throws -> Void
        var deactivateSession: () -> Void
        var makeRecorder: (_ url: URL, _ settings: [String: Any]) throws -> AVAudioRecorder

        static var live: Backend {
            Backend(
                activateSession: {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
                    try session.setActive(true)
                },
                deactivateSession: {
                    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                },
                makeRecorder: { url, settings in try AVAudioRecorder(url: url, settings: settings) }
            )
        }
    }

    init(store: AudioStore = AudioStore(), maxDuration: TimeInterval = 60,
         center: NotificationCenter = .default, backend: Backend = .live) {
        self.store = store
        self.maxDuration = maxDuration
        self.center = center
        self.backend = backend
        super.init()
        registerForBackgrounding()
        registerForInterruptions()
        registerForRouteChanges()
    }

    deinit {
        observerTokens.forEach { center.removeObserver($0) }
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
        try backend.activateSession()

        let fileName = store.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        // The session is active from here, so every way out of `start()` either leaves
        // a take recording or closes the session again. Until this was fixed (after
        // 1.13.1), a recorder that could not be made or would not record threw from
        // here with the session still active: audio another app had been playing was
        // never told it could resume, and a file the recorder had already created
        // stayed on disk with no capsule to name it (an orphan, M17 §4E).
        let recorder: AVAudioRecorder
        do {
            recorder = try backend.makeRecorder(store.url(for: fileName), settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw RecorderError.couldNotStart }
        } catch {
            try? store.delete(fileName)
            backend.deactivateSession()
            throw error
        }

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
        guard state == .recording, let fileName = currentFileName else { return nil }
        // `currentTime` "is 0 when you call it on a stopped audio recorder" (Apple),
        // and the system stops the recorder of an app it suspends or interrupts. The
        // metered elapsed time is the floor, so a take the person watched run for
        // twelve seconds is never reported as nothing and deleted as too short.
        let finalDuration = max(recorder?.currentTime ?? 0, duration)
        recorder?.stop()
        finishSession()
        duration = finalDuration
        state = .finished
        return (fileName, finalDuration)
    }

    /// Stop and discard the recording + its file.
    ///
    /// This had **zero callers** from the day it was written until M17 §S0
    /// (`CaptureViewModel.discard`). Everything it does mattered and none of it
    /// happened: a capture sheet dismissed mid-take left `AVAudioRecorder` running,
    /// never reached `finishSession()` — the only place the meter timer is
    /// invalidated and the audio session deactivated — and stranded an `.m4a` that
    /// nothing in the app could ever see, because the `Capsule` row that would name
    /// it is not inserted until save.
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
        backend.deactivateSession()
    }

    // MARK: Leaving the foreground, interruptions & route changes

    private func registerForBackgrounding() {
        let token = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Synchronously — never a `Task` hop. Once this notification's observers
            // return, iOS may suspend the app at any moment and stop its recorder; a
            // hop can land after that, against a recorder that reads 0 s.
            MainActor.assumeIsolated { self?.handleEnteredBackground() }
        }
        observerTokens.append(token)
    }

    /// The app went to the background mid-take: the Home Screen, the side button, the
    /// App Switcher, a widget on another screen. There is no background recording, so
    /// the take ends here — while the recorder is still running and its file can be
    /// closed properly — and the person comes back to it waiting in review.
    private func handleEnteredBackground() {
        guard state == .recording else { return }
        finishAutomatically()
    }

    private func registerForInterruptions() {
        let token = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        observerTokens.append(token)
    }

    private func registerForRouteChanges() {
        let token = center.addObserver(
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

#if DEBUG
extension AudioRecorder {
    /// Test seam: look like a take in flight without touching AVFoundation.
    ///
    /// Starting a real recording inside a unit test measures the simulator's audio
    /// stack rather than this code — two suites are already documented as failing
    /// locally and green on CI for exactly that reason (M16 §13B). What §S0 needs to
    /// prove is that the discard path *reaches* `cancel()`, and that `cancel()`
    /// closes the session rather than merely flipping a flag. Both are properties of
    /// the state machine, and neither needs a microphone.
    ///
    /// `elapsed` stands in for what metering has shown so far. With no
    /// `AVAudioRecorder` behind the seam, `stop()` sees what it sees after the system
    /// has stopped one: no `currentTime` worth reading (1.13.1).
    func beginRecordingForTesting(fileName: String, elapsed: TimeInterval = 0) {
        currentFileName = fileName
        duration = elapsed
        state = .recording
        startMetering()
    }

    /// Whether the metering timer is still alive. `finishSession()` is the only
    /// place it is invalidated — and the only place the audio session is
    /// deactivated — so this is how a test sees that a cancelled take actually shut
    /// the session down (M17 §4E).
    var isMeteringForTesting: Bool { meterTimer?.isValid == true }
}
#endif

extension AudioRecorder: AVAudioRecorderDelegate {
    /// By the time this hop runs, a `stop()` or `cancel()` that asked for the finish
    /// has already moved `state` off `.recording`. So a take still `.recording` here
    /// was ended by the system, and it is finished like any other automatic stop.
    ///
    /// Before 1.13.1 this only closed the session and left `state` at `.recording`:
    /// the screen stayed on a frozen take, and `stop()` — which then guarded on the
    /// recorder it had just dropped — returned nothing, stranding the clip on disk.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if self.state == .recording { self.finishAutomatically() }
        }
    }
}
