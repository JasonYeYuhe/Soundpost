import Foundation
import SwiftData
import struct SwiftUI.LocalizedStringKey
import Testing
import UserNotifications
@testable import Soundpost

/// Seal at the moment of capture (M20 §4E).
///
/// The take is seeded the way a real one is — `finishRecordingForTesting`, which draws a
/// surprise echo — with the echo at its default. `setReviewStateForTesting` leaves
/// `echoAt` nil, and a test seeded that way passes against the very bug it is for: the
/// echo assignment written after the seal, putting an echo back on a sealed capsule.
@MainActor
@Suite("Seal at capture")
struct CaptureSealTests {
    private let day: TimeInterval = 86_400

    private func takeInReview() -> CaptureViewModel {
        let viewModel = CaptureViewModel()
        viewModel.finishRecordingForTesting(fileName: "take.m4a", duration: 5)
        return viewModel
    }

    @Test func aCaptureSavedSealedIsSealedAtNineAndNeverEchoes() throws {
        let store = try TestSupport.isolatedStore()
        let viewModel = takeInReview()
        #expect(viewModel.echoAt != nil && viewModel.echoEnabled, "the take must carry a real echo")
        let chosen = Date.now.addingTimeInterval(40 * day)

        viewModel.chooseSeal(until: chosen)
        let capsule = try #require(try viewModel.save(using: store))

        #expect(capsule.state == .sealed)
        #expect(capsule.sealUntil == SealClock.normalize(chosen, in: .current))
        #expect(capsule.sealTimeZoneID == TimeZone.current.identifier)
        #expect(capsule.echoAt == nil, "a sealed capture must not also echo")
        #expect(capsule.serverJobSyncedAt == nil, "the next reconcile must upsert its far job")
        // Saved in the one write, not left pending.
        let held = try ModelContext(store.context.container).fetch(FetchDescriptor<Capsule>())
        #expect(held.map(\.id) == [capsule.id])
        #expect(held.first?.state == .sealed)
    }

    @Test func unsealingASealedCaptureLeavesNoEchoBehind() throws {
        let store = try TestSupport.isolatedStore()
        let viewModel = takeInReview()
        viewModel.chooseSeal(until: Date.now.addingTimeInterval(40 * day))
        let capsule = try #require(try viewModel.save(using: store))

        try store.commitUnseal(capsule)

        #expect(capsule.state == .captured)
        let plan = NotificationPlanner.plan(capsules: [capsule], now: .now)
        #expect(plan.isEmpty, "an unsealed capture would echo on a day nobody chose")
    }

    @Test func theChoiceIsClearedByResetAndNeverExistsWithoutADay() throws {
        let store = try TestSupport.isolatedStore()
        let viewModel = takeInReview()
        #expect(viewModel.comesBack == .echo)
        #expect(viewModel.sealChoice == nil, "nothing is sealed until a day is chosen")

        let chosen = Date.now.addingTimeInterval(60 * day)
        viewModel.chooseSeal(until: chosen)
        #expect(viewModel.sealChoice == chosen)
        #expect(!viewModel.echoEnabled, "a seal replaces the echo")
        _ = try viewModel.save(using: store)
        #expect(viewModel.comesBack == .echo, "the next take starts from the default")

        let discarded = takeInReview()
        discarded.chooseSeal(until: chosen)
        discarded.discard()
        #expect(discarded.comesBack == .echo)
    }

    @Test func turningTheEchoOffLeavesASealAloneAndOnReplacesIt() {
        let viewModel = takeInReview()
        let chosen = Date.now.addingTimeInterval(60 * day)
        viewModel.chooseSeal(until: chosen)
        viewModel.echoEnabled = false
        #expect(viewModel.sealChoice == chosen)
        viewModel.echoEnabled = true
        #expect(viewModel.comesBack == .echo)

        viewModel.chooseSeal(until: chosen)
        viewModel.dropSeal()
        #expect(viewModel.comesBack == .off)
    }

    /// The catalog key a `LocalizedStringKey` was built with. Its `==` does not compare
    /// interpolated arguments reliably, so the key is read directly.
    private func catalogKey(_ key: LocalizedStringKey) -> String? {
        Mirror(reflecting: key).children.first { $0.label == "key" }?.value as? String
    }

    /// The row repeats the seal sheet's own sentence for the chosen day, chosen by the
    /// same rule: `.notDetermined` is a promise here, as in the sheet, because the seal
    /// option asks when its day is confirmed; only a denial says nothing will alert you.
    @Test func theSealRowPromisesExactlyWhenTheSealSheetDoes() throws {
        let day = Date.now.addingTimeInterval(90 * day)
        let promise = "Soundpost will hide this capsule and notify you on %@. This is a gentle, honor-system seal kept on your device — not encryption."
        let noAlert = "Soundpost will hide this capsule until %@. Notifications are off, so nothing will alert you — it reappears here on its date. This is a gentle, honor-system seal kept on your device — not encryption."

        let coordinator = NotificationCoordinator()
        for status in [UNAuthorizationStatus.notDetermined, .authorized] {
            coordinator.setAuthorizationForTesting(status)
            #expect(catalogKey(SealSheet.promise(for: day, canPromise: coordinator.canPromiseAReminder))
                    == promise, "\(status)")
        }
        coordinator.setAuthorizationForTesting(.denied)
        #expect(catalogKey(SealSheet.promise(for: day, canPromise: coordinator.canPromiseAReminder))
                == noAlert, "a denial must not be told it will be notified")

        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/Capture/CaptureView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        #expect(code.contains("SealSheet.promise(for: day, canPromise: notifications.canPromiseAReminder)"),
                "the seal row no longer says what the seal sheet says, by the sheet's rule")
    }

    /// Sealing "until today" in capture: the picker's instant is a minute after it was
    /// opened, and Save comes later. The seal must still be ahead of Save, still plan
    /// its reminder, and not be over at birth (the M17 §S4 rule, at the capture door).
    @Test func aCaptureSealedUntilTodayIsStillAheadWhenItIsSaved() throws {
        let store = try TestSupport.isolatedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let picked = try #require(calendar.date(bySettingHour: 15, minute: 0, second: 0, of: .now))
        let saved = picked.addingTimeInterval(5 * 60)   // a note and a mood later
        let viewModel = takeInReview()

        viewModel.chooseSeal(until: picked.addingTimeInterval(60))   // what the picker gives for today
        let capsule = try #require(try viewModel.save(using: store, now: saved))

        let until = try #require(capsule.sealUntil)
        #expect(until > saved, "the seal was over before anyone saw it")
        #expect(!capsule.isDueToResurface(now: saved))
        #expect(NotificationPlanner.plan(capsules: [capsule], now: saved).map(\.kind) == [.seal],
                "the reminder the row promised is never scheduled")
    }

    /// One rule for both seal doors (M20 release review): a picked "today" whose minute
    /// has gone by the write becomes a minute from the write; any other day keeps 09:00.
    @Test func theSealInstantIsDecidedAtTheWrite() throws {
        let tz = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let base = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15)))
        let staleFloor = base.addingTimeInterval(60)          // picked at 15:00
        let writtenAt = base.addingTimeInterval(5 * 60)        // written at 15:05

        #expect(CapsuleStore.sealInstant(for: staleFloor, in: tz, now: writtenAt)
                == writtenAt.addingTimeInterval(60))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 7)))
        let nineToday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9)))
        #expect(CapsuleStore.sealInstant(for: morning.addingTimeInterval(60), in: tz, now: morning) == nineToday)
        let later = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 15)))
        let nineLater = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 9)))
        #expect(CapsuleStore.sealInstant(for: later, in: tz, now: writtenAt) == nineLater)
    }

    /// The detail screen's seal uses the same rule, after its permission prompt.
    @Test func theDetailScreenSealsAtTheInstantOfTheWrite() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/Views/CapsuleDetailView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let seal = try #require(code.range(of: "private func seal(until date: Date) {"))
        let body = code[seal.upperBound...].prefix(900)
        let prompt = try #require(body.range(of: "requestAuthorization()"))
        let write = try #require(body.range(of: "store.commitSeal(capsule, until: CapsuleStore.sealInstant(for: date))"),
                                 "the detail seal writes the picked instant, which may be past by now")
        #expect(prompt.lowerBound < write.lowerBound)
    }

    /// Asked when the day is confirmed — inside Seal — and nowhere else; and neither that
    /// nor the save calls a sync (the gallery observer owns it, §4E).
    @Test func permissionIsAskedOnSealAndNothingInCaptureSyncs() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Soundpost/Capture/CaptureView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let sheet = try #require(code.range(of: "SealSheet(initialDate: viewModel.sealChoice) { day in"))
        let onSeal = code[sheet.upperBound...].prefix(while: { $0 != "}" })
        #expect(onSeal.contains("viewModel.chooseSeal(until: day)"))
        #expect(onSeal.contains("requestAuthorization()"))
        #expect(code.components(separatedBy: "chooseSeal(").count - 1 == 1,
                "the seal is chosen somewhere other than the sheet's Seal button")
        #expect(code.components(separatedBy: "requestAuthorization()").count - 1 == 1)
        #expect(!code.contains("notifications.sync("), "capture must not run its own sync")
    }

    /// For a fixed library, saving the same take sealed instead of echoing changes the
    /// 64-slot plan only in that capsule's entry — its kind and its date — and the save
    /// moves `sealSignature`, which is what makes the gallery sync it.
    @Test func sealingAtCaptureChangesThePlanOnlyForThatCapsule() throws {
        let now = Date.now
        func library() throws -> CapsuleStore {
            let store = try TestSupport.isolatedStore()
            for index in 0..<70 {
                let capsule = store.create(createdAt: now.addingTimeInterval(-Double(index + 1) * day))
                try store.markRecording(capsule)
                try store.markCaptured(capsule, audioFileName: "x.m4a", durationSeconds: 3,
                                       waveformSamples: [0.4])
                if index.isMultiple(of: 2) {
                    try store.seal(capsule, until: now.addingTimeInterval(Double(index + 2) * day),
                                   timeZone: TimeZone(identifier: "UTC")!, now: now)
                } else {
                    capsule.echoAt = now.addingTimeInterval(Double(index + 3) * day)
                }
            }
            try store.save()
            return store
        }
        let echoing = try library()
        let sealing = try library()
        let signatureBefore = UpcomingResurfaces.sealSignature(try sealing.all())

        let echoTake = takeInReview()
        let echoed = try #require(try echoTake.save(using: echoing))
        let sealTake = takeInReview()
        sealTake.chooseSeal(until: now.addingTimeInterval(5 * day))
        let sealed = try #require(try sealTake.save(using: sealing))

        let echoPlan = NotificationPlanner.plan(capsules: try echoing.all(), now: now)
        let sealPlan = NotificationPlanner.plan(capsules: try sealing.all(), now: now)
        // Library capsules have different ids in the two stores; compare what is planned
        // for them by position, which is ordered by fire date.
        let rest = { (plan: [PlannedNotification], skip: UUID) in
            plan.filter { $0.capsuleID != skip }.map { "\($0.kind)|\($0.fireDate.timeIntervalSince1970)" }
        }
        #expect(rest(echoPlan, echoed.id) == rest(sealPlan, sealed.id),
                "the rest of the library's plan moved")
        #expect(echoPlan.first { $0.capsuleID == echoed.id }?.kind == .echo)
        #expect(sealPlan.first { $0.capsuleID == sealed.id }?.kind == .seal)
        #expect(UpcomingResurfaces.sealSignature(try sealing.all()) != signatureBefore)
    }
}
