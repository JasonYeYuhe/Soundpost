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
                    gallery
                }
            }
            .navigationTitle("Soundpost")
            .navigationDestination(for: Capsule.self) { CapsuleDetailView(capsule: $0) }
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

    private var gallery: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(capsules) { capsule in
                    NavigationLink(value: capsule) {
                        CapsuleCard(capsule: capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Capsule.self, inMemory: true)
}
