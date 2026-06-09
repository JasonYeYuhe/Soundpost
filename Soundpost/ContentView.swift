import SwiftUI
import SwiftData

/// Home screen: the list of capsules (M4 turns each row into a waveform card)
/// plus the entry point to the capture flow.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Capsule.createdAt, order: .reverse) private var capsules: [Capsule]
    @State private var showingCapture = false

    var body: some View {
        NavigationStack {
            Group {
                if capsules.isEmpty {
                    emptyState
                } else {
                    capsuleList
                }
            }
            .navigationTitle("Soundpost")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCapture = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("New capsule")
                }
            }
            .sheet(isPresented: $showingCapture) { CaptureView() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No capsules yet", systemImage: "waveform")
        } description: {
            Text("Capture ten seconds of how your life sounds right now.")
        } actions: {
            Button { showingCapture = true } label: { Text("Record a sound") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var capsuleList: some View {
        List {
            ForEach(capsules) { CapsuleRow(capsule: $0) }
                .onDelete(perform: delete)
        }
        .listStyle(.plain)
    }

    private func delete(_ offsets: IndexSet) {
        let audioStore = AudioStore()
        for index in offsets {
            let capsule = capsules[index]
            if let file = capsule.audioFileName { try? audioStore.delete(file) }
            modelContext.delete(capsule)
        }
        try? modelContext.save()
    }
}

/// Compact list row for M3 — a richer waveform card lands in M4.
private struct CapsuleRow: View {
    let capsule: Capsule

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: capsule.mood?.symbolName ?? "waveform")
                .foregroundStyle(capsule.mood?.tint ?? .accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(capsule.createdAt, format: .dateTime.month().day().hour().minute())
                    if let name = capsule.place?.name {
                        Label(name, systemImage: "mappin").labelStyle(.titleAndIcon).lineLimit(1)
                    }
                    Text(durationString)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !capsule.waveformSamples.isEmpty {
                WaveformView(samples: capsule.waveformSamples, color: capsule.mood?.tint ?? .accentColor)
                    .frame(width: 70, height: 28)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if let note = capsule.note, !note.isEmpty { return note }
        return "Untitled capsule"
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Capsule.self, inMemory: true)
}
