import Testing
import Foundation
@testable import Soundpost

/// Whether Pro is *shown* (1.9.0 review) — `ProOffer`. `ProGateTests` covers what a
/// user may do; this covers the question that got 1.9.0 rejected: whether a user who
/// cannot buy anything is still being offered something.
@MainActor
struct ProOfferTests {

    private let free = ProGate(isPro: false)
    private let owner = ProGate(isPro: true)

    // MARK: - This build

    /// Changing this is the decision to sell Pro, and it belongs to the release that
    /// submits the products with its binary. Two files have to agree, on purpose.
    @Test func proIsNotOnSaleInThisBuild() {
        #expect(ProOffer.isOnSaleInThisBuild == false)
    }

    /// The case App Review is in: a sandbox device where the never-submitted products
    /// may well load. The build's own answer must win, or the reviewer sees the same
    /// paywall again.
    @Test func thisBuildOffersAFreeUserNothingEvenWhenProductsLoad() {
        let offer = ProOffer(gate: free, productsLoaded: true)
        #expect(!offer.mayOpenPaywall)
        #expect(!offer.showsProSection)
        #expect(!offer.upsellsLongerRecording)
        #expect(!offer.showsPersonalisation(hasChoicesToUndo: false))
    }

    @Test func storeServiceOffersNothingToAFreeUser() {
        let service = StoreService(autoStart: false)
        service.purchasedProductIDs = []
        #expect(service.offer == ProOffer(gate: ProGate(isPro: false), productsLoaded: false))
        #expect(!service.offer.mayOpenPaywall)
        #expect(!service.offer.showsProSection)
    }

    /// The same, through `StoreService`'s own wiring and with the products loaded —
    /// the input a test `StoreService` can never produce on its own, and the only one
    /// under which wiring `onSale: true` in by mistake would show.
    @Test func storeServiceWiringOffersNothingEvenWithProductsLoaded() {
        let offer = StoreService.offer(isPro: false, productsLoaded: true)
        #expect(!offer.mayOpenPaywall)
        #expect(!offer.showsProSection)
        #expect(!offer.upsellsLongerRecording)
        #expect(offer.freeCapNotice(atCap: true) == .limit)
    }

    /// Off sale, the app does not ask the App Store for the products at all. The Debug
    /// test scheme carries a StoreKit configuration that defines both, so without the
    /// guard this load really would fill `products`.
    @Test func offSaleLoadRequestsNoProducts() async {
        let service = StoreService(autoStart: false)
        await service.loadProducts()
        #expect(service.products.isEmpty)
        #expect(service.loadError == nil)
    }

    // MARK: - When Pro is on sale

    @Test func onSaleWithProductsOffersProToAFreeUser() {
        let offer = ProOffer(gate: free, productsLoaded: true, onSale: true)
        #expect(offer.mayOpenPaywall)
        #expect(offer.showsProSection)
        #expect(offer.upsellsLongerRecording)
    }

    /// Even in the release that sells Pro, a paywall with nothing loaded on it is the
    /// dead end this type exists to remove.
    @Test func onSaleWithoutProductsIsStillNoPaywall() {
        let offer = ProOffer(gate: free, productsLoaded: false, onSale: true)
        #expect(!offer.mayOpenPaywall)
        #expect(!offer.showsProSection)
        #expect(!offer.upsellsLongerRecording)
    }

    // MARK: - Owners

    /// Someone who owns Pro keeps Restore Purchases and the way into personalisation
    /// whatever the build or the store says, and is never *upsold*. (Settings' Pro row
    /// still opens `ProPaywallView` for them: with Pro active it is their hub — status
    /// and themes — which is why that door is gated on `showsProSection`.)
    @Test func anOwnerKeepsTheProSectionWhenProIsNotOnSale() {
        let offer = ProOffer(gate: owner, productsLoaded: false, onSale: false)
        #expect(offer.showsProSection)
        #expect(!offer.mayOpenPaywall)
        #expect(!offer.upsellsLongerRecording)
    }

    @Test func anOwnerIsNeverUpsold() {
        let offer = ProOffer(gate: owner, productsLoaded: true, onSale: true)
        #expect(!offer.upsellsLongerRecording)
    }

    @Test func storeServiceKeepsTheProSectionForAnOwner() {
        let service = StoreService(autoStart: false)
        service.purchasedProductIDs = [StoreService.ProProduct.lifetime.rawValue]
        #expect(service.offer.showsProSection)
        #expect(!service.offer.mayOpenPaywall)
    }

    // MARK: - The 60-second cap

    /// Hiding the upsell must not hide the fact: a free recording that stops at 1:00
    /// still says why.
    @Test func aFreeRecordingAtTheCapIsToldWhyWhenProIsNotOnSale() {
        #expect(ProOffer(gate: free, productsLoaded: true).freeCapNotice(atCap: true) == .limit)
        #expect(ProOffer(gate: free, productsLoaded: false, onSale: true).freeCapNotice(atCap: true) == .limit)
    }

    @Test func aFreeRecordingAtTheCapIsOfferedFiveMinutesOnlyWhenOnSale() {
        #expect(ProOffer(gate: free, productsLoaded: true, onSale: true).freeCapNotice(atCap: true) == .upsell)
    }

    @Test func nothingIsSaidBeforeTheCapOrToAnOwner() {
        #expect(ProOffer(gate: free, productsLoaded: true, onSale: true).freeCapNotice(atCap: false) == .none)
        #expect(ProOffer(gate: owner, productsLoaded: true, onSale: true).freeCapNotice(atCap: true) == .none)
        #expect(ProOffer(gate: owner, productsLoaded: false).freeCapNotice(atCap: true) == .none)
    }

    // MARK: - Undo is never gated (M14 §4F)

    @Test func personalisationStaysReachableWhileThereIsAChoiceToUndo() {
        let offer = ProOffer(gate: free, productsLoaded: false, onSale: false)
        #expect(offer.showsPersonalisation(hasChoicesToUndo: true))
        #expect(!offer.showsPersonalisation(hasChoicesToUndo: false))
    }

    // MARK: - Every door to the paywall asks

    /// The views that can open a paywall, and nothing else. A new one fails here until
    /// someone decides it is gated — the unguarded `else` that shipped Export & share
    /// to every free user was one line in a view nobody was looking at for this.
    private static let paywallViews = [
        "Soundpost/Capture/CaptureView.swift",
        "Soundpost/Views/CapsuleDetailView.swift",
        "Soundpost/Views/PersonalisationSettingsView.swift",
        "Soundpost/Views/SettingsView.swift",
    ]

    @Test func onlyTheKnownViewsOpenAPaywall() throws {
        let root = Self.repoRoot()
        let appDir = root.appending(path: "Soundpost")
        let files = try #require(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        var openers: [String] = []
        var swiftFilesSeen = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            swiftFilesSeen += 1
            let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            if url.lastPathComponent != "ProPaywallView.swift", code.contains("ProPaywallView(") {
                openers.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        // A walk that found nothing would pass the comparison below by agreeing on
        // an empty world.
        #expect(swiftFilesSeen > 50, "the source walk found \(swiftFilesSeen) Swift files; it is not looking at the app")
        #expect(openers.sorted() == Self.paywallViews)
    }

    /// The predicates that may stand in front of a paywall door. Only these count:
    /// `store.offer.gate.isPro` contains "store.offer." and gates nothing to do with
    /// sale, and `showsPersonalisation` decides a link, not a paywall.
    private static let doorGuards = [
        "store.offer.mayOpenPaywall",
        "store.offer.upsellsLongerRecording",
        "store.offer.showsProSection",
        "store.offer.freeCapNotice(",
    ]

    /// Each of those views must evaluate one of `doorGuards` at least once per place it
    /// sets `showingPaywall = true`. It cannot tell *which* guard stands in front of
    /// *which* door — a view could check in one place and open the paywall in another,
    /// and an inverted predicate still counts — but it does fail when a guard is deleted
    /// or a door is added without one.
    @Test func everyPaywallDoorHasAnOfferCheck() throws {
        let root = Self.repoRoot()
        for path in Self.paywallViews {
            let url = root.appending(path: path)
            try #require(FileManager.default.fileExists(atPath: url.path), "\(path) has moved; this guard checks nothing")
            let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            let doors = code.components(separatedBy: "showingPaywall = true").count - 1
            let checks = Self.doorGuards.map { code.components(separatedBy: $0).count - 1 }.reduce(0, +)
            #expect(doors > 0, "\(path) no longer opens a paywall — update `paywallViews`")
            #expect(checks >= doors, "\(path): \(doors) way(s) into the paywall, \(checks) offer check(s)")
        }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundpostTests/
            .deletingLastPathComponent()   // repo root
    }

    /// Comments explain these gates at length and mention the very tokens being
    /// counted; only code may satisfy the guard.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
