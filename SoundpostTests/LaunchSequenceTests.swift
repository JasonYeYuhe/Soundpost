import Foundation
import Testing
@testable import Soundpost

/// The launch's privacy-critical order (M21 §4C).
///
/// The sequence runs against closures that record each step, so these tests read the
/// order the code actually uses — not that each step was called. Swapping any two
/// steps in `LaunchSequence.run` fails `theStepsRunInExactlyThisOrder`.
@MainActor
@Suite("Launch sequence")
struct LaunchSequenceTests {
    /// A recorder plus the knobs a test turns.
    final class Script {
        var ran: [String] = []
        var consent: Result<Bool, Error> = .success(true)
        var answered: Result<Bool, Error> = .success(false)
        var standing = true

        var steps: LaunchSequence.Steps {
            LaunchSequence.Steps(
                startObservers: { self.ran.append("observers") },
                reclaimExportScratch: { self.ran.append("scratch") },
                countOrphanedAudio: { self.ran.append("orphans") },
                applyAccountConsent: {
                    self.ran.append("consent")
                    return try self.consent.get()
                },
                resyncNotifications: { self.ran.append("resync") },
                accountHasAnswered: {
                    self.ran.append("answered")
                    return try self.answered.get()
                },
                recordStanding: { answered in
                    self.ran.append("standing")
                    return answered || self.standing
                },
                remediateWrittenOff: { self.ran.append("remediate") },
                backfillLibrary: { self.ran.append("backfill") }
            )
        }
    }

    @Test func theStepsRunInExactlyThisOrder() async {
        let script = Script()
        await LaunchSequence(steps: script.steps).run()
        #expect(script.ran == ["observers", "scratch", "orphans", "consent", "resync",
                               "answered", "standing", "remediate", "backfill"])
    }

    /// The account's answer cannot be read: no retrospective analysis this launch, but
    /// the notification bodies are still rebuilt.
    @Test func anUnreadableConsentMeansNoAnalysisButStillAResync() async {
        let script = Script()
        script.consent = .failure(DeliveryTestError.boom)
        await LaunchSequence(steps: script.steps).run()
        #expect(script.ran.contains("resync"))
        #expect(!script.ran.contains("remediate"))
        #expect(!script.ran.contains("backfill"))
    }

    @Test func listeningOffMeansNoAnalysis() async {
        let script = Script()
        script.consent = .success(false)
        await LaunchSequence(steps: script.steps).run()
        #expect(!script.ran.contains("remediate"))
        #expect(!script.ran.contains("backfill"))
    }

    /// No standing — nothing recorded here and no account answer — means neither drain
    /// touches the library.
    @Test func noStandingMeansNoDrains() async {
        let script = Script()
        script.standing = false
        await LaunchSequence(steps: script.steps).run()
        #expect(script.ran.contains("standing"))
        #expect(!script.ran.contains("remediate"))
        #expect(!script.ran.contains("backfill"))
    }

    /// An account answer gives standing on its own, and an unreadable one counts as
    /// "not answered" rather than stopping the launch.
    @Test func theAccountsAnswerGivesStandingAndAnUnreadableOneDoesNot() async {
        let answered = Script()
        answered.standing = false
        answered.answered = .success(true)
        await LaunchSequence(steps: answered.steps).run()
        #expect(answered.ran.suffix(2) == ["remediate", "backfill"])

        let unreadable = Script()
        unreadable.standing = false
        unreadable.answered = .failure(DeliveryTestError.boom)
        await LaunchSequence(steps: unreadable.steps).run()
        #expect(unreadable.ran.contains("standing"))
        #expect(!unreadable.ran.contains("backfill"))
    }

    // MARK: The app runs the sequence and nothing beside it

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `SoundpostApp.swift` hands the launch to `LaunchSequence` and makes none of its
    /// step calls itself — so a step cannot be re-added beside the sequence, out of
    /// order, without this failing.
    @Test func theAppRunsTheSequenceAndNoStepBesideIt() throws {
        let app = try source("Soundpost/SoundpostApp.swift")
        // The call itself, constructed and run in one expression — not merely a `.run()`
        // somewhere in the file (`AudioSelfTest.run()` is one; a guard that matched it
        // passed with the sequence never run).
        let runsTheSequence = try Regex(#"await LaunchSequence\([^()]*\)\s*\.run\(\)"#)
        #expect(app.contains(runsTheSequence), "the app does not run the launch sequence")
        for step in ["applyToDevice", "hasAnswer", "hasStanding", "hasRecordedHere",
                     "SoundprintRemediation", "SoundprintBackfill", "AudioOrphanAudit",
                     "VideoExportWorkspace", "notifications.sync", "remoteChanges.start",
                     "accountChanges.start", "syncMonitor.start"] {
            #expect(!app.contains(step), "\(step) is called beside the launch sequence")
        }
    }

    /// Each production step is wired to its own implementation, the way the order test
    /// assumes — every call it makes, nothing that swallows a failure the sequence must
    /// see, and nothing that lets a step finish before its work does. The order test
    /// runs stand-ins, so it cannot see any of this.
    @Test func eachProductionStepCallsItsOwnImplementation() throws {
        let code = try source("Soundpost/Services/LaunchSequence.swift")
        let wiring: [(step: String, calls: [String], never: [String])] = [
            ("startObservers:", ["remoteChanges.start(", "accountChanges.start(", "syncMonitor.start("], []),
            ("reclaimExportScratch:", ["VideoExportWorkspace.scavenge()", "VideoExportWorkspace.scavenge(named:",
                                       "VideoExportWorkspace.scavengeLegacyDataExports()"], []),
            ("countOrphanedAudio:", ["AudioOrphanAudit.report("], []),
            // A `try?` here would fail OPEN: the sequence must see the throw.
            ("applyAccountConsent:", ["try ListeningConsentStore.applyToDevice(in: context)"], ["try?", "Task {"]),
            ("resyncNotifications:", ["await notifications.sync("], ["Task {"]),
            ("accountHasAnswered:", ["try ListeningConsentStore.hasAnswer(in: context)"], ["try?"]),
            ("recordStanding:", ["SoundAnalysisPreferences.hasStanding = answered || SoundAnalysisPreferences.hasRecordedHere",
                                 "return SoundAnalysisPreferences.hasStanding"], []),
            ("remediateWrittenOff:", ["SoundprintRemediation.drain(in: context)"], ["Task {"]),
            ("backfillLibrary:", ["await SoundprintBackfill(modelContainer: container).drain()"], ["Task {"])
        ]
        let production = try #require(code.range(of: "self.steps = Steps("))
        let productionEnd = try #require(code.range(of: "func run() async", range: production.upperBound..<code.endIndex))
        var cursor = production.upperBound
        for (index, entry) in wiring.enumerated() {
            let label = try #require(code.range(of: entry.step, range: cursor..<productionEnd.lowerBound),
                                     "\(entry.step) is missing or out of place")
            let end = index + 1 < wiring.count
                ? (code.range(of: wiring[index + 1].step, range: label.upperBound..<productionEnd.lowerBound)?.lowerBound
                   ?? productionEnd.lowerBound)
                : productionEnd.lowerBound
            let body = code[label.upperBound..<end]
            for call in entry.calls {
                #expect(body.contains(call), "\(entry.step) does not call \(call)")
            }
            for forbidden in entry.never {
                #expect(!body.contains(forbidden), "\(entry.step) contains \(forbidden)")
            }
            cursor = label.upperBound
        }
    }
}
