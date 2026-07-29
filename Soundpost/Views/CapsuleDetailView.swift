import SwiftUI
import SwiftData
import UIKit

/// Full view of a capsule: large waveform with playback, the one line, mood,
/// place, date. Sealed-but-not-due capsules show an honest locked state.
struct CapsuleDetailView: View {
    let capsule: Capsule

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(StoreService.self) private var store
    @State private var player = AudioPlayer()
    @State private var confirmingDelete = false
    @State private var showingSeal = false
    @State private var sealedWithNotificationsOff = false
    @State private var showingPaywall = false
    @State private var sharePayload: SharePayload?
    @State private var exportFailed = false
    /// A video render in flight. Blocks a second tap and shows the button working.
    @State private var isExportingVideo = false
    /// The temp directory holding the rendered `.mp4`. Retained until the share sheet
    /// reports it is finished with the file, then cleaned (M13 §4G).
    @State private var videoWorkspace: VideoExportWorkspace?

    private var tint: Color { capsule.mood?.tint ?? .accentColor }
    private var isLocked: Bool { capsule.state == .sealed && !capsule.isContentVisible() }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if isLocked { lockedView } else { openView }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(capsule.mood?.label ?? String(localized: "Capsule"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete capsule")
            }
        }
        .confirmationDialog("Delete this capsule?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("This permanently removes the recording.")
        }
        .sheet(isPresented: $showingSeal) {
            SealSheet(onSeal: seal(until:))
        }
        .alert("Sealed — but reminders are off", isPresented: $sealedWithNotificationsOff) {
            Button("Open Settings") { openSettings() }
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("This capsule is sealed and will reappear here on its date. To be reminded on the day, turn on notifications for Soundpost in Settings.")
        }
        .sheet(item: $sharePayload) { payload in
            // Clean the video's temp dir only once the sheet is done with the file —
            // shared, saved, or cancelled. (No-op for the image share, which owns no
            // workspace.)
            ShareSheet(items: payload.items) {
                videoWorkspace?.clean()
                videoWorkspace = nil
            }
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView(context: "Export & share is a Pro feature.")
        }
        .alert("Couldn't prepare the export", isPresented: $exportFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please try again.")
        }
        .onAppear(perform: markOpenedIfResurfaced)
        .onDisappear { player.stop() }
    }

    private var openView: some View {
        VStack(spacing: 24) {
            WaveformView(
                samples: capsule.waveformSamples,
                color: tint,
                progress: player.state == .idle ? nil : player.progress
            )
            .frame(height: 150)
            .padding(.top, 12)

            Button(action: togglePlay) {
                Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            // Read the play control and clip length as one unit (§S8 a11y): the
            // visible duration is folded into the button's value so VoiceOver
            // announces "Play, 0:08" together instead of two stray elements.
            .accessibilityValue(durationString)
            .sensoryFeedback(.impact(weight: .light), trigger: player.state)

            Text(durationString)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if let note = capsule.note, !note.isEmpty {
                Text(note)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 8) {
                if let place = capsule.place?.name {
                    Label(place, systemImage: "mappin.and.ellipse")
                }
                Label(capsule.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if capsule.state == .captured {
                Button { showingSeal = true } label: {
                    Label("Seal to the future", systemImage: "lock")
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .padding(.top, 8)
            }

            // Export/share — Pro-gated, offered only here in the *visible* view
            // (the locked view has no export affordance, so a sealed-not-due
            // capsule structurally can't be exported — M11 §4G).
            exportControl
                .buttonStyle(.bordered)
                .tint(tint)
                .padding(.top, capsule.state == .captured ? 0 : 8)
        }
    }

    /// **The gate sits before the menu** (M13 §4E). A free user taps one button and
    /// meets one paywall — they never see an image/video menu, so the affordance
    /// can't tease a feature they don't have. Only a Pro user is offered the choice.
    @ViewBuilder
    private var exportControl: some View {
        if store.gate.canExport {
            Menu {
                Button(action: exportImageTapped) {
                    Label("Share as image", systemImage: "photo")
                }
                Button(action: exportVideoTapped) {
                    Label("Share as video", systemImage: "film")
                }
            } label: {
                exportLabel
            }
            .disabled(isExportingVideo)
        } else {
            Button(action: { showingPaywall = true }) { exportLabel }
        }
    }

    private var exportLabel: some View {
        Label {
            Text("Export & share")
        } icon: {
            // While a render is running the icon becomes a spinner, so the button
            // reports its own state without new copy. S4 adds determinate progress
            // and a Cancel.
            if isExportingVideo {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    /// The M11 path, unchanged: the card image plus the capsule's audio.
    private func exportImageTapped() {
        if let payload = CapsuleExporter.payload(for: capsule) {
            sharePayload = payload
        } else {
            exportFailed = true
        }
    }

    /// The M13 path: render the branded waveform video, then share it.
    private func exportVideoTapped() {
        guard !isExportingVideo else { return }
        switch VideoExportPolicy.decide(for: capsule, gate: store.gate) {
        case .needsPro:
            // Only reachable if the entitlement lapsed between this view rendering
            // and the tap. Same single paywall, no video-specific sales pitch.
            showingPaywall = true
        case .nothingToExport:
            exportFailed = true
        case .allowed:
            startVideoExport()
        }
    }

    /// Renders off the main actor and hands the finished file to the share sheet.
    /// Every failure path cleans the workspace, so no stale `.mp4` is left behind.
    private func startVideoExport() {
        let workspace: VideoExportWorkspace
        let input: VideoExportInput
        do {
            workspace = try VideoExportWorkspace.makeUnique()
            input = try VideoExporter.input(for: capsule, in: workspace)
        } catch {
            Diagnostics.notice("Video export could not start")
            exportFailed = true
            return
        }
        videoWorkspace = workspace
        isExportingVideo = true
        Task {
            do {
                let result = try await VideoExporter.export(input)
                sharePayload = SharePayload(items: [result.url])
            } catch {
                workspace.clean()
                videoWorkspace = nil
                Diagnostics.notice("Video export failed")
                exportFailed = true
            }
            isExportingVideo = false
        }
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Sealed").font(.title2.weight(.semibold))
            if let until = capsule.sealUntil {
                Text("This capsule opens \(until.formatted(.dateTime.weekday().month().day().year())).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Text("A gentle seal: Soundpost keeps it hidden until then, but this is an honor-system lock on your device — not encryption.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            // Unseal reveals the capsule early — it doesn't delete anything, so
            // it is a neutral action, not a destructive (red) one.
            Button("Unseal", action: unseal)
                .font(.subheadline)
                .padding(.top, 4)
        }
        .padding(.top, 48)
    }

    private func togglePlay() {
        switch player.state {
        case .idle: try? player.play(capsule)
        case .playing: player.pause()
        case .paused: player.resume()
        }
    }

    private func markOpenedIfResurfaced() {
        guard capsule.state == .resurfaced else { return }
        let store = CapsuleStore(context: modelContext)
        try? store.open(capsule)
        try? store.save()
    }

    private func seal(until date: Date) {
        Task {
            let granted = await notifications.requestAuthorization()
            let store = CapsuleStore(context: modelContext)
            do {
                try store.seal(capsule, until: date)
                try store.save()
            } catch {
                // Surface the rare failure instead of swallowing it (§S8) — a static,
                // non-PII message to Sentry (Release) + the local log.
                Diagnostics.notice("Seal failed at user action")
            }
            await notifications.sync(capsules: (try? store.all()) ?? [])
            if granted {
                dismiss() // back to the gallery, where the card now shows the seal
            } else {
                // The seal still happens, but be honest that no reminder will fire
                // until the user enables notifications.
                sealedWithNotificationsOff = true
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        dismiss()
    }

    private func unseal() {
        let store = CapsuleStore(context: modelContext)
        do {
            try store.unseal(capsule)
            try store.save()
        } catch {
            Diagnostics.notice("Unseal failed at user action")
        }
        Task { await notifications.sync(capsules: (try? store.all()) ?? []) }
    }

    private func delete() {
        // Cancel the far-future server job first: a deleted capsule isn't in the
        // @Query array, so the sync→reconcile path can't cancel it (§S4). Capture
        // the id before the delete; offline-first — the local delete proceeds
        // regardless, and the cancel is best-effort (idempotent, signed-in only).
        let capsuleID = capsule.id
        // Persist the cancel intent before deleting so it survives a cold launch
        // or a momentarily-unresolved key and is retried by reconcile (§S4).
        DeliveryPreferences.enqueuePendingCancel(capsuleID)
        if let file = capsule.audioFileName { try? AudioStore().delete(file) }
        modelContext.delete(capsule)
        do {
            try modelContext.save()
        } catch {
            Diagnostics.notice("Delete save failed at user action")
        }
        Task { await notifications.sealDelivery?.cancelJob(capsuleID: capsuleID) }
        dismiss()
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
