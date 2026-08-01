import SwiftUI

/// The two Pro micro-levers (M14): what each mood looks like, and how soon a
/// surprise echo comes back.
///
/// **Reachable by everyone on purpose.** Choosing is Pro, but *undoing* never is:
/// a lapsed user must always be able to reset a colour they can no longer change,
/// or they would be stranded with a palette they cannot undo (M14 §4F, the same
/// reason `.classic` is always an available theme). So the controls are disabled
/// without Pro while every reset stays live.
///
/// The footer states the lapse rules plainly rather than leaving them to be
/// discovered — the two levers genuinely behave differently, and pretending
/// otherwise would be the dark pattern.
struct PersonalisationSettingsView: View {
    @Environment(StoreService.self) private var store

    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    @AppStorage(EchoPreferences.lowerKey) private var storedLower = ProGate.defaultEchoWindow.lowerBound
    @AppStorage(EchoPreferences.upperKey) private var storedUpper = ProGate.defaultEchoWindow.upperBound

    @State private var showingPaywall = false

    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }
    private var canEdit: Bool { store.gate.canCustomiseMoodColours }

    var body: some View {
        Form {
            if !canEdit { unlockSection }
            colourSection
            echoSection
        }
        .navigationTitle("Make it yours")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView(context: "Choosing colours and your echo window is a Pro feature.")
        }
    }

    // MARK: - Unlock

    private var unlockSection: some View {
        Section {
            Button { showingPaywall = true } label: {
                Label("Soundpost Pro", systemImage: "waveform.badge.plus")
            }
        } footer: {
            Text("Colours you have already chosen keep showing — a lapse never changes how your capsules look. Only picking new ones needs Pro.")
        }
    }

    // MARK: - Mood colours

    private var colourSection: some View {
        Section {
            ForEach(Mood.allCases) { mood in
                HStack(spacing: 12) {
                    Image(systemName: mood.symbolName)
                        .foregroundStyle(palette.tint(for: mood))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    if canEdit {
                        ColorPicker(mood.label, selection: colourBinding(for: mood), supportsOpacity: false)
                    } else {
                        Text(mood.label)
                        Spacer()
                        Circle()
                            .fill(palette.tint(for: mood))
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                    // Undoing is never gated (§4F).
                    if palette.hasOverride(for: mood) {
                        Button {
                            var updated = palette
                            updated.reset(mood)
                            moodPaletteRaw = updated.stored
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Use the default colour for \(mood.label)"))
                    }
                }
            }
            if !palette.isEmpty {
                Button("Use the default colours", role: .destructive) {
                    moodPaletteRaw = ""
                }
            }
        } header: {
            Text("Mood colours")
        } footer: {
            Text("A colour applies to every capsule of that mood, old ones included — it is a palette, not a per-capsule setting. Soundpost keeps your choice readable on cards and in videos.")
        }
    }

    // MARK: - Echo window

    private var echoSection: some View {
        Section {
            Stepper(value: lowerBinding, in: ProGate.echoWindowBounds) {
                LabeledContent("Earliest") { Text("\(storedLower) days") }
            }
            .disabled(!canEdit)
            Stepper(value: upperBinding, in: ProGate.echoWindowBounds) {
                LabeledContent("Latest") { Text("\(storedUpper) days") }
            }
            .disabled(!canEdit)
            if EchoPreferences.storedWindow != nil {
                Button("Use the default window") {
                    setWindow(lower: ProGate.defaultEchoWindow.lowerBound,
                              upper: ProGate.defaultEchoWindow.upperBound)
                }
            }
        } header: {
            Text("Echo window")
        } footer: {
            Text("A new recording draws its surprise echo somewhere in this range. Unlike your colours, this only seeds new recordings — without Pro they go back to 7–30 days, and echoes already set keep their dates.")
        }
    }

    // MARK: - Bindings

    private func colourBinding(for mood: Mood) -> Binding<Color> {
        Binding(
            get: { palette.tint(for: mood) },
            set: { picked in
                var updated = palette
                updated.set(MoodColor(picked), for: mood)
                moodPaletteRaw = updated.stored
            }
        )
    }

    /// Both bounds are written together on every change: `EchoPreferences` treats a
    /// half-written pair as "never chosen", so writing only one key would silently
    /// drop the user's whole window back to the default.
    private var lowerBinding: Binding<Int> {
        Binding(get: { storedLower }, set: { setWindow(lower: $0, upper: max($0, storedUpper)) })
    }

    private var upperBinding: Binding<Int> {
        Binding(get: { storedUpper }, set: { setWindow(lower: min(storedLower, $0), upper: $0) })
    }

    private func setWindow(lower: Int, upper: Int) {
        let clamped = ProGate.clampEchoWindow(lower...max(lower, upper))
        storedLower = clamped.lowerBound
        storedUpper = clamped.upperBound
    }
}
