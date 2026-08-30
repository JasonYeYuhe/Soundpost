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
    /// What this person has said was wrong (M18 §4A), from the gallery's one query.
    ///
    /// The reveal cannot make a correction — there is no affordance here, and this is
    /// not a screen to start editing on — but it must honour one, including one that
    /// arrives from another device while it is open. Threading the index rather than
    /// fetching once at `.task` is what makes that live.
    let rejecting: RejectionIndex
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

    /// This device's mirror of the account-wide listening answer, and whether that
    /// answer is an answer at all — the pair `SoundAnalysisPreferences.mayReveal`
    /// composes. `@AppStorage` for the same reason the card and the detail screen use
    /// it: the reveal repaints if the switch flips underneath it, and the read is not
    /// a `UserDefaults` hit inside `body`.
    @AppStorage(SoundAnalysisPreferences.enabledKey) private var listeningEnabled = true
    @AppStorage(SoundAnalysisPreferences.hasStandingKey) private var hasStanding = false


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

            // What Soundpost heard, said as a machine's guess and not as a fact
            // (M18 §4D). Until now this screen was the one surface that named a sound
            // without attribution — the summary above described a classifier guess in
            // the app's own prose, on the most emotionally loaded moment the app has.
            // The generator is no longer told the guess at all; this deterministic
            // line is what replaces it.
            //
            // **Below the note, not directly under the summary.** §4D says "beneath
            // it", and this is beneath it — but the rule the detail screen states in
            // full applies here too: the line the person wrote is the title of their
            // own memory, and a guess about the room never goes above it (M17 §4A
            // rule 2). A sentence, not chips: the reveal is a moment, not a place to
            // start browsing from.
            if let heard = heardSentence {
                Text(heard)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// Ask for a sentence once the screen is up. Fire-and-forget: it either arrives
    /// and fades in, or it never does and nothing about this screen changes.
    private func generateSummary() async {
        // Built by `SoundSummaryWriter`, not here. This is where the sounds line was
        // assembled, out of reach of every test, which is how the reveal came to be
        // the last surface presenting a guess as a fact (M18 §4B/§4D).
        summary = await SoundSummaryWriter.summary(
            for: SoundSummaryWriter.facts(for: capsule, elapsedPhrase: elapsedPhrase))
    }

    /// The attributed line, subject to every §4A rule. `.detail` rather than `.card`:
    /// this screen has room, and the guess sits below the note rather than in its
    /// place, so a capsule with a note is not a reason to say nothing.
    private var heardSentence: String? {
        SoundprintDisplay.sentence(for: capsule, on: .detail, rejecting: rejecting,
                                   listening: listeningEnabled && hasStanding)
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
        // `play`, not `toggle`: this is an auto-start, and toggling something that
        // had just begun would pause the postcard as it opened.
        playback.play(capsule)
    }
}
