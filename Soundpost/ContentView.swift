import SwiftUI
import SwiftData

/// Home screen: the card gallery, the capture entry point, and the glue that
/// keeps scheduled notifications in sync and resurfaces due capsules.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(CloudSyncMonitor.self) private var syncMonitor
    @Environment(DeliveryRegistrar.self) private var registrar
    @Query(sort: \Capsule.createdAt, order: .reverse) private var capsules: [Capsule]
    @State private var showingCapture = false
    @State private var showingPro = false
    @State private var path: [Capsule] = []
    /// The capsule currently presented as a full-screen resurface reveal (§S4).
    @State private var revealCapsule: Capsule?
    /// Set when the current reveal opened a genuine resurface, so the milestone
    /// review prompt fires *after* the reveal is dismissed — never during the
    /// moment, never on launch/capture (§S5).
    @State private var reviewAfterReveal = false
    @State private var confirmingCloudDelete = false
    @State private var cloudDeleteFailed = false
    // Calm gallery browsability (§S6): search + a collapsible mood/sealed filter.
    @State private var searchText = ""
    @State private var filterMoods: Set<Mood> = []
    @State private var sealedOnly = false
    @State private var showingFilters = false
    /// Mirrors `DeliveryPreferences.cloudOptedOut` so the control reacts to it.
    @AppStorage(DeliveryPreferences.optedOutKey) private var cloudOptedOut = false
    /// Mirrors the lock-screen-preview preference (toggled in Settings, §S3/§S7).
    /// Changing it must force a full notification reconcile so already-scheduled
    /// requests don't keep a stale personalized/generic body (§S3 P0).
    @AppStorage(NotificationPreferences.personalizedKey) private var personalizedNotifications = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if capsules.isEmpty {
                    emptyState
                } else {
                    gallery
                }
            }
            .searchable(text: $searchText, prompt: Text("Search your sounds"))
            .navigationTitle("Soundpost")
            .navigationDestination(for: Capsule.self) { CapsuleDetailView(capsule: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The minimal Pro entry point (M11 §4F): status, paywall,
                    // restore, manage subscription, Terms/Privacy. Full Settings
                    // is M12. Sits beside the primary "New capsule" action.
                    Button { showingPro = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Soundpost Pro")

                    Button { showingCapture = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("New capsule")
                }
            }
            .sheet(isPresented: $showingCapture) { CaptureView() }
            .sheet(isPresented: $showingPro) { ProPaywallView() }
            .fullScreenCover(item: $revealCapsule, onDismiss: requestReviewIfEarned) { capsule in
                ResurfaceView(capsule: capsule) { reviewAfterReveal = true }
            }
        }
        .task { await refreshAndSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAndSync() } }
        }
        .onChange(of: sealSignature) { _, _ in
            Task { await notifications.sync(capsules: capsules) }
        }
        .onChange(of: personalizedNotifications) { _, _ in
            // Re-issue owned requests with fresh copy when the preference flips,
            // so no stale personalized/generic body lingers on the lock screen.
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

    /// Filtered + searched capsules (metadata-only, visibility-aware — §S6).
    private var displayed: [Capsule] {
        GalleryFilter.apply(
            capsules,
            GalleryFilter.Criteria(searchText: searchText, moods: filterMoods, sealedOnly: sealedOnly)
        )
    }

    private var gallery: some View {
        ScrollView {
            LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                filterBar
                if displayed.isEmpty {
                    noMatches
                } else {
                    ForEach(GallerySection.grouped(displayed), id: \.section.id) { group in
                        Section {
                            ForEach(group.capsules) { capsule in
                                Button { openCapsule(capsule) } label: {
                                    CapsuleCard(capsule: capsule)
                                }
                                .buttonStyle(.plain)
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                            }
                        } header: {
                            sectionHeader(group.section.title)
                        }
                    }
                }
                storageFooter
            }
            .padding()
            .animation(.spring(duration: 0.35), value: displayed.count)
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(.background.opacity(0.95))
    }

    private var noMatches: some View {
        ContentUnavailableView.search(text: searchText)
            .padding(.top, 40)
    }

    /// A collapsed-by-default filter: mood chips + a "Sealed only" toggle. Calm,
    /// secondary chrome — no counters, no engagement loops (§4D).
    @ViewBuilder
    private var filterBar: some View {
        let criteria = GalleryFilter.Criteria(searchText: searchText, moods: filterMoods, sealedOnly: sealedOnly)
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showingFilters.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("Filter")
                    Spacer()
                    Image(systemName: showingFilters ? "chevron.up" : "chevron.down").font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(criteria.isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            if showingFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Mood.allCases) { moodFilterChip($0) }
                    }
                    .padding(.vertical, 2)
                }
                Toggle("Sealed only", isOn: $sealedOnly)
                    .font(.subheadline)
                    .tint(.accentColor)
                if criteria.isActive {
                    Button("Clear filters") {
                        withAnimation { filterMoods = []; sealedOnly = false; searchText = "" }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func moodFilterChip(_ mood: Mood) -> some View {
        let selected = filterMoods.contains(mood)
        return Button {
            if selected { filterMoods.remove(mood) } else { filterMoods.insert(mood) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mood.symbolName)
                Text(mood.label)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? mood.tint.opacity(0.22) : Color(.secondarySystemBackground), in: SwiftUI.Capsule())
            .overlay(SwiftUI.Capsule().stroke(selected ? mood.tint : .clear, lineWidth: 1.5))
            .foregroundStyle(selected ? mood.tint : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// Normalize any pre-§S2 antisocial-hour seals/echoes to 09:00 local, flip any
    /// due seals to `.resurfaced`, then reconcile scheduled notifications. The
    /// normalization is idempotent (no-op once everything is at 09:00) and clears
    /// `serverJobSyncedAt` for any seal it shifts, so the M10 reconcile in `sync`
    /// re-upserts the corrected wall clock (§S2 P0).
    private func refreshAndSync() async {
        let store = CapsuleStore(context: modelContext)
        _ = try? store.normalizeSealHours()
        _ = try? store.refreshDueSeals()
        try? store.save()
        await notifications.sync(capsules: capsules)
    }

    /// The single "open capsule" action every card tap and deep link routes
    /// through (§S4/§4C): refresh due seals first (so a `.sealed`-past-date capsule
    /// flips to `.resurfaced`), then present the **reveal** for a due/resurfaced
    /// capsule or navigate to detail otherwise. One decision point, so a due seal
    /// never opens as a plain detail screen.
    private func openCapsule(_ capsule: Capsule) {
        let store = CapsuleStore(context: modelContext)
        _ = try? store.refreshDueSeals()
        try? store.save()
        switch CapsuleOpenRoute.route(for: capsule) {
        case .reveal: revealCapsule = capsule
        case .detail: path = [capsule]
        }
    }

    /// After the reveal closes, ask for a rating if this was a genuine resurface
    /// and the per-version cap allows it (§S5). The OS further rate-limits.
    private func requestReviewIfEarned() {
        guard reviewAfterReveal else { return }
        reviewAfterReveal = false
        ReviewPrompt.requestIfEligible(requestReview)
    }

    private func handleDeepLink(_ id: UUID?) {
        guard let id else { return }
        if let capsule = capsules.first(where: { $0.id == id }) {
            openCapsule(capsule)
        }
        notifications.pendingDeepLinkCapsuleID = nil
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Capsule.self, inMemory: true)
        .environment(NotificationCoordinator())
        .environment(CloudSyncMonitor())
        .environment(StoreService(autoStart: false))
}
