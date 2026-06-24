import Testing
import Foundation
@testable import Soundpost

/// Tests the testable parts of `StoreService`: the `ProProduct` enum and the
/// on-device entitlement (`isPro` / `gate`) derived from `purchasedProductIDs`.
/// The actual StoreKit calls (`Product.products`, `Transaction.*`) need a real
/// StoreKit configuration and are exercised in the §S6 manual StoreKit-testing
/// pass. Constructed with `autoStart: false` so no StoreKit network client opens.
@MainActor
struct StoreServiceTests {

    // MARK: - ProProduct enum

    @Test func soundpostSellsExactlyTwoProducts() {
        // Lifetime + annual only — no monthly (M11 §1.4).
        #expect(StoreService.ProProduct.allCases.count == 2)
    }

    @Test func annualProductID() {
        #expect(StoreService.ProProduct.annual.rawValue == "com.soundpost.Soundpost.pro.annual")
    }

    @Test func lifetimeProductID() {
        #expect(StoreService.ProProduct.lifetime.rawValue == "com.soundpost.Soundpost.pro.lifetime")
    }

    @Test func productIDsAreDistinct() {
        let ids = StoreService.ProProduct.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
    }

    @Test func noMonthlyProductExists() {
        let ids = StoreService.ProProduct.allCases.map(\.rawValue)
        #expect(!ids.contains { $0.contains("monthly") })
    }

    // MARK: - Entitlement (isPro / gate)

    @Test func isProFalseWhenNothingPurchased() {
        let service = StoreService(autoStart: false)
        service.purchasedProductIDs = []
        #expect(service.isPro == false)
        #expect(service.gate == ProGate(isPro: false))
    }

    @Test func isProTrueWithLifetime() {
        let service = StoreService(autoStart: false)
        service.purchasedProductIDs = [StoreService.ProProduct.lifetime.rawValue]
        #expect(service.isPro == true)
        #expect(service.gate == ProGate(isPro: true))
    }

    @Test func isProTrueWithAnnual() {
        let service = StoreService(autoStart: false)
        service.purchasedProductIDs = [StoreService.ProProduct.annual.rawValue]
        #expect(service.isPro == true)
        #expect(service.gate == ProGate(isPro: true))
    }

    /// Dropping the annual's product ID (a lapse / refund seen via
    /// `currentEntitlements`) flips `isPro` back to false — the only thing that
    /// gates is the *start* of a new Pro action (M11 §4D).
    @Test func losingTheEntitlementDropsIsProToFalse() {
        let service = StoreService(autoStart: false)
        service.purchasedProductIDs = [StoreService.ProProduct.annual.rawValue]
        #expect(service.isPro == true)
        service.purchasedProductIDs = []           // annual lapsed / refunded
        #expect(service.isPro == false)
    }
}
