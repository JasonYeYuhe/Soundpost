import Testing
import Foundation
import CloudKit
@testable import Soundpost

/// M10 §S4: the iCloud-account-change observer must fire its reconcile/relink
/// action when `CKAccountChanged` posts (the same observe→handle plumbing as
/// `RemoteChangeReconciler`). The signed-in vs signed-out branch lives in the
/// production `start(...)` wiring (reads the real `ubiquityIdentityToken`); its
/// building blocks — `DeliveryRegistrar.signOut` / `.accountDidChange` — are
/// covered by `DeliveryRegistrarTests`.
@MainActor
struct DeliveryAccountObserverTests {
    @Test func handleInvokesTheAction() async {
        let observer = DeliveryAccountObserver()
        var calls = 0
        observer.observe(onAccountChange: { calls += 1 }, center: NotificationCenter())
        await observer.handle()?.value
        #expect(calls == 1)
        observer.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func postingCKAccountChangedTriggersTheAction() async {
        let center = NotificationCenter()
        let observer = DeliveryAccountObserver()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            observer.observe(onAccountChange: { cont.resume() }, center: center)
            center.post(name: .CKAccountChanged, object: nil)
        }
        observer.stop() // reaching here means the observer fired the action
    }

    @Test func observeIsIdempotent() async {
        let observer = DeliveryAccountObserver()
        var calls = 0
        observer.observe(onAccountChange: { calls += 1 }, center: NotificationCenter())
        observer.observe(onAccountChange: { calls += 100 }, center: NotificationCenter()) // ignored
        await observer.handle()?.value
        #expect(calls == 1)
        observer.stop()
    }
}
