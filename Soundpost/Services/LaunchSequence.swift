import Foundation
import SwiftData

/// The launch's privacy-critical order, in one place a test can read (M21 §4C).
///
/// Until M21 this was the body of a `.task` on the root view, and no test read that
/// file: the order below — consent applied before anything trusts the local mirror,
/// notifications re-synced after it, standing decided before the library is touched,
/// both drains only with standing — was held in place by comments alone. A swap of
/// two lines would have passed every test in the suite.
///
/// **Order only.** The steps are exactly the ones the `.task` ran, in the same order,
/// with the same failure handling; `SoundpostApp.swift` now calls `run()` and nothing
/// else. Production builds its `Steps` from its dependencies here, so a step cannot be
/// re-added beside the sequence (a source guard checks that file); tests build `Steps`
/// from closures that record the order.
///
/// **What it does not order.** The root view's other launch tasks — the audio
/// `Data` backfill (`AudioMigrator`) and the gallery's `refreshAndSync` — run beside
/// this one, unordered with it, as they always have. Neither reads the listening
/// mirror or standing: the audio backfill moves bytes, and the gallery's sync builds
/// notification bodies through the same `contentVersion` that folds listening in, so
/// a sync that runs before consent is applied is corrected by the re-sync here.
@MainActor
struct LaunchSequence {
    struct Steps {
        /// The one-shot onboarding seed (M21 §4D) — first, before standing is read.
        var migrateStandingSeed: () -> Void
        /// Remote-change, account-change and sync-health observers.
        var startObservers: () -> Void
        /// Reclaim export scratch a previous launch left behind.
        var reclaimExportScratch: () -> Void
        /// Count — never delete — audio no capsule points at.
        var countOrphanedAudio: () -> Void
        /// Adopt the account-wide listening answer; returns whether we may listen.
        var applyAccountConsent: () throws -> Bool
        /// Rebuild notification bodies under the answer just applied.
        var resyncNotifications: () async -> Void
        /// Whether the account has answered outright (a `ListeningConsent` row exists).
        var accountHasAnswered: () throws -> Bool
        /// Record standing from the account's answer; returns the standing recorded.
        var recordStanding: (_ answered: Bool) -> Bool
        /// Hand back capsules an older gate wrote off.
        var remediateWrittenOff: () -> Void
        /// Analyse the existing library.
        var backfillLibrary: () async -> Void
    }

    private let steps: Steps

    /// Tests: closures that record what ran.
    init(steps: Steps) {
        self.steps = steps
    }

    /// The app: the real step implementations, given their dependencies.
    init(
        store: ProductionStore,
        notifications: NotificationCoordinator,
        registrar: DeliveryRegistrar,
        remoteChanges: RemoteChangeReconciler,
        accountChanges: DeliveryAccountObserver,
        syncMonitor: CloudSyncMonitor
    ) {
        let container = store.container
        let context = container.mainContext
        self.steps = Steps(
            migrateStandingSeed: {
                SoundAnalysisPreferences.migrateStandingSeed()
            },
            startObservers: {
                // Start app-layer remote-change observation once (idempotent).
                remoteChanges.start(container: container, notifications: notifications)
                // React to iCloud account changes for cloud-backed delivery (M10 §S4).
                accountChanges.start(container: container, notifications: notifications, registrar: registrar)
                // Watch CloudKit sync health for honest, calm in-app copy (S5/S6).
                syncMonitor.start(rung: store.rung)
            },
            reclaimExportScratch: {
                // Reclaim video-export temp dirs a previous launch left behind
                // (a crash, a kill, or a share sheet that never called back —
                // M13 §4G). Nothing is in flight at launch, and it only ever
                // removes children of our own export container.
                VideoExportWorkspace.scavenge()
                VideoExportWorkspace.scavenge(named: VideoExportWorkspace.dataExportContainerName)
                VideoExportWorkspace.scavengeLegacyDataExports()
            },
            countOrphanedAudio: {
                // Count — never delete — audio clips no capsule points at
                // (M17 §4E). Until §S0 a capture sheet dismissed mid-take left
                // one behind, and nothing in the app could see it: every
                // existing check starts from capsule rows, so none of them can
                // fail for a file no row names. This starts from the directory.
                // Deleting on that rule would take the take the user is
                // recording right now, whose row does not exist until save.
                AudioOrphanAudit.report(in: context)
            },
            applyAccountConsent: {
                try ListeningConsentStore.applyToDevice(in: context)
            },
            resyncNotifications: {
                await notifications.sync(
                    capsules: (try? CapsuleStore(context: context).all()) ?? [],
                    in: context)
            },
            accountHasAnswered: {
                try ListeningConsentStore.hasAnswer(in: context)
            },
            recordStanding: { answered in
                LaunchSequence.recordStanding(answered: answered)
            },
            remediateWrittenOff: {
                SoundprintRemediation.drain(in: context)
            },
            backfillLibrary: {
                await SoundprintBackfill(modelContainer: container).drain()
            }
        )
    }

    /// Recorded, not just computed. M15 asked this question only to decide whether to
    /// ANALYSE; M17 gave the app a way to DISPLAY a label, and the display path had no
    /// way to ask it (Codex, M17 review). One expression now answers both. Static so the
    /// tests run the real rule.
    static func recordStanding(answered: Bool) -> Bool {
        SoundAnalysisPreferences.hasStanding = answered || SoundAnalysisPreferences.hasRecordedHere
        return SoundAnalysisPreferences.hasStanding
    }

    func run() async {
        // Take the old onboarding seed once, before anything below reads standing: an
        // install that had finished onboarding when this version first ran keeps the
        // standing it had; one that finishes it later earns standing by recording here
        // or by the account's answer (M21 §4D).
        steps.migrateStandingSeed()
        steps.startObservers()
        steps.reclaimExportScratch()
        steps.countOrphanedAudio()
        // Adopt the account-wide listening answer before anything reads
        // the local mirror (M15 §4I, revised). Ordering matters: the
        // backfill below gates on that mirror, so a withdrawal made on
        // another device has to land here first — otherwise this launch
        // would re-label the very capsules the user cleared elsewhere.
        let mayListen: Bool
        do {
            mayListen = try steps.applyAccountConsent()
        } catch {
            // Fail CLOSED, and only for this launch. The old comment said
            // "using this device's answer" and then ran both drains anyway
            // — but the whole reason this call exists is that the device's
            // answer may be a stale default, so proceeding on it is exactly
            // the case it was written to prevent. Nothing is written to the
            // mirror here: this is a local decision to do no retrospective
            // work until we can read the account, not a new answer.
            mayListen = false
            Diagnostics.notice("Could not read account-wide listening consent at launch; skipping this launch's analysis")
        }
        // Re-sync after consent is applied, as the merge path already does.
        // A withdrawal that landed while the app was closed erases the
        // stored labels, but an already-scheduled lock-screen body has its
        // text baked in and the scheduler skips identifiers it has already
        // scheduled — so without this the phrase Soundpost heard keeps
        // firing on the lock screen after the switch was turned off.
        // `NotificationPreferences.contentVersion` folds listening in for
        // exactly this; it only works if something re-syncs.
        await steps.resyncNotifications()
        // Does this device have standing to analyse the EXISTING library?
        //
        // Distinct from "may we listen", and the distinction is the whole
        // point. A phone set up as new and signed into iCloud imports the
        // library long before the `ListeningConsent` row — CloudKit returns
        // a zone's changes in roughly modification order, so the person who
        // opted out most recently has their answer sorted behind every
        // capsule they own. With no row yet, the mirror reads its default
        // (on), and these two drains would analyse the entire library of
        // somebody who had said no.
        //
        // A row settles it outright. Failing that, `hasRecordedHere` asks
        // whether the mirror is an answer or a default — see its doc; the
        // wipe that makes the mirror untrustworthy clears it too.
        //
        // Nothing is lost by waiting. A genuinely new user has no library
        // to backfill, and capture-time analysis is deliberately NOT gated,
        // so their first capsule is labelled as always. And because
        // `soundprintRaw` syncs with the capsule, this pass is per-library
        // work rather than per-device: a device that skips it is usually
        // skipping work another device has already done.
        let answered = (try? steps.accountHasAnswered()) ?? false
        let hasStanding = steps.recordStanding(answered)
        let mayScanLibrary = mayListen && hasStanding
        guard mayScanLibrary else {
            Diagnostics.info("No standing to analyse the existing library yet — deferring until the account's answer arrives")
            return
        }
        // Hand back the capsules an older generation of gates wrote off,
        // before the backfill runs — reopening sets `soundprintRaw` to
        // nil, which is exactly what the backfill below looks for, so
        // the two compose in one launch instead of two (M15 §11E).
        steps.remediateWrittenOff()
        // Give pre-M15 capsules their soundprints. Batched so peak memory
        // stays one clip and capture keeps the device between batches
        // (M15 §4H), but drained rather than stopped after one batch: the
        // release notes say search finds your rainy mornings, and one
        // batch per launch made that true only after about fifteen of them
        // (§11H).
        await steps.backfillLibrary()
    }
}
