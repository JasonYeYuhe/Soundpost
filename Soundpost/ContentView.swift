import SwiftUI
import SwiftData

/// Home screen: the card gallery, the capture entry point, and the glue that
/// keeps scheduled notifications in sync and resurfaces due capsules.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(CloudSyncMonitor.self) private var syncMonitor
    @Environment(DeliveryRegistrar.self) private var registrar
    @Query(sort: \Capsule.createdAt, order: .reverse) private var capsules: [Capsule]
    @State private var showingCapture = false
    @State private var path: [Capsule] = []
    @State private var confirmingCloudDelete = false
    @State private var cloudDeleteFailed = false
    /// Mirrors `DeliveryPreferences.cloudOptedOut` so the control reacts to it.
    @AppStorage(DeliveryPreferences.optedOutKey) private var cloudOptedOut = false

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
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                storageFooter
            }
            .padding()
            .animation(.spring(duration: 0.35), value: capsules.count)
        }
    }

    private var storageFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Label("\(capsules.count)", systemImage: "waveform")
                Label(storageString, systemImage: "internaldrive")
            }
            Label {
                Text(backupMessage)
            } icon: {
                Image(systemName: backupSymbol)
            }
            .labelStyle(.titleAndIcon)
            .multilineTextAlignment(.center)

            // "Delete my cloud data" — required once delivery tokens are collected
            // (S5). Shown only when signed in (so there's cloud data) and not
            // already opted out. The local path keeps working after.
            if syncMonitor.backup == .iCloud && !cloudOptedOut {
                Button("Delete my cloud data") { confirmingCloudDelete = true }
                    .font(.caption)
                    .padding(.top, 2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        .confirmationDialog(
            "Delete my cloud data?",
            isPresented: $confirmingCloudDelete,
            titleVisibility: .visible
        ) {
            Button("Delete my cloud data", role: .destructive, action: deleteCloudData)
        } message: {
            Text("This removes the reminder schedule and device tokens Soundpost keeps on its server. Your capsules stay on this device and in iCloud. Far-future reminders fall back to this device's local schedule.")
        }
        .alert("Couldn't delete cloud data", isPresented: $cloudDeleteFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Check your connection and try again. Your cloud data hasn't been changed.")
        }
    }

    /// Purge the server-side tokens + jobs (which also sets the account-wide
    /// opt-out tombstone) and, **only on success**, opt out + clear each capsule's
    /// `serverJobSyncedAt` so the local planner re-arms its backstop, then re-sync.
    /// On failure (e.g. offline) nothing is latched and the control stays visible
    /// to retry — so we never report success while the data still exists (§S5).
    private func deleteCloudData() {
        Task {
            let purged = await notifications.sealDelivery?.deleteAllCloudData() ?? false
            await registrar.signOut()
            guard purged else {
                cloudDeleteFailed = true
                return
            }
            cloudOptedOut = true
            let store = CapsuleStore(context: modelContext)
            for capsule in (try? store.all()) ?? [] where capsule.serverJobSyncedAt != nil {
                capsule.serverJobSyncedAt = nil
            }
            try? store.save()
            await notifications.sync(capsules: (try? store.all()) ?? [])
        }
    }

    /// Honest, iCloud-state-aware durability copy (S6). Strings are literals so
    /// SwiftUI localizes them via the String Catalog (EN/JA/ZH-Hans).
    private var backupMessage: LocalizedStringKey {
        switch syncMonitor.backup {
        case .iCloud:
            "Backed up to your iCloud and synced across your devices."
        case .signedOut:
            "Only on this device — sign in to iCloud to back up your capsules."
        case .quotaFull:
            "Your iCloud storage is full, so new capsules stay on this device for now."
        case .localOnly:
            "Capsules live only on this device, so deleting the app erases them."
        }
    }

    private var backupSymbol: String {
        switch syncMonitor.backup {
        case .iCloud:    "checkmark.icloud"
        case .signedOut: "icloud.slash"
        case .quotaFull: "exclamationmark.icloud"
        case .localOnly: "internaldrive"
        }
    }

    /// Approximate on-device audio size. Estimated from clip duration at the
    /// recorder's 64 kbps bitrate (~8 KB/s) rather than reading file sizes or
    /// faulting the `audioData` blobs — the gallery must never load audio into
    /// memory (docs/M9-DEVPLAN.md risks), and post-backfill the source files are
    /// gone anyway.
    private var storageString: String {
        let bytes = capsules.reduce(Int64(0)) { $0 + Int64($1.durationSeconds * 8_000) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Changes whenever a capsule's seal or echo scheduling changes, so we
    /// re-sync notifications.
    private var sealSignature: String {
        capsules
            .map {
                "\($0.id.uuidString)|\($0.state.rawValue)|\($0.sealUntil?.timeIntervalSince1970 ?? 0)|\($0.echoAt?.timeIntervalSince1970 ?? 0)"
            }
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
        .environment(CloudSyncMonitor())
}
