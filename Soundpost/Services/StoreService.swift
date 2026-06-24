import Foundation
import StoreKit
import OSLog

private let logger = Logger(subsystem: "com.soundpost.Soundpost", category: "Store")

/// StoreKit 2 entitlement service for **Soundpost Pro**.
///
/// On-device only — `isPro` derives solely from `Transaction.currentEntitlements`.
/// There is **no backend entitlement check, no receipt server, and no App Store
/// Server Notifications**, because nothing server-side is gated (M11 §2A/§4A):
/// cloud-backed delivery, sealing, resurfacing, and playback all stay free. If a
/// future milestone ever gates a *server* feature behind Pro, server validation +
/// ASSN v2 come back — not now.
///
/// Pattern ported from Kinen's `StoreService` (production-tested, itself from
/// Stride), dropping the monthly plan: Soundpost sells **lifetime + annual only**.
@Observable
@MainActor
final class StoreService {
    /// The two Soundpost Pro products. Lifetime is a non-consumable ("pay once,
    /// keep forever"); annual is an auto-renewable subscription in the
    /// "Soundpost Pro" group. Both confer the **same** Pro entitlement and simply
    /// flip the same `isPro` flag (M11 §1.4) — there is no per-plan feature gate.
    enum ProProduct: String, CaseIterable {
        case annual = "com.soundpost.Soundpost.pro.annual"
        case lifetime = "com.soundpost.Soundpost.pro.lifetime"
    }

    /// Loaded `Product`s (empty until `loadProducts()` resolves, or forever in the
    /// ship-dormant state where no ASC products exist yet — M11 §0).
    var products: [Product] = []
    /// Product IDs the user currently owns, recomputed from
    /// `Transaction.currentEntitlements`.
    var purchasedProductIDs: Set<String> = []
    var isLoading = false
    var loadError: String?
    var isPurchasing = false
    private var loadAttempts = 0
    private var transactionListener: Task<Void, Never>?

    /// On-device entitlement: Pro the moment ANY Soundpost Pro product is owned.
    /// A lapsed annual (or a refund) drops its ID here, flipping `isPro` to false —
    /// which only gates *starting* a new Pro action. It never revokes already-made
    /// content; that lapse-safety is structural and lives in `ProGate` (M11 §4D),
    /// never as an `isPro` re-check over stored capsules.
    var isPro: Bool { !purchasedProductIDs.isEmpty }

    /// The entitlement→features seam every view should read instead of `isPro`
    /// (M11 §4C), so gating rules stay in one audited, unit-tested place.
    var gate: ProGate { ProGate(isPro: isPro) }

    /// The annual subscription product, if loaded — the only one that needs the
    /// auto-renew disclosure (App Review 3.1.2).
    var annualProduct: Product? {
        products.first { $0.id == ProProduct.annual.rawValue }
    }

    /// The lifetime non-consumable, if loaded.
    var lifetimeProduct: Product? {
        products.first { $0.id == ProProduct.lifetime.rawValue }
    }

    /// `autoStart: false` (used by tests) skips the network product load and the
    /// `Transaction.updates` listener, so the unit-test runner opens no StoreKit
    /// network client — mirroring the "SentryBootstrap skipped under tests"
    /// discipline in `SoundpostApp`.
    init(autoStart: Bool = true) {
        guard autoStart else { return }
        startTransactionListener()
        Task { await loadProducts() }
        Task { await refreshPurchasedProducts() }
    }

    // MARK: - Load products

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil

        do {
            let ids = ProProduct.allCases.map(\.rawValue)
            // Annual first, lifetime second (ascending price), so the paywall can
            // show the lower-entry on-ramp before the "keep forever" anchor.
            products = try await Product.products(for: ids).sorted { $0.price < $1.price }
            loadError = nil
            loadAttempts = 0
            logger.info("Loaded \(self.products.count) products")
        } catch is CancellationError {
            // Don't retry on cancellation.
        } catch {
            loadAttempts += 1
            loadError = error.localizedDescription
            logger.error("Failed to load products (attempt \(self.loadAttempts)): \(error)")

            // Exponential backoff retry (max 5 attempts).
            if loadAttempts < 5 {
                let delay = pow(2.0, Double(loadAttempts))
                try? await Task.sleep(for: .seconds(delay))
                await loadProducts()
            }
        }

        isLoading = false
    }

    // MARK: - Purchase

    /// Returns `true` only when a verified transaction was finished and the
    /// entitlement refreshed. User-cancelled / pending (Ask-to-Buy) / unverified
    /// all return `false` without changing `isPro`.
    func purchase(_ product: Product) async throws -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            if let transaction = checkVerified(verification) {
                await transaction.finish()
                await refreshPurchasedProducts()
                logger.info("Purchase successful: \(product.id)")
                return true
            }
            return false
        case .userCancelled:
            return false
        case .pending:
            // Ask-to-Buy / SCA: the entitlement (if approved) arrives later via
            // the `Transaction.updates` listener.
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshPurchasedProducts()
            logger.info("Purchases restored")
        } catch {
            logger.error("Restore failed: \(error)")
        }
    }

    // MARK: - Transaction verification

    private func checkVerified<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let safe): return safe
        case .unverified: return nil
        }
    }

    // MARK: - Refresh entitlements

    /// Recompute `purchasedProductIDs` from the source of truth. Called at launch,
    /// after a purchase/restore, and on every `Transaction.updates` event
    /// (renewals, Ask-to-Buy approvals, refunds, Family Sharing changes).
    func refreshPurchasedProducts() async {
        var purchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if let transaction = checkVerified(result) {
                purchased.insert(transaction.productID)
            }
        }
        purchasedProductIDs = purchased
    }

    // MARK: - Transaction listener

    private func startTransactionListener() {
        // `[weak self]` avoids a retain cycle; after the service is gone the loop
        // simply no-ops. The service lives for the app's lifetime in practice.
        transactionListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if let transaction = await self.checkVerified(result) {
                    await transaction.finish()
                    await self.refreshPurchasedProducts()
                }
            }
        }
    }
}
