import SwiftUI
import SwiftData
import UIKit

/// The capture flow: record → review (mood / note / place) → save a Capsule.
struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = CaptureViewModel()

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
                    Button("Cancel") { viewModel.discard(); dismiss() }
                }
            }
            .alert(
                viewModel.errorMessage ?? "",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
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
            Text("Up to 60 seconds. Tap to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await viewModel.startRecording() }
            } label: {
                ZStack {
                    Circle().fill(.red.opacity(0.15)).frame(width: 100, height: 100)
                    Circle().fill(.red).frame(width: 74, height: 74)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
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
                        color: viewModel.mood?.tint ?? .accentColor,
                        progress: viewModel.player.state == .idle ? nil : viewModel.player.progress
                    )
                    .frame(height: 110)
                    HStack {
                        Button { viewModel.togglePlayback() } label: {
                            Image(systemName: viewModel.player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 42))
                        }
                        .accessibilityLabel(viewModel.player.state == .playing ? "Pause" : "Play")
                        Spacer()
                        Text(timeString(viewModel.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                section("Mood") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Mood.allCases) { moodChip($0) }
                        }
                        .padding(.vertical, 2)
                    }
                }

                section("One line") {
                    TextField("What is this?", text: $viewModel.note, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                }

                section("Place") { placeControl }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { save() } label: { Text("Save capsule").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button(role: .destructive) { viewModel.discard() } label: { Text("Discard & re-record") }
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
            .background(selected ? mood.tint.opacity(0.22) : Color(.secondarySystemBackground), in: SwiftUI.Capsule())
            .overlay(SwiftUI.Capsule().stroke(selected ? mood.tint : .clear, lineWidth: 1.5))
            .foregroundStyle(selected ? mood.tint : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private func save() {
        let store = CapsuleStore(context: modelContext)
        try? store.save() // ensure context is in a clean state
        do {
            try viewModel.save(using: store)
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
}
