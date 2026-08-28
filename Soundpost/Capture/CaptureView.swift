import SwiftUI
import SwiftData
import UIKit

/// The capture flow: record → review (mood / note / place) → save a Capsule.
struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(StoreService.self) private var store
    /// Read for one sentence: whether the echo this screen is offering is a reminder
    /// the app is still allowed to deliver (M17 §S4).
    @Environment(NotificationCoordinator.self) private var notifications
    @State private var viewModel = CaptureViewModel()
    @State private var showingEchoPicker = false
    /// A stable fallback for the echo-picker binding, seeded once at view init so
    /// the picker selection never re-rolls across body evaluations (§S2). The
    /// picker is only ever presented with `echoAt` already seeded, so this is a
    /// belt-and-suspenders default that keeps the binding getter pure.
    @State private var echoPickerSeed = CaptureViewModel.randomEchoDate()

    /// The user's custom mood colours (M14). Observed so a change in Settings
    /// repaints immediately, exactly like `cardTheme`. Resolving never reads
    /// `isPro` — that is what keeps a chosen colour rendering after a lapse.
    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }
    @State private var showingPaywall = false
    @State private var recordPulse = false
    @State private var saveCount = 0

    /// What a confirmed discard should do afterwards. The take is destroyed either
    /// way; the difference is only where the user lands (M17 §S0).
    private enum DiscardIntent: Identifiable {
        /// Cancel — throw the take away and leave the sheet.
        case close
        /// Discard & re-record — throw it away and stay, ready to start again.
        case reRecord
        var id: Self { self }
    }
    @State private var confirmingDiscard: DiscardIntent?

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .idle: idleView
                case .recording: recordingView
                case .review: reviewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("New capsule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Nothing recorded yet is nothing to lose — closing an idle
                        // sheet must not ask a question with no stakes.
                        if viewModel.hasUnsavedTake {
                            confirmingDiscard = .close
                        } else {
                            viewModel.discard()
                            dismiss()
                        }
                    }
                }
            }
            // A swipe cannot be confirmed, so while there is a take to lose the
            // gesture is not offered at all and Cancel is the only way out (M17
            // §4E). There is no UI-test target in this project, so this line is
            // verified by hand in the simulator and nowhere else — see §13.
            .interactiveDismissDisabled(viewModel.hasUnsavedTake)
            .alert(
                viewModel.errorMessage ?? "",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog(
                "Discard this recording?",
                isPresented: Binding(
                    get: { confirmingDiscard != nil },
                    set: { if !$0 { confirmingDiscard = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirmingDiscard
            ) { intent in
                Button("Discard", role: .destructive) { performDiscard(intent) }
                Button("Keep it", role: .cancel) { confirmingDiscard = nil }
            } message: { _ in
                Text("It hasn't been saved yet, and this can't be undone.")
            }
            .sheet(isPresented: $showingEchoPicker) { echoPicker }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView(context: "Recording up to 5 minutes is a Pro feature.")
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.phase)
            .sensoryFeedback(.success, trigger: saveCount)
        }
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("Capture how this moment sounds")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            // Honest, gate-aware hint reflecting the *current* cap (M11 §4D/S3).
            Text(captureHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // No "record past 60s" gesture exists (the recorder hard-stops), so
            // the longer-clip upsell is an explicit affordance, never a nag.
            if !store.gate.isPro {
                Button { showingPaywall = true } label: {
                    Label("Record up to 5 minutes with Pro", systemImage: "timer")
                        .font(.footnote)
                }
                .padding(.top, 2)
            }
            Spacer()
            Button {
                Task {
                    // Both caps are read HERE, at capture-start (M11 §4D / M14 §4D):
                    // the clip length and the echo window this recording will use.
                    // A later lapse can never reach back and change either.
                    viewModel.echoWindow = EchoPreferences.effectiveWindow(gate: store.gate)
                    await viewModel.startRecording(maxDuration: store.gate.maxRecordingDuration)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.15))
                        .frame(width: 100, height: 100)
                        .scaleEffect(recordPulse ? 1.12 : 1.0)
                    Circle().fill(.red).frame(width: 74, height: 74)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    recordPulse = true
                }
            }
            if viewModel.permissionDenied { permissionHint }
            Spacer()
            Text("Recording may pick up nearby voices — please be considerate of others.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var permissionHint: some View {
        VStack(spacing: 4) {
            Text("Microphone access is off.").font(.footnote)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    // MARK: Recording

    private var recordingView: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(timeString(viewModel.recorder.duration))
                .font(.system(size: 46, weight: .light, design: .rounded))
                .monospacedDigit()
            WaveformView(samples: viewModel.recorder.levels, color: .red, isDecorative: true)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
            Text("Recording…").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button { viewModel.stopRecording() } label: {
                ZStack {
                    Circle().strokeBorder(.red.opacity(0.3), lineWidth: 4).frame(width: 100, height: 100)
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 34, height: 34)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            Spacer()
        }
        .padding()
    }

    // MARK: Review

    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    WaveformView(
                        samples: viewModel.waveform,
                        color: palette.tint(for: viewModel.mood),
                        progress: viewModel.player.state == .idle ? nil : viewModel.player.progress
                    )
                    .frame(height: 110)
                    HStack {
                        Button { viewModel.togglePlayback() } label: {
                            Image(systemName: viewModel.player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 42))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .accessibilityLabel(viewModel.player.state == .playing ? "Pause" : "Play")
                        Spacer()
                        Text(timeString(viewModel.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                // Shown only when a free clip actually bumped the 60s cap — a
                // gentle, in-context upsell, not an interruption.
                if reachedFreeCap {
                    Button { showingPaywall = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                            Text("Reached the 60-second limit. Record up to 5 minutes with Pro.")
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .font(.footnote)
                        .padding(12)
                        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                section("Mood") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Mood.allCases) { moodChip($0) }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // What the on-device classifier heard (M15 §4E). A SUGGESTION: it
                // appears only when there is something confident to say, it is never
                // applied on its own, and ignoring it forever costs nothing.
                //
                // The header and the chips are driven by the SAME array, which is the
                // point rather than a tidy-up: this used to ask `!soundprint.isEmpty`
                // — a count of *stored* labels — and then render each one only `if let
                // phrase = displayName(for:)`. A value holding nothing showable drew
                // the "Sounds like" header over zero chips (M17 §4C). A header that
                // cannot exist without its content cannot be a ghost.
                let heard = viewModel.suggestedPhrases
                if !heard.isEmpty {
                    section("Sounds like") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(heard, id: \.self) { soundSuggestionChip($0) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .transition(.opacity)
                }

                section("One line") {
                    TextField("What is this?", text: $viewModel.note, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                }

                section("Place") { placeControl }

                section("Echo") { echoControl }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { save() } label: { Text("Save capsule").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button(role: .destructive) { confirmingDiscard = .reRecord } label: { Text("Discard & re-record") }
                    .font(.subheadline)
            }
            .padding()
            .background(.bar)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    /// A tappable guess. Tapping *adds it to the user's line* — it never becomes the
    /// line by itself, and it never touches the mood: what the room sounded like is an
    /// observation, what the moment felt like is the user's alone (M15 §4E).
    private func soundSuggestionChip(_ phrase: String) -> some View {
        Button {
            acceptSuggestion(phrase)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                Text(phrase)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: SwiftUI.Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add \(phrase) to your line"))
    }

    /// Whether joining these two runs needs a space.
    ///
    /// Only when the character either side of the join belongs to a script that
    /// writes with spaces. Two CJK runs join directly; "朝の音" + "雨" is "朝の音雨",
    /// not "朝の音 雨".
    static func needsSpaceBetween(_ left: String, _ right: String) -> Bool {
        guard let last = left.unicodeScalars.last,
              let first = right.unicodeScalars.first else { return false }
        return !isCJK(last) || !isCJK(first)
    }

    /// The wider set, including CJK punctuation: "朝の音、" ends in a character that is
    /// not an ideograph but certainly does not want an ASCII space after it.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        ScriptHeuristics.isCJKOrCJKPunctuation(scalar)
    }

    /// Append rather than replace: a guess must never eat something the user wrote.
    private func acceptSuggestion(_ phrase: String) {
        let existing = viewModel.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            // Sentence-start capitalisation in languages that have it; a no-op in ja/zh.
            viewModel.note = phrase.prefix(1).localizedUppercase + phrase.dropFirst()
        } else {
            // No space between two CJK runs. Japanese and Chinese do not separate
            // words, so an ASCII space here reads as a typo in two of the three
            // languages this feature ships in — on the exact path the release notes
            // advertise. The join is spaced only when either side is a script that
            // uses spaces.
            let separator = Self.needsSpaceBetween(existing, phrase) ? " " : ""
            viewModel.note = existing + separator + phrase
        }
    }

    private func moodChip(_ mood: Mood) -> some View {
        let selected = viewModel.mood == mood
        return Button {
            viewModel.mood = selected ? nil : mood
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mood.symbolName)
                Text(mood.label)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? palette.tint(for: mood).opacity(0.22) : Color(.secondarySystemBackground), in: SwiftUI.Capsule())
            .overlay(SwiftUI.Capsule().stroke(selected ? palette.tint(for: mood) : .clear, lineWidth: 1.5))
            .foregroundStyle(selected ? palette.tint(for: mood) : .primary)
            .scaleEffect(selected && !reduceMotion ? 1.06 : 1.0)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }

    /// The surprise "echo" reminder row: shows the randomly drawn date, lets the
    /// user change it or turn it off. Honest copy — it's a reminder, not a seal.
    @ViewBuilder
    private var echoControl: some View {
        if viewModel.echoEnabled, let echoAt = viewModel.echoAt {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { viewModel.seedEchoIfNeeded(); showingEchoPicker = true } label: {
                        Label(
                            "Echoes back \(echoAt.formatted(date: .abbreviated, time: .omitted)) · in \(echoDays(until: echoAt)) days",
                            systemImage: "bell.badge"
                        )
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { viewModel.echoEnabled = false }
                        .font(.subheadline)
                }
                Text(echoPromise)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                viewModel.seedEchoIfNeeded()
                viewModel.echoEnabled = true
            } label: {
                Label("Remind me of this later", systemImage: "bell")
            }
        }
    }

    /// A `LocalizedStringKey` property rather than a ternary inside `Text(...)`, and
    /// not only for readability: the localization gate reads source, and it finds
    /// literals in a localizing *call* or in a declaration typed `LocalizedStringKey`.
    /// A ternary's branches inside `Text(…)` are in neither position, so a new string
    /// written that way would ship untranslated with the gate green — the same
    /// blindness M17 §S2 closed for interpolated literals, in a different disguise.
    private var echoPromise: LocalizedStringKey {
        // `remindersWouldBeDelivered`, not `canPromiseAReminder`: this screen never
        // requests authorization, so `.notDetermined` here is not a question about to
        // be asked — see the property's own doc.
        notifications.remindersWouldBeDelivered
            ? "A surprise reminder of what today sounded like."
            : "Notifications are off, so this won't reach you until you turn them on."
    }

    private var echoPicker: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Echo date",
                    selection: Binding(
                        get: { viewModel.echoAt ?? echoPickerSeed },
                        set: { viewModel.echoAt = SealClock.normalize($0) }
                    ),
                    in: Calendar.current.date(byAdding: .day, value: 1, to: .now)!...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingEchoPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func echoDays(until date: Date) -> Int {
        max(1, Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 1)
    }

    @ViewBuilder
    private var placeControl: some View {
        if let place = viewModel.place, viewModel.includePlace {
            HStack {
                Label(place.name ?? String(localized: "Current location"), systemImage: "mappin.and.ellipse")
                Spacer()
                Button("Remove", role: .destructive) { viewModel.clearPlace() }.font(.subheadline)
            }
        } else {
            Button {
                Task { await viewModel.fetchPlace() }
            } label: {
                if viewModel.isFetchingPlace {
                    HStack(spacing: 8) { ProgressView(); Text("Finding location…") }
                } else {
                    Label("Tag where I am", systemImage: "mappin")
                }
            }
            .disabled(viewModel.isFetchingPlace)
        }
    }

    // MARK: Actions

    /// Throw the take away, then go where the intent says. The destruction is
    /// `viewModel.discard()`'s either way — this only decides whether the sheet
    /// closes behind it.
    private func performDiscard(_ intent: DiscardIntent) {
        viewModel.discard()
        confirmingDiscard = nil
        if intent == .close { dismiss() }
    }

    private func save() {
        let store = CapsuleStore(context: modelContext)
        try? store.save() // ensure context is in a clean state
        do {
            try viewModel.save(using: store)
            saveCount += 1 // success haptic
            dismiss()
        } catch {
            // Persisting failed; keep the sheet open so the recording isn't lost,
            // and tell the user instead of failing silently.
            viewModel.errorMessage = String(localized: "Couldn't save the capsule. Please try again.")
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The honest capture hint, reflecting the current entitlement's cap.
    private var captureHint: LocalizedStringKey {
        store.gate.isPro ? "Up to 5 minutes. Tap to start." : "Up to 60 seconds. Tap to start."
    }

    /// True when a free recording hit its cap (≈60s) — the only moment the
    /// review-screen longer-clip upsell appears.
    private var reachedFreeCap: Bool {
        !store.gate.isPro && viewModel.duration >= viewModel.recorder.maxDuration - 0.5
    }
}
