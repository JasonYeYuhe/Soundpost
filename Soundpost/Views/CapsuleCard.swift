import SwiftUI
import UIKit

/// A capsule as a tappable, glanceable keepsake: a mood-tinted waveform with its
/// one line, place, and date. Sealed capsules render locked (honest copy) until
/// their date. This is the app's signature object (docs/PROJECT.md differentiation).
///
/// **Two tap targets, deliberately not nested** (M16 §4E). The card used to be
/// wrapped in a whole-card `Button` by the gallery, and putting a play control
/// inside that would have given SwiftUI two overlapping buttons and — because the
/// card merges its accessibility children into one element — hidden the control
/// from VoiceOver entirely. So the card owns its own surface tap, and the play
/// control is a sibling: its own hit region, its own accessibility element.
struct CapsuleCard: View {
    let capsule: Capsule
    /// Opening the capsule. Passed in rather than wrapping this view in a `Button`
    /// — see the type doc.
    var onOpen: () -> Void = {}

    /// The app's single playback owner (M16 §4A). Read here rather than held, so
    /// every card in the gallery drives the one player.
    @Environment(PlaybackController.self) private var playback

    /// The global card theme (M11 §2B(c)). A single app-wide preference, read at
    /// render time — never `isPro` — so an applied theme keeps rendering after a
    /// Pro lapse (§4D). `.classic` is the free base and the default, so free /
    /// lapsed users (and the pre-Pro app) see the card unchanged.
    @AppStorage("cardTheme") private var theme: Theme = .classic

    /// The user's custom mood colours (M14). Observed so a change in Settings
    /// repaints immediately, exactly like `cardTheme`. Resolving never reads
    /// `isPro` — that is what keeps a chosen colour rendering after a lapse.
    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }

    /// This device's mirror of the account-wide listening answer. `@AppStorage` rather
    /// than a `SoundAnalysisPreferences.isEnabled` read, for the same reason the
    /// palette is: it repaints the whole gallery the moment the switch flips, and it
    /// is not a `UserDefaults` hit per card per body pass on a path the 20 Hz player
    /// already drives (M16 §7).
    @AppStorage(SoundAnalysisPreferences.enabledKey) private var listeningEnabled = true

    private var tint: Color { palette.tint(for: capsule.mood) }
    private var isLocked: Bool { capsule.state == .sealed && !capsule.isContentVisible() }
    /// No control at all on a sealed-not-due capsule, or on one with no clip.
    private var showsPlayControl: Bool { capsule.offersPlayback() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isLocked { lockedBody } else { openBody }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Everything readable becomes ONE element carrying the card's own action.
        // Applied here, *below* the play control's overlay, which is what keeps the
        // control a separate element instead of being merged away by `.combine`.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(theme.baseFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(tint.opacity(theme.tintWashOpacity))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(theme.strokeColor(tint: tint), lineWidth: theme.strokeWidth)
        )
        .overlay(alignment: .bottomTrailing) { playControl }
        // The whole card surface opens it. A tap that lands on the play control is
        // handled there first — SwiftUI resolves the innermost gesture — so the two
        // never compete for the same touch.
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture(perform: onOpen)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: capsule.mood?.symbolName ?? "waveform")
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(capsule.mood?.label ?? String(localized: "Sound"))
                    .font(.subheadline.weight(.semibold))
                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusGlyph
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch capsule.state {
        case .sealed:
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                .accessibilityLabel("Sealed")
        case .resurfaced:
            Image(systemName: "sparkles").foregroundStyle(tint)
                .accessibilityLabel("Resurfaced")
        case .captured where capsule.echoAt.map({ $0 > .now }) == true:
            // A pending echo: this capsule will ring back on its surprise day.
            Image(systemName: "bell.badge").foregroundStyle(tint)
                .accessibilityLabel("Echo scheduled")
        default: EmptyView()
        }
    }

    private var openBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            WaveformView(samples: capsule.waveformSamples, color: tint, isDecorative: true)
                .frame(height: 56)
            if let note = capsule.note, !note.isEmpty {
                Text(note).font(.body).lineLimit(2)
            } else if let heard = SoundprintDisplay.sentence(for: heardPhrases) {
                // The machine's guess FILLS A SILENCE — it never competes with the
                // user's own line, which is why this is the `else` branch and not a
                // row of its own (M17 §4A rule 2, `NotificationCopy.Digest.lead`'s
                // precedence applied to a second surface).
                //
                // Attributed in the copy, at caption weight and secondary colour, so
                // it can never be mistaken for something the person wrote here. A bare
                // "rain" in this position would read as their own caption — the exact
                // failure rule 1 names.
                Text(heard)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                // `play.circle` here was decoration — a glyph that looked like a
                // control and did nothing (M16 §S0). The duration keeps its place;
                // the real control is the sibling in the corner.
                Label(durationString, systemImage: "waveform")
                if let place = capsule.place?.name {
                    Label(place, systemImage: "mappin").lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Keep a long place name out from under the play control.
            .padding(.trailing, showsPlayControl ? 40 : 0)
        }
    }

    /// The real play/pause control: a sibling of the card's readable content, with
    /// its own hit region (44 pt) and its own accessibility element.
    ///
    /// It shows *state*, not *progress*. Progress ticks at 20 Hz
    /// (`AudioPlayer.swift`), and a card that read it would re-render twenty times a
    /// second while the gallery around it re-walked the library (M16 §7). The detail
    /// view is where progress belongs — one screen, one capsule.
    @ViewBuilder
    private var playControl: some View {
        if showsPlayControl {
            let state = playback.controlState(for: capsule)
            Button { playback.toggle(capsule) } label: {
                Image(systemName: state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel(state == .playing ? "Pause" : "Play")
            .accessibilityValue(durationString)
            .sensoryFeedback(.impact(weight: .light), trigger: state)
        }
    }

    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A flattened, dimmed hint of the waveform — present but not revealed.
            WaveformView(samples: capsule.waveformSamples.map { min($0, 0.25) }, color: .secondary, isDecorative: true)
                .frame(height: 28)
                .opacity(0.5)
            if let until = capsule.sealUntil {
                Text("Opens \(until.formatted(.dateTime.month().day().year()))")
                    .font(.subheadline.weight(.medium))
            }
            Text("A gentle seal — held until then.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// What Soundpost heard, subject to every §4A rule at once — including the one
    /// this surface adds, that a capsule with a note shows nothing here. Decided in
    /// `SoundprintDisplay` so the card and the detail screen cannot drift apart.
    private var heardPhrases: [String] {
        SoundprintDisplay.phrases(for: capsule, on: .card, listening: listeningEnabled)
    }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(capsule.createdAt) {
            return capsule.createdAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(capsule.createdAt) { return String(localized: "Yesterday") }
        return capsule.createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
