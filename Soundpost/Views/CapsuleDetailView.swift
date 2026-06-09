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
    @State private var player = AudioPlayer()
    @State private var confirmingDelete = false
    @State private var showingSeal = false
    @State private var sealedWithNotificationsOff = false

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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")

            Text(durationString)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)

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
        guard let file = capsule.audioFileName else { return }
        switch player.state {
        case .idle: try? player.play(fileName: file)
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
            try? store.seal(capsule, until: date)
            try? store.save()
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
        try? store.unseal(capsule)
        try? store.save()
        Task { await notifications.sync(capsules: (try? store.all()) ?? []) }
    }

    private func delete() {
        if let file = capsule.audioFileName { try? AudioStore().delete(file) }
        modelContext.delete(capsule)
        try? modelContext.save()
        dismiss()
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
