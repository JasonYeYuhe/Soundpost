import SwiftUI
import SwiftData

/// Fixing what you wrote (M16 §S2).
///
/// The one line, the mood, the place's name and the echo — nothing else. Not the
/// date, not the audio, and no revision history: one level of in-sheet Cancel is
/// the whole undo, because a keepsake that keeps a record of its own corrections
/// is a document, not a memory.
///
/// Only ever presented for a capsule whose content is visible. A sealed-not-due
/// capsule has no Edit item at all, and `CapsuleStore.update` refuses one anyway —
/// a text field holding a note the seal is hiding would be a back door around it.
struct CapsuleEditSheet: View {
    let capsule: Capsule
    /// Called after the edit is committed, so the caller can re-sync notifications:
    /// a pending reminder may be quoting the sentence that just changed (§4C).
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var note: String
    @State private var mood: Mood?
    @State private var placeName: String
    /// False once the user has removed the place. There is no way back within the
    /// sheet other than Cancel — see `CapsuleStore.PlaceEdit` for why a place can
    /// never be re-captured at edit time.
    @State private var keepsPlace: Bool
    @State private var echoEnabled: Bool
    @State private var echoAt: Date
    @State private var saveFailed = false

    /// The user's custom mood colours (M14), read at render time exactly as the card
    /// and the capture sheet do.
    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }

    init(capsule: Capsule, onSaved: @escaping () -> Void = {}) {
        self.capsule = capsule
        self.onSaved = onSaved
        _note = State(initialValue: capsule.note ?? "")
        _mood = State(initialValue: capsule.mood)
        _placeName = State(initialValue: capsule.place?.name ?? "")
        _keepsPlace = State(initialValue: capsule.place != nil)
        // A date already past is not an echo — it can never fire, the card's bell
        // glyph and the "Coming up" strip both already ignore it, and offering it in
        // a picker whose range starts tomorrow would put the selection outside its
        // own bounds. Saving therefore also clears a dead date, which loses nothing.
        let pendingEcho = capsule.echoAt.flatMap { $0 > .now ? $0 : nil }
        _echoEnabled = State(initialValue: pendingEcho != nil)
        _echoAt = State(initialValue: pendingEcho ?? Self.defaultEchoDate())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("One line") {
                    TextField("What is this?", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("Mood") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Mood.allCases) { moodChip($0) }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Only when something was recorded. Where you were is not a field a
                // later edit can invent.
                if capsule.place != nil {
                    Section("Place") { placeControls }
                }

                // An echo belongs to a capsule that is still simply captured: sealing
                // supersedes it, and the planner only schedules one for `.captured`.
                if capsule.state == .captured {
                    Section("Echo") { echoControls }
                }
            }
            .navigationTitle("Edit capsule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .alert("Couldn't save your changes", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                // True by construction: a failed commit puts every field back before
                // it throws (§4D). Saying so is the difference between an honest
                // error and one that leaves the user unsure what they now have.
                Text("Your capsule is unchanged. Please try again.")
            }
        }
    }

    @ViewBuilder
    private var placeControls: some View {
        if keepsPlace {
            TextField("Place name", text: $placeName)
            Button("Remove", role: .destructive) { keepsPlace = false }
        } else {
            Text("No place on this capsule.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var echoControls: some View {
        if echoEnabled {
            DatePicker(
                "Echo date",
                selection: $echoAt,
                in: Self.earliestEcho()...,
                displayedComponents: [.date]
            )
            Button("Remove", role: .destructive) { echoEnabled = false }
        } else {
            Button {
                echoAt = max(echoAt, Self.defaultEchoDate())
                echoEnabled = true
            } label: {
                Label("Remind me of this later", systemImage: "bell")
            }
        }
    }

    private func moodChip(_ mood: Mood) -> some View {
        let selected = self.mood == mood
        return Button {
            self.mood = selected ? nil : mood
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

    private func save() {
        let store = CapsuleStore(context: modelContext)
        do {
            try store.update(
                capsule,
                note: note,
                mood: mood,
                place: keepsPlace ? .rename(placeName) : .remove,
                echoAt: echoEnabled ? echoAt : nil
            )
        } catch {
            // Never silent: the capsule is back as it was, and the user needs to know
            // the typo they just fixed is still there.
            Diagnostics.notice("Capsule edit failed at user action")
            saveFailed = true
            return
        }
        onSaved()
        dismiss()
    }

    /// Tomorrow, at the humane hour `SealClock` pins every reminder to.
    private static func defaultEchoDate() -> Date {
        SealClock.normalize(Date(timeIntervalSinceNow: 86_400))
    }

    private static func earliestEcho() -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    }
}
