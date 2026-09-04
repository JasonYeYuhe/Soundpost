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
    /// The app's single playback owner (M16 §4A). The gallery's cards drive it, and
    /// every transition away from the gallery stops it.
    @Environment(PlaybackController.self) private var playback
    @Query(sort: \Capsule.createdAt, order: .reverse) private var capsules: [Capsule]
    /// Every rejection, as one query (M18 §4B).
    ///
    /// **One query for the whole gallery, not one per card and not a fetch per
    /// capsule.** The detail screen is handed the resolved index rather than running
    /// its own, so a correction made there — or one arriving from another device —
    /// repaints the card behind it through this same observation.
    @Query private var rejections: [SoundRejection]
    @State private var showingCapture = false
    @State private var showingSettings = false
    @State private var path: [Capsule] = []
    /// The capsule currently presented as a full-screen resurface reveal (§S4).
    @State private var revealCapsule: Capsule?
    /// Set when the current reveal opened a genuine resurface, so the milestone
    /// review prompt fires *after* the reveal is dismissed — never during the
    /// moment, never on launch/capture (§S5).
    @State private var reviewAfterReveal = false
    // Calm gallery browsability (§S6): search + a collapsible mood/sealed filter.
    @State private var searchText = ""
    @State private var filterMoods: Set<Mood> = []
    @State private var sealedOnly = false
    /// The "sounded like this" facet, set by tapping a phrase on a capsule's detail
    /// screen (M17 §S3). **Never derived by walking the library**: the chip shown is
    /// the one the user just tapped, so no facet list is enumerated on a path the
    /// 20 Hz player already drives (M16 §7).
    @State private var filterSounds: Set<String> = []
    @State private var showingFilters = false
    /// Mirrors the lock-screen-preview preference (toggled in Settings, §S3/§S7).
    /// Changing it must force a full notification reconcile so already-scheduled
    /// requests don't keep a stale personalized/generic body (§S3 P0).
    @AppStorage(NotificationPreferences.personalizedKey) private var personalizedNotifications = false

    /// The user's custom mood colours (M14). Observed so a change in Settings
    /// repaints immediately, exactly like `cardTheme`. Resolving never reads
    /// `isPro` — that is what keeps a chosen colour rendering after a lapse.
    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }

    var body: some View {
        // **The one resolution.** Held in a `let` for the whole body evaluation and
        // handed to the gallery and to both one-capsule sheets, so there is no
        // computed property anywhere in this file that returns a `RejectionIndex` —
        // which is what made the old bug invisible. `contentViewResolvesRejections\
        // OnlyThroughOnePass` is the guard, and it can be a simple "this file never
        // calls the resolver" because of this line.
        let pass = GalleryPass.make(capsules: capsules, rejections: rejections,
                                    criteria: filterCriteria)
        return NavigationStack(path: $path) {
            Group {
                if capsules.isEmpty {
                    emptyState
                } else {
                    gallery(pass)
                }
            }
            .searchable(text: $searchText, prompt: Text("Search your sounds"))
            .navigationTitle("Soundpost")
            .navigationDestination(for: Capsule.self) {
                CapsuleDetailView(capsule: $0, rejecting: pass.rejecting,
                                  onFindSimilar: findSimilar)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The calm Settings hub (§S7): notifications, iCloud + delivery,
                    // export-your-data, Pro, privacy/support. Replaces the M11 minimal
                    // Pro entry (a person icon read as "account"). Sits beside the
                    // primary "New capsule" action.
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")

                    Button { showingCapture = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("New capsule")
                }
            }
            .sheet(isPresented: $showingCapture) { CaptureView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .fullScreenCover(item: $revealCapsule, onDismiss: requestReviewIfEarned) { capsule in
                ResurfaceView(capsule: capsule, rejecting: pass.rejecting) {
                    reviewAfterReveal = true
                }
            }
        }
        .task { await refreshAndSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshAndSync() }
            } else {
                // Recording and playback are both foreground-only (docs/PROJECT.md
                // §1e.4), so a clip that kept "playing" into the background would be
                // a control lying about silence.
                playback.stop()
            }
        }
        .onChange(of: showingCapture) { _, presented in
            // Capture builds its own player for the unsaved recording; the gallery's
            // must not be sounding underneath it.
            if presented { playback.stop() }
        }
        .onChange(of: sealSignature) { _, _ in
            Task { await notifications.sync(capsules: capsules, in: modelContext) }
        }
        .onChange(of: personalizedNotifications) { _, _ in
            // Re-issue owned requests with fresh copy when the preference flips,
            // so no stale personalized/generic body lingers on the lock screen.
            Task { await notifications.sync(capsules: capsules, in: modelContext) }
        }
        .onChange(of: notifications.pendingDeepLinkCapsuleID) { _, id in
            handleDeepLink(id)
        }
        .onChange(of: capsules.count) { _, _ in
            // The other half of `PendingLink.wait`: a link kept because its capsule had
            // not imported yet is retried the moment the library grows. Cheap — an
            // `Int` comparison, and a no-op whenever nothing is pending.
            drainPendingDeepLink()
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

    // There is deliberately no `rejectionIndex` computed property here any more.
    //
    // There was one, and its own doc comment described the design correctly —
    // resolution "happens here, once, and every card then asks the result a `Set`
    // question". That was M18 §4B's argument, and it was not what the code did: a
    // computed property is evaluated at every use, and `rejecting: rejectionIndex`
    // sat inside a `ForEach`. Every rendered card walked the whole rejection table,
    // and so did each of the three reads of `displayed`. The comment ended by
    // admitting the cost was "still unmeasured"; M19 §4B measured it (§4B-ii).
    //
    // The lesson is not that the property was written wrong — it read correctly at
    // every use site, which is exactly why nobody saw it. It is that a resolver
    // reachable by name from anywhere in a `body` will eventually be read inside a
    // loop. `GalleryPass` stores its results, `body` builds one, and this file no
    // longer contains a call to the resolver at all.


    private var filterCriteria: GalleryFilter.Criteria {
        GalleryFilter.Criteria(searchText: searchText, moods: filterMoods,
                               sealedOnly: sealedOnly, sounds: filterSounds)
    }

    /// The nearest upcoming resurfaces/echoes for the anticipation strip (§S8).
    private var upcoming: [PlannedNotification] {
        UpcomingResurfaces.nearest(capsules)
    }

    /// - Parameter pass: built once in `body`. Taken as a parameter rather than read
    ///   from a property so that this view cannot be rendered without one having been
    ///   made, and cannot make a second.
    private func gallery(_ pass: GalleryPass) -> some View {
        ScrollView {
            LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                // "Coming up" anticipation strip — only on the unfiltered home view,
                // so it stays a calm header, not chrome layered over a search.
                if !filterCriteria.isActive && !upcoming.isEmpty { upcomingStrip }
                filterBar
                if pass.isEmpty {
                    noMatches
                } else {
                    ForEach(pass.sections, id: \.section.id) { group in
                        Section {
                            ForEach(group.capsules) { capsule in
                                // No wrapping `Button`: the card owns its surface tap
                                // so its play control can be a sibling rather than a
                                // second button nested inside this one (M16 §4E).
                                CapsuleCard(capsule: capsule, rejecting: pass.rejecting) {
                                    openCapsule(capsule)
                                }
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
            .animation(.spring(duration: 0.35), value: pass.count)
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

    /// **Only a search says "no results for".** This was always
    /// `ContentUnavailableView.search(text:)`, so a mood filter or a sound facet with
    /// nothing under it answered a question the user had not asked — and with an empty
    /// query it rendered a bare "No Results", which names no cause and offers no way
    /// out (M17 §S4). A filter with nothing under it is a filter that wants removing,
    /// and now says so.
    ///
    /// A query present makes it a search result again, even alongside filters: the
    /// words are the user's own and are part of what they asked.
    @ViewBuilder
    private var noMatches: some View {
        if !filterCriteria.describesASearch {
            ContentUnavailableView {
                Label("Nothing matches this filter", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No capsules match the filters you've set.")
            } actions: {
                Button("Clear filters") { withAnimation { clearFilters() } }
            }
            .padding(.top, 40)
        } else {
            ContentUnavailableView.search(text: searchText)
                .padding(.top, 40)
        }
    }

    /// One definition of "clear", so the filter bar's button and the empty state's
    /// cannot come to mean different things.
    private func clearFilters() {
        filterMoods = []
        sealedOnly = false
        searchText = ""
        filterSounds = []
    }

    /// A collapsed-by-default filter: mood chips + a "Sealed only" toggle. Calm,
    /// secondary chrome — no counters, no engagement loops (§4D).
    // MARK: Upcoming strip (§S8)

    private var upcomingStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coming up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(upcoming, id: \.capsuleID) { upcomingCard($0) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// **An echo card opens its capsule; a seal card does not** (M17 §S4).
    ///
    /// An echo names a capsule whose content is already visible, so going there is
    /// simply the thing the card is about. A seal's capsule is hidden until its date —
    /// tapping it could only ever arrive at the locked screen, which is an invitation
    /// to be told no. The strip stays content-free either way: a countdown, never a
    /// note or a place (§4F).
    @ViewBuilder
    private func upcomingCard(_ item: PlannedNotification) -> some View {
        let isSeal = item.kind == .seal
        let face = upcomingCardFace(item)
        if !isSeal, let capsule = capsules.first(where: { $0.id == item.capsuleID }) {
            Button { openCapsule(capsule) } label: { face }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this capsule")
        } else {
            face
        }
    }

    private func upcomingCardFace(_ item: PlannedNotification) -> some View {
        let isSeal = item.kind == .seal
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: isSeal ? "lock.fill" : "bell.badge")
                .foregroundStyle(.secondary)
            Text(relativeCountdown(item.fireDate))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(isSeal ? "Opens" : "Echo")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 130, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// A localized, content-free countdown ("in 23 days"). Never reveals which
    /// capsule or its hidden words — anticipation only (§4F).
    private func relativeCountdown(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    @ViewBuilder
    private var filterBar: some View {
        let criteria = filterCriteria
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
                // The sound facet, when there is one. Rendered from the SET, never
                // from the library: a facet list derived by walking every capsule
                // inside `body` would run on a path that already re-walks several
                // times per pass and is driven at 20 Hz during playback (§S3).
                if !filterSounds.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(filterSounds).sorted(), id: \.self) { soundFilterChip($0) }
                    }
                }
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
                    Button("Clear filters") { withAnimation { clearFilters() } }
                        .font(.caption)
                }
            }
        }
    }

    /// The active sound facet, with the way out of it. Attributed in the copy, like
    /// every other place a guess appears (§4A rule 1) — a bare "rain" chip in a filter
    /// bar would read as a tag the user applied to their own capsules.
    ///
    /// A label the vocabulary no longer names cannot produce a chip, so it cannot
    /// produce a filter the user is unable to see or remove: it is dropped along with
    /// the facet itself.
    @ViewBuilder
    private func soundFilterChip(_ identifier: String) -> some View {
        if let phrase = SoundVocabulary.displayName(for: identifier),
           let sentence = SoundprintDisplay.sentence(for: [phrase]) {
            Button {
                withAnimation { _ = filterSounds.remove(identifier) }
            } label: {
                HStack(spacing: 6) {
                    Text(sentence)
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.16), in: SwiftUI.Capsule())
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove the \(phrase) filter"))
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
            .background(selected ? palette.tint(for: mood).opacity(0.22) : Color(.secondarySystemBackground), in: SwiftUI.Capsule())
            .overlay(SwiftUI.Capsule().stroke(selected ? palette.tint(for: mood) : .clear, lineWidth: 1.5))
            .foregroundStyle(selected ? palette.tint(for: mood) : .primary)
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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
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
        // Authorization is async and revocable from Settings while the app is
        // backgrounded, so it is read on every foreground rather than once at launch
        // — otherwise the seal sheet goes on promising a reminder the OS has since
        // refused (M17 §S4).
        await notifications.refreshAuthorization()
        await notifications.sync(capsules: capsules, in: modelContext)
        drainPendingDeepLink()
    }

    /// Open the capsule a notification tap asked for, if one is waiting.
    ///
    /// **The cold-launch tap used to do nothing.** `pendingDeepLinkCapsuleID`'s only
    /// consumer was `.onChange`, which does not fire for a value that was already set
    /// at the first body evaluation — and a tap that *launches* the app sets it before
    /// there is any body to change. So the one tap that most obviously means "take me
    /// to this capsule" was the one tap that was dropped. The coordinator's unit tests
    /// could not see it: they assert the id was set, which it always was.
    ///
    /// Called after every `refreshAndSync`, which covers both the cold launch and a
    /// return to the foreground; `.onChange` still covers a tap while the app is
    /// already running. Harmless when nothing is pending.
    private func drainPendingDeepLink() {
        handleDeepLink(notifications.pendingDeepLinkCapsuleID)
    }

    /// The single "open capsule" action every card tap and deep link routes
    /// through (§S4/§4C): refresh due seals first (so a `.sealed`-past-date capsule
    /// flips to `.resurfaced`), then present the **reveal** for a due/resurfaced
    /// capsule or navigate to detail otherwise. One decision point, so a due seal
    /// never opens as a plain detail screen.
    private func openCapsule(_ capsule: Capsule) {
        // Opening anything supersedes a link still waiting for its capsule to import.
        // This is what bounds `PendingLink.wait` without inventing a clock: the user
        // going somewhere themselves is the event that means "I have moved on", and
        // without it a capsule arriving minutes later would yank them out of whatever
        // they were doing.
        notifications.pendingDeepLinkCapsuleID = nil
        // One stop covers every way out of the gallery: detail, the reveal, and the
        // notification deep link, which all route through here (M16 §4A).
        playback.stop()
        let store = CapsuleStore(context: modelContext)
        _ = try? store.refreshDueSeals()
        try? store.save()
        switch CapsuleOpenRoute.route(for: capsule) {
        case .reveal: revealCapsule = capsule
        case .detail: path = [capsule]
        }
    }

    /// "Find the others that sounded like this" (§S3): return to the gallery with the
    /// tapped phrase as an active facet.
    ///
    /// It **replaces** rather than accumulates, because the question the user asked is
    /// about the phrase they just tapped, and it clears the search text, which would
    /// otherwise silently narrow the answer with words from a previous question. The
    /// filter bar is opened so the reason the gallery is filtered is on screen —
    /// a filtered library with no visible cause is the app being quietly wrong about
    /// what it is showing.
    private func findSimilar(_ identifier: String) {
        playback.stop()
        filterSounds = [identifier]
        searchText = ""
        filterMoods = []
        sealedOnly = false
        showingFilters = true
        path = []
    }

    /// After the reveal closes, ask for a rating if this was a genuine resurface
    /// and the per-version cap allows it (§S5). The OS further rate-limits.
    private func requestReviewIfEarned() {
        guard reviewAfterReveal else { return }
        reviewAfterReveal = false
        ReviewPrompt.requestIfEligible(requestReview)
    }

    private func handleDeepLink(_ id: UUID?) {
        switch CapsuleOpenRoute.pendingLink(id, among: capsules.map(\.id)) {
        case .open(let found):
            guard let capsule = capsules.first(where: { $0.id == found }) else { return }
            // Cleared BEFORE opening: `openCapsule` mutates `path`, which re-evaluates
            // the body, and a link still marked pending at that moment would be drained
            // a second time.
            notifications.pendingDeepLinkCapsuleID = nil
            openCapsule(capsule)
        case .wait:
            // Deliberately keep it. At a cold launch the tap is handled before CloudKit
            // has delivered the library; clearing here is what made the fix incomplete.
            break
        case .none:
            break
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Capsule.self, inMemory: true)
        .environment(NotificationCoordinator())
        .environment(CloudSyncMonitor())
        .environment(StoreService(autoStart: false))
        .environment(PlaybackController())
}
