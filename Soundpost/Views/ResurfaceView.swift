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
    /// The app's single playback owner (M16 §4A) — the reveal used to build its own,
    /// which is how the gallery and this screen could sound at once.
    @Environment(PlaybackController.self) private var playback
    @State private var revealed = false
    /// One generated sentence, when Apple Intelligence is available (M15 §4G).
    /// Purely additive: `nil` is the normal case on most devices and the screen
    /// reads exactly as it always has.
    @State private var summary: String?


    /// The user's custom mood colours (M14). Observed so a change in Settings
    /// repaints immediately, exactly like `cardTheme`. Resolving never reads
    /// `isPro` — that is what keeps a chosen colour rendering after a lapse.
    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }
    private var tint: Color { palette.tint(for: capsule.mood) }
    /// This capsule's control state — the owner is shared, so "playing" has to mean
    /// "playing *this*".
    private var playbackState: PlaybackController.ControlState { playback.controlState(for: capsule) }

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
        .task { await generateSummary() }
        .onDisappear { playback.stop() }
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
                progress: playbackState == .idle ? nil : playback.player.progress
            )
            .frame(height: 120)
            .padding(.top, 4)

            // Additive only — never replaces the user's own words below.
            if let summary {
                Text(summary)
                    .font(.callout)
                    .italic()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

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
            Button { playback.toggle(capsule) } label: {
                Image(systemName: playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackState == .playing ? "Pause" : "Play")
            .sensoryFeedback(.impact(weight: .light), trigger: playbackState)
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
    /// Ask for a sentence once the screen is up. Fire-and-forget: it either arrives
    /// and fades in, or it never does and nothing about this screen changes.
    private func generateSummary() async {
        let facts = SoundSummaryWriter.Facts(
            // Showable, not merely stored: this dropped out-of-vocabulary labels but
            // honoured no confidence floor, so a gate-1 `waterfall=0.35` could still
            // reach the summary writer (M17 §4C).
            soundPhrases: Soundprint(stored: capsule.soundprintRaw)?.showablePhrases() ?? [],
            note: capsule.note,
            placeName: capsule.place?.name,
            elapsedPhrase: elapsedPhrase
        )
        summary = await SoundSummaryWriter.summary(for: facts)
    }

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
        // `play`, not `toggle`: this is an auto-start, and toggling something that
        // had just begun would pause the postcard as it opened.
        playback.play(capsule)
    }
}
