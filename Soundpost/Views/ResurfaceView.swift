import SwiftUI
import SwiftData

/// The resurface **reveal** (M12 §S4/§4C) — the emotional core of the app. A due
/// capsule opens here as a deliberate, quiet "then vs now" moment rather than a
/// plain detail screen: the elapsed time since you captured it, the one-line,
/// place and mood, and the sound itself. Calm and fully skippable — a cross-fade,
/// not melodrama, and gated on Reduce Motion. It performs the deliberate
/// `.resurfaced → .opened` flip that the detail view used to do silently.
struct ResurfaceView: View {
    let capsule: Capsule
    /// Called once when this reveal opens a genuinely-resurfaced capsule — the
    /// ethically-correct trigger for the milestone review prompt (§S5).
    var onOpened: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = AudioPlayer()
    @State private var revealed = false

    private var tint: Color { capsule.mood?.tint ?? .accentColor }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [tint.opacity(0.18), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            // Always-available dismiss — the reveal is never a gate (§4C).
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            .padding()

            ScrollView {
                content
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .padding(.top, 36)
            }
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.97)
        }
        .onAppear(perform: open)
        .onDisappear { player.stop() }
    }

    private var content: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text("A sound resurfaces")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            // Honest elapsed time from createdAt (no sealedAt field exists; §4C).
            Text("You captured this \(elapsedPhrase)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            WaveformView(
                samples: capsule.waveformSamples,
                color: tint,
                progress: player.state == .idle ? nil : player.progress
            )
            .frame(height: 120)
            .padding(.top, 4)

            if let note = capsule.note, !note.isEmpty {
                Text(note)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 6) {
                if let place = capsule.place?.name {
                    Label(place, systemImage: "mappin.and.ellipse")
                }
                if let mood = capsule.mood {
                    Label(mood.label, systemImage: mood.symbolName)
                }
                Label(
                    capsule.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            // The payoff: a big, inviting playback control. Auto-started on reveal
            // (the postcard plays itself), and fully pausable/skippable.
            Button(action: togglePlay) {
                Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            .sensoryFeedback(.impact(weight: .light), trigger: player.state)
            .padding(.top, 4)

            Button { dismiss() } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(tint)
            .padding(.top, 8)
        }
    }

    /// Localized elapsed time since capture, e.g. "8 months ago" / "8か月前".
    private var elapsedPhrase: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: capsule.createdAt, relativeTo: .now)
    }

    /// Deliberate flip (replacing the silent `markOpenedIfResurfaced`), fire the
    /// review hook once, reveal with a cross-fade unless Reduce Motion is on, then
    /// auto-offer playback.
    private func open() {
        if capsule.state == .resurfaced {
            let store = CapsuleStore(context: modelContext)
            try? store.open(capsule)
            try? store.save()
            onOpened()
        }
        if reduceMotion {
            revealed = true
        } else {
            withAnimation(.easeOut(duration: 0.8)) { revealed = true }
        }
        try? player.play(capsule)
    }

    private func togglePlay() {
        switch player.state {
        case .idle: try? player.play(capsule)
        case .playing: player.pause()
        case .paused: player.resume()
        }
    }
}
