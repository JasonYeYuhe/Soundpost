import SwiftUI
import SwiftData

/// Home screen: the card gallery, the capture entry point, and the glue that
/// keeps scheduled notifications in sync and resurfaces due capsules.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NotificationCoordinator.self) private var notifications
    @Query(sort: \Capsule.createdAt, order: .reverse) private var capsules: [Capsule]
    @State private var showingCapture = false
    @State private var path: [Capsule] = []

    var body: some View {
        NavigationStack(path: $path) {
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
        .task { await refreshAndSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAndSync() } }
        }
        .onChange(of: sealSignature) { _, _ in
            Task { await notifications.sync(capsules: capsules) }
        }
        .onChange(of: notifications.pendingDeepLinkCapsuleID) { _, id in
            handleDeepLink(id)
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
                storageFooter
            }
            .padding()
        }
    }

    private var storageFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Label("\(capsules.count)", systemImage: "waveform")
                Label(storageString, systemImage: "internaldrive")
            }
            Text("Capsules live only on this device — there's no cloud backup yet, so deleting the app erases them.")
                .multilineTextAlignment(.center)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private var storageString: String {
        let store = AudioStore()
        let bytes = capsules.reduce(Int64(0)) { sum, capsule in
            guard let file = capsule.audioFileName,
                  let size = try? FileManager.default.attributesOfItem(atPath: store.url(for: file).path)[.size] as? Int64
            else { return sum }
            return sum + size
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Changes whenever a capsule's seal state changes, so we re-sync notifications.
    private var sealSignature: String {
        capsules
            .map { "\($0.id.uuidString)|\($0.state.rawValue)|\($0.sealUntil?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: ",")
    }

    /// Flip any due seals to `.resurfaced`, then reconcile scheduled notifications.
    private func refreshAndSync() async {
        let store = CapsuleStore(context: modelContext)
        _ = try? store.refreshDueSeals()
        try? store.save()
        await notifications.sync(capsules: capsules)
    }

    private func handleDeepLink(_ id: UUID?) {
        guard let id else { return }
        let store = CapsuleStore(context: modelContext)
        _ = try? store.refreshDueSeals()
        try? store.save()
        if let capsule = capsules.first(where: { $0.id == id }) {
            path = [capsule]
        }
        notifications.pendingDeepLinkCapsuleID = nil
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Capsule.self, inMemory: true)
        .environment(NotificationCoordinator())
}
