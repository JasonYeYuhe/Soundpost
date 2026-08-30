import SwiftUI
import SwiftData
import UIKit

/// Full view of a capsule: large waveform with playback, the one line, mood,
/// place, date. Sealed-but-not-due capsules show an honest locked state.
struct CapsuleDetailView: View {
    let capsule: Capsule

    /// What this person has said was wrong (M18 §4A). Threaded from the gallery's one
    /// `@Query` rather than fetched here, so resolution happens once for the whole
    /// library instead of once per screen — and so a rejection made here, or arriving
    /// from another device, repaints this view through the same observation the
    /// gallery already has (§4B).
    let rejecting: RejectionIndex

    /// "Find the others that sounded like this" (M17 §S3). Passed in rather than
    /// reached for, because the gallery owns both the filter state and the navigation
    /// path — the same arrangement `CapsuleCard.onOpen` and `ResurfaceView.onOpened`
    /// already use. The default makes this view usable from a preview.
    var onFindSimilar: (String) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(StoreService.self) private var store
    /// The app's single playback owner (M16 §4A). This view used to build its own
    /// `AudioPlayer`, which is how a gallery clip could go on sounding underneath it.
    @Environment(PlaybackController.self) private var playback
    @State private var confirmingDelete = false
    /// A correction that could not be written. Surfaced rather than swallowed: the
    /// chip is still there and the person has every reason to think they removed it.
    @State private var correctionWriteFailed = false
    @State private var showingEdit = false
    @State private var showingSeal = false
    @State private var sealedWithNotificationsOff = false
    @State private var showingPaywall = false
    @State private var sharePayload: SharePayload?
    @State private var exportFailed = false
    /// A video render in flight. Replaces the export control with progress + Cancel.
    @State private var isExportingVideo = false
    /// Frames written / total, 0…1 — determinate, because "how long will this take"
    /// deserves a real answer rather than a spinner.
    @State private var videoProgress: Double = 0
    /// Held so Cancel can actually stop the work.
    @State private var videoTask: Task<Void, Never>?
    /// A long clip: confirm the size before spending the time (§4G).
    @State private var confirmingLargeVideo = false
    /// The temp directory holding the rendered `.mp4`. Retained until the share sheet
    /// reports it is finished with the file, then cleaned (M13 §4G).
    @State private var videoWorkspace: VideoExportWorkspace?

    /// The user's custom mood colours (M14). Observed so a change in Settings
    /// repaints immediately, exactly like `cardTheme`. Resolving never reads
    /// `isPro` — that is what keeps a chosen colour rendering after a lapse.
    @AppStorage(MoodPalette.storageKey) private var moodPaletteRaw = ""
    private var palette: MoodPalette { MoodPalette(stored: moodPaletteRaw) }

    /// This device's mirror of the account-wide listening answer, observed rather than
    /// read, so turning listening off in Settings removes what Soundpost heard from
    /// this screen immediately — and so the read is not a `UserDefaults` hit inside
    /// `body`. Default `true` matches `SoundAnalysisPreferences.isEnabled`'s
    /// default-on; write through `ListeningConsentStore.set`, never here.
    @AppStorage(SoundAnalysisPreferences.enabledKey) private var listeningEnabled = true
    /// Whether that answer is an answer at all (M15 §11Q's standing, extended to
    /// display). Both are `@AppStorage` so this view repaints when either changes; the
    /// rule they compose is `SoundAnalysisPreferences.mayReveal`.
    @AppStorage(SoundAnalysisPreferences.hasStandingKey) private var hasStanding = false

    private var tint: Color { palette.tint(for: capsule.mood) }
    private var isLocked: Bool { capsule.state == .sealed && !capsule.isContentVisible() }

    /// What Soundpost heard, subject to every §4A rule at once. Empty on a
    /// sealed-not-due capsule, empty with listening off, empty when nothing stored is
    /// showable — and never assembled here, so this screen and the card cannot drift.
    private var heard: [Soundprint.Showable] {
        SoundprintDisplay.heard(for: capsule, on: .detail, rejecting: rejecting,
                                listening: listeningEnabled && hasStanding)
    }

    /// Whether this capsule holds a label the person has dismissed — the only thing
    /// the way back needs to know. Not *which*: naming it would put the guess back on
    /// the screen it was removed from (see `SoundprintDisplay.dismissedIdentifiers`).
    private var hasDismissed: Bool {
        !SoundprintDisplay.dismissedIdentifiers(
            for: capsule, rejecting: rejecting,
            listening: listeningEnabled && hasStanding).isEmpty
    }
    /// This capsule's control state, not the player's: the owner is shared now, so
    /// "playing" has to mean "playing *this*".
    private var playbackState: PlaybackController.ControlState { playback.controlState(for: capsule) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if isLocked { lockedView } else { openView }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(capsule.mood?.label ?? String(localized: "Capsule"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Editing is offered only while the content is visible (§4B).
                    // A sealed capsule's words are hidden from its owner, so the way
                    // in simply is not there — a stronger guarantee than an error,
                    // though `CapsuleStore.update` still refuses one.
                    if !isLocked {
                        Button { showingEdit = true } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete capsule", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this capsule?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("This permanently removes the recording.")
        }
        .sheet(isPresented: $showingSeal) {
            SealSheet(onSeal: seal(until:))
        }
        .sheet(isPresented: $showingEdit) {
            CapsuleEditSheet(capsule: capsule, onSaved: resyncAfterEdit)
        }
        .alert("Sealed — but reminders are off", isPresented: $sealedWithNotificationsOff) {
            Button("Open Settings") { openSettings() }
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("This capsule is sealed and will reappear here on its date. To be reminded on the day, turn on notifications for Soundpost in Settings.")
        }
        .sheet(item: $sharePayload) { payload in
            // Clean the video's temp dir only once the sheet is done with the file —
            // shared, saved, or cancelled. (No-op for the image share, which owns no
            // workspace.)
            ShareSheet(items: payload.items) {
                videoWorkspace?.clean()
                videoWorkspace = nil
            }
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView(context: "Export & share is a Pro feature.")
        }
        .alert("Couldn't prepare the export", isPresented: $exportFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please try again.")
        }
        .alert("Couldn't save that", isPresented: $correctionWriteFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Soundpost couldn't record your correction. Please try again.")
        }
        // Arithmetic-only size preflight (§4G): estimated from the clip's duration and
        // a measured per-second constant — never from a free-disk-space query, which
        // is a Required-Reason API we deliberately don't use.
        .alert("Prepare this video?", isPresented: $confirmingLargeVideo) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") { startVideoExport() }
        } message: {
            Text("This one is about \(estimatedVideoSize), so it will take a moment to make.")
        }
        .onAppear(perform: markOpenedIfResurfaced)
        .onDisappear {
            playback.stop()
            // Nobody is waiting for this render any more — stop it and let the
            // cancellation path clean the temp dir, rather than burning CPU on a
            // video that has nowhere to go.
            videoTask?.cancel()
        }
    }

    private var openView: some View {
        VStack(spacing: 24) {
            WaveformView(
                samples: capsule.waveformSamples,
                color: tint,
                // One screen, one capsule — the right place for the 20 Hz progress
                // the gallery card deliberately does not read (M16 §7).
                progress: playbackState == .idle ? nil : playback.player.progress
            )
            .frame(height: 150)
            .padding(.top, 12)

            Button { playback.toggle(capsule) } label: {
                Image(systemName: playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackState == .playing ? "Pause" : "Play")
            // Read the play control and clip length as one unit (§S8 a11y): the
            // visible duration is folded into the button's value so VoiceOver
            // announces "Play, 0:08" together instead of two stray elements.
            .accessibilityValue(durationString)
            .sensoryFeedback(.impact(weight: .light), trigger: playbackState)

            Text(durationString)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if let note = capsule.note, !note.isEmpty {
                Text(note)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            heardSection

            VStack(spacing: 8) {
                if let place = capsule.place?.name {
                    Label(place, systemImage: "mappin.and.ellipse")
                }
                Label(capsule.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if capsule.state == .captured {
                Button { showingSeal = true } label: {
                    Label("Seal to the future", systemImage: "lock")
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .padding(.top, 8)
            }

            // Export/share — Pro-gated, offered only here in the *visible* view
            // (the locked view has no export affordance, so a sealed-not-due
            // capsule structurally can't be exported — M11 §4G).
            exportControl
                .padding(.top, capsule.state == .captured ? 0 : 8)
        }
    }

    /// What Soundpost heard, said in the reader's language and attributed in the copy
    /// (M17 §4A).
    ///
    /// **Below the note, never above it.** The one line the person wrote is the title
    /// of their own memory; this is a machine's guess about the room, and it says so.
    ///
    /// The attribution is a *header over chips* rather than one joined sentence, which
    /// is the shape the capture sheet already uses and which M17 §S3 needs — a phrase
    /// has to be tappable on its own to become a gallery facet. No chip is ever a bare
    /// noun in context: the header names the guesser directly above them, and each
    /// chip carries the whole sentence as its accessibility label, because VoiceOver
    /// can land on one out of the header's context.
    @ViewBuilder
    private var heardSection: some View {
        let showable = heard
        VStack(spacing: 8) {
            if !showable.isEmpty {
                Text("Soundpost heard")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Wrapping, not scrolling: at most three phrases, and a horizontal
                // scroll view on a vertically-scrolling screen is a gesture conflict
                // for the sake of a row that fits.
                HStack(spacing: 8) {
                    ForEach(showable) { heardChip($0) }
                }
            }
            // Outside the check above on purpose: a capsule whose only label was
            // dismissed has nothing left to show, and that is exactly the capsule
            // whose owner most needs the way back.
            if hasDismissed { restoreControl }
        }
        .padding(.top, showable.isEmpty && !hasDismissed ? 0 : 4)
    }

    /// A phrase, the way back to every other capsule that sounded like it (M17 §S3),
    /// and — from M18 — the way to say it was wrong.
    ///
    /// **The correction is a context menu, and that is the design rather than a
    /// compromise.** Nothing may ask whether a label was right; no prompt, no counter,
    /// no "was this useful?" (§0B). The affordance is there when someone goes looking
    /// for it and silent otherwise, which is what a long press is. SwiftUI also
    /// publishes context-menu items as VoiceOver actions, so it is not a gesture only
    /// sighted users have.
    ///
    /// The accessibility label is the whole attributed sentence because VoiceOver can
    /// land on one chip out of its header's context; the hint says what tapping does,
    /// which a lone noun cannot.
    private func heardChip(_ item: Soundprint.Showable) -> some View {
        Button {
            onFindSimilar(item.identifier)
        } label: {
            Text(item.phrase)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: SwiftUI.Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SoundprintDisplay.sentence(for: [item.phrase]) ?? item.phrase)
        .accessibilityHint("Find your other capsules that sounded like this")
        .contextMenu {
            Button(role: .destructive) { dismissSound(item.identifier) } label: {
                Label("No, it wasn't", systemImage: "xmark.circle")
            }
        }
    }

    /// The way back, and it deliberately names nothing.
    ///
    /// A dismissed label is gone from this screen; listing it here under a different
    /// heading would put the guess back in front of the person who said it was wrong,
    /// which for an upsetting mislabel is worse than never having offered the
    /// correction. So this restores everything this capsule's owner dismissed at once.
    /// The cost is real and small: someone who dismissed two labels and wants one back
    /// restores both and dismisses the other again.
    private var restoreControl: some View {
        Button("Show dismissed sounds again", action: restoreDismissedSounds)
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, heard.isEmpty ? 0 : 2)
    }

    /// **The gate sits before the menu** (M13 §4E). A free user taps one button and
    /// meets one paywall — they never see an image/video menu, so the affordance
    /// can't tease a feature they don't have. Only a Pro user is offered the choice.
    @ViewBuilder
    private var exportControl: some View {
        if isExportingVideo {
            videoProgressRow
        } else if store.gate.canExport {
            Menu {
                Button(action: exportImageTapped) {
                    Label("Share as image", systemImage: "photo")
                }
                Button(action: exportVideoTapped) {
                    Label("Share as video", systemImage: "film")
                }
            } label: {
                exportLabel
            }
            .buttonStyle(.bordered)
            .tint(tint)
        } else {
            Button(action: { showingPaywall = true }) { exportLabel }
                .buttonStyle(.bordered)
                .tint(tint)
        }
    }

    private var exportLabel: some View {
        Label("Export & share", systemImage: "square.and.arrow.up")
    }

    /// Determinate progress plus a real Cancel. Stacked rather than in one row so it
    /// stays readable at accessibility text sizes, and exposed to VoiceOver as one
    /// element whose value is the percentage.
    private var videoProgressRow: some View {
        VStack(spacing: 10) {
            ProgressView(value: videoProgress)
                .progressViewStyle(.linear)
                .tint(tint)
                .accessibilityLabel(Text("Preparing your video…"))

            HStack(alignment: .firstTextBaseline) {
                Text("Preparing your video…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel", action: cancelVideoExport)
                    .font(.footnote.weight(.medium))
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal)
    }

    /// The size estimate shown in the preflight prompt, localized by
    /// `ByteCountFormatStyle`.
    private var estimatedVideoSize: String {
        let bytes = VideoExportConfiguration.vertical1080x1920
            .estimatedByteCount(forDuration: capsule.durationSeconds)
        return bytes.formatted(.byteCount(style: .file))
    }

    /// The M11 path, unchanged: the card image plus the capsule's audio.
    private func exportImageTapped() {
        if let payload = CapsuleExporter.payload(for: capsule) {
            sharePayload = payload
        } else {
            exportFailed = true
        }
    }

    /// The M13 path: render the branded waveform video, then share it.
    private func exportVideoTapped() {
        guard !isExportingVideo else { return }
        switch VideoExportPolicy.decide(for: capsule, gate: store.gate) {
        case .needsPro:
            // Only reachable if the entitlement lapsed between this view rendering
            // and the tap. Same single paywall, no video-specific sales pitch.
            showingPaywall = true
        case .nothingToExport:
            exportFailed = true
        case .allowed:
            // Warn first only for a genuinely long clip; short ones just go.
            if VideoExportConfiguration.vertical1080x1920
                .needsSizeWarning(forDuration: capsule.durationSeconds) {
                confirmingLargeVideo = true
            } else {
                startVideoExport()
            }
        }
    }

    /// Renders off the main actor and hands the finished file to the share sheet.
    /// Every exit — success, failure, cancel — leaves no stale `.mp4` behind.
    private func startVideoExport() {
        let workspace: VideoExportWorkspace
        let input: VideoExportInput
        do {
            workspace = try VideoExportWorkspace.makeUnique()
            input = try VideoExporter.input(for: capsule, in: workspace)
        } catch {
            Diagnostics.notice("Video export could not start")
            exportFailed = true
            return
        }
        videoWorkspace = workspace
        videoProgress = 0
        isExportingVideo = true
        videoTask = Task {
            do {
                let result = try await VideoExporter.export(input) { fraction in
                    // Already throttled to whole percents inside the exporter, so
                    // this is ~100 hops for a whole render, not one per frame.
                    Task { @MainActor in videoProgress = fraction }
                }
                sharePayload = SharePayload(items: [result.url])
            } catch is CancellationError {
                // The user asked to stop. Not a failure — say nothing, leave nothing.
                workspace.clean()
                videoWorkspace = nil
            } catch {
                workspace.clean()
                videoWorkspace = nil
                Diagnostics.notice("Video export failed")
                exportFailed = true
            }
            isExportingVideo = false
            videoProgress = 0
            videoTask = nil
        }
    }

    private func cancelVideoExport() {
        videoTask?.cancel()
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Sealed").font(.title2.weight(.semibold))
            if let until = capsule.sealUntil {
                Text("This capsule opens \(until.formatted(.dateTime.weekday().month().day().year())).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Text("A gentle seal: Soundpost keeps it hidden until then, but this is an honor-system lock on your device — not encryption.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            // Unseal reveals the capsule early — it doesn't delete anything, so
            // it is a neutral action, not a destructive (red) one.
            Button("Unseal", action: unseal)
                .font(.subheadline)
                .padding(.top, 4)
        }
        .padding(.top, 48)
    }

    // MARK: Saying no (M18 §S3)

    /// Record that this label was wrong, and re-issue anything already carrying it.
    ///
    /// **The notification resync is not optional** (§4C). A lock-screen body is
    /// rendered and baked at schedule time, and `NotificationScheduler` skips an
    /// identifier it has already scheduled — so without this the phrase the person
    /// just dismissed goes on firing at them on its seal date. M16 §S1 made the
    /// request's identity include a fingerprint of its *rendered* copy, which is what
    /// makes a plain resync enough: the body changes, the fingerprint changes, the
    /// request is replaced. Exactly what an edit does (`resyncAfterEdit`).
    ///
    /// Nothing re-analyses. Rejecting "rain" says *do not show me this*, not *go and
    /// look again* (§0B) — and a re-analysis could only ever propose the same label
    /// from the same audio.
    private func dismissSound(_ identifier: String) {
        write(rejected: true, identifiers: [identifier])
    }

    private func restoreDismissedSounds() {
        write(rejected: false,
              identifiers: SoundprintDisplay.dismissedIdentifiers(
                for: capsule, rejecting: rejecting,
                listening: listeningEnabled && hasStanding))
    }

    private func write(rejected: Bool, identifiers: some Collection<String>) {
        guard !identifiers.isEmpty else { return }
        do {
            for identifier in identifiers {
                try SoundRejectionStore.set(rejected, identifier: identifier,
                                            forCapsule: capsule.id, in: modelContext)
            }
        } catch {
            // Leave no half-applied insert on the shared main context for the next
            // unrelated save to commit — the same care `SettingsView`'s consent toggle
            // takes. The store already drops its own pending row; this covers a
            // partial run across several identifiers.
            modelContext.rollback()
            correctionWriteFailed = true
            Diagnostics.notice("A sound correction could not be recorded")
            return
        }
        resyncAfterEdit()
    }

    private func markOpenedIfResurfaced() {
        guard capsule.state == .resurfaced else { return }
        let store = CapsuleStore(context: modelContext)
        try? store.open(capsule)
        try? store.save()
    }

    private func seal(until date: Date) {
        Task {
            let granted = await notifications.requestAuthorization()
            let store = CapsuleStore(context: modelContext)
            do {
                try store.seal(capsule, until: date)
                try store.save()
            } catch {
                // Surface the rare failure instead of swallowing it (§S8) — a static,
                // non-PII message to Sentry (Release) + the local log.
                Diagnostics.notice("Seal failed at user action")
            }
            await notifications.sync(capsules: (try? store.all()) ?? [], in: modelContext)
            if granted {
                dismiss() // back to the gallery, where the card now shows the seal
            } else {
                // The seal still happens, but be honest that no reminder will fire
                // until the user enables notifications.
                sealedWithNotificationsOff = true
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        dismiss()
    }

    /// Re-issue this capsule's pending reminder after an edit.
    ///
    /// The gallery's own resync watches `sealSignature`, which carries id, state,
    /// seal and echo — not content — so an edited note would otherwise leave the
    /// lock-screen body quoting the old sentence. From M16 §S1 the request's identity
    /// includes a fingerprint of its rendered copy, so this call actually rebuilds
    /// the body rather than finding the identifier already scheduled and skipping it.
    private func resyncAfterEdit() {
        let store = CapsuleStore(context: modelContext)
        Task { await notifications.sync(capsules: (try? store.all()) ?? [], in: modelContext) }
    }

    private func unseal() {
        let store = CapsuleStore(context: modelContext)
        do {
            try store.unseal(capsule)
            try store.save()
        } catch {
            Diagnostics.notice("Unseal failed at user action")
        }
        Task { await notifications.sync(capsules: (try? store.all()) ?? [], in: modelContext) }
    }

    private func delete() {
        // Cancel the far-future server job first: a deleted capsule isn't in the
        // @Query array, so the sync→reconcile path can't cancel it (§S4). Capture
        // the id before the delete; offline-first — the local delete proceeds
        // regardless, and the cancel is best-effort (idempotent, signed-in only).
        let capsuleID = capsule.id
        // Persist the cancel intent before deleting so it survives a cold launch
        // or a momentarily-unresolved key and is retried by reconcile (§S4).
        DeliveryPreferences.enqueuePendingCancel(capsuleID)
        if let file = capsule.audioFileName { try? AudioStore().delete(file) }
        // Through the store, so the capsule's rejections go with it in the same save
        // (§4F). This used to be a bare `modelContext.delete`, which is why the
        // pruning lives in `CapsuleStore.delete` where a test can reach it rather
        // than in this view where nothing could.
        do {
            let store = CapsuleStore(context: modelContext)
            try store.delete(capsule)
            try modelContext.save()
        } catch {
            Diagnostics.notice("Delete save failed at user action")
        }
        Task { await notifications.sealDelivery?.cancelJob(capsuleID: capsuleID) }
        dismiss()
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
