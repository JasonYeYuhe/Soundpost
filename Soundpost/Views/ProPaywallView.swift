import SwiftUI
import StoreKit

/// The single, honest **Soundpost Pro** surface (M11 §4E/§4F).
///
/// Shown from the Pro entry point and from in-context gates (export, the
/// longer-clip affordance, a locked theme). It states plainly that Soundpost is
/// free and that nothing already made or received is ever locked, lists what Pro
/// adds, shows **lifetime + annual** with the required auto-renew / cancel
/// disclosure inline *before* the buy action (App Review 3.1.2), and offers a
/// discoverable **Restore Purchases**, **Manage Subscription**, and Terms /
/// Privacy links. No fake scarcity, no nags.
///
/// Reads `StoreService` from the environment; load / error states come straight
/// from the service (loading / load-failed-with-retry / buy disabled while
/// purchasing). In the ship-dormant state (no ASC products yet) `products` is
/// empty and this shows an honest "not available right now" — it is simply
/// unreachable in the UI until the entry point and gates exist to present it.
struct ProPaywallView: View {
    /// Optional one-line context shown under the header when opened from a
    /// specific gate (e.g. "Recording up to 5 minutes is a Pro feature").
    var context: LocalizedStringKey? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(StoreService.self) private var store
    @State private var purchaseError: String?
    /// The live card-theme preference (M11 §2B(c)) — same key `CapsuleCard`
    /// renders, so a selection applies immediately and persists across launches.
    @AppStorage("cardTheme") private var cardTheme: Theme = .classic
    @State private var showLockedThemeHint = false

    /// Apple's Standard EULA (Schedule 1) — the Terms of Use for the
    /// auto-renewable subscription (App Review 3.1.2(c)); no EULA page to author.
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://jasonyeyuhe.github.io/soundpost-site/privacy.html")!
    private let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private var ownsAnnual: Bool {
        store.purchasedProductIDs.contains(StoreService.ProProduct.annual.rawValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let context { contextNote(context) }
                    statusBadge
                    features
                    // The theme picker belongs to the hub entry, not the focused
                    // in-context gate presentations (export, longer clip).
                    if context == nil { themePicker }
                    pricing
                    restoreAndManage
                    legal
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Soundpost Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close")
                }
            }
            .alert("Purchase failed", isPresented: .constant(purchaseError != nil)) {
                Button("OK") { purchaseError = nil }
            } message: {
                Text(purchaseError ?? "")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Soundpost Pro")
                .font(.title.weight(.bold))
            Text("Soundpost is free — capture, seal, resurface, back up to iCloud, and receive every memory. Pro adds richer ways to make and share them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("It never locks a memory you've already made or received.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func contextNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if store.isPro {
            Label("Soundpost Pro is active — thank you.", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Features

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProFeatureRow(
                icon: "square.and.arrow.up",
                title: "Export & share your cards",
                subtitle: "Save a card as an image with its audio, and share it anywhere."
            )
            ProFeatureRow(
                icon: "timer",
                title: "Record up to 5 minutes",
                subtitle: "Go beyond the free 60-second clip when a moment needs longer."
            )
            ProFeatureRow(
                icon: "paintpalette",
                title: "A card theme pack",
                subtitle: "Alternate looks for your waveform cards, layered over each mood."
            )
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Pricing

    @ViewBuilder
    private var pricing: some View {
        if store.isPro {
            Text("You have Soundpost Pro. Thank you for supporting Soundpost.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if store.isLoading && store.products.isEmpty {
            ProgressView("Loading plans…")
                .padding(.vertical, 12)
        } else if store.products.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Plans aren't available right now.")
                    .font(.subheadline)
                Button("Try again") { Task { await store.loadProducts() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 12) {
                // Annual first (the lower-entry on-ramp), then the lifetime anchor.
                if let annual = store.annualProduct {
                    PricingCard(
                        product: annual,
                        sublabel: "Auto-renews yearly. Cancel anytime.",
                        pricePeriodSuffix: "/ year",
                        actionTitle: "Subscribe",
                        isPurchasing: store.isPurchasing,
                        onPurchase: { purchase(annual) }
                    )
                }
                if let lifetime = store.lifetimeProduct {
                    PricingCard(
                        product: lifetime,
                        sublabel: "One-time purchase. Yours to keep.",
                        pricePeriodSuffix: nil,
                        actionTitle: "Buy",
                        isPurchasing: store.isPurchasing,
                        onPurchase: { purchase(lifetime) }
                    )
                }
            }
        }
    }

    // MARK: - Restore / Manage

    private var restoreAndManage: some View {
        VStack(spacing: 10) {
            Button("Restore Purchases") { Task { await store.restorePurchases() } }
                .font(.subheadline)
                .accessibilityLabel("Restore purchases")

            if ownsAnnual {
                Button("Manage Subscription") { openURL(manageURL) }
                    .font(.subheadline)
                    .accessibilityLabel("Manage subscription")
            }
        }
    }

    // MARK: - Legal / disclosure

    private var legal: some View {
        VStack(spacing: 8) {
            // The auto-renew / cancel disclosure required for an auto-renewable
            // subscription (App Review 3.1.2), shown before any purchase.
            Text("The annual plan auto-renews each year until you cancel. Manage or cancel anytime in your App Store account settings, at least 24 hours before the renewal date. Payment is charged to your Apple Account at confirmation. Lifetime is a one-time purchase. Your existing and received memories are never locked.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Terms of Use", destination: termsURL)
                Link("Privacy Policy", destination: privacyURL)
            }
            .font(.caption2)
        }
    }

    // MARK: - Theme picker (hub entry only)

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Card theme").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Theme.allCases) { themeSwatch($0) }
                }
                .padding(.vertical, 2)
            }
            // Lapse-safe: choosing a locked theme never applies it; the applied
            // theme keeps rendering. Free users see how to unlock — the plans are
            // in this same surface (M11 §4D(iii)).
            if showLockedThemeHint {
                Text("Unlock the theme pack with Soundpost Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themeSwatch(_ theme: Theme) -> some View {
        let isSelected = cardTheme == theme
        let locked = !store.gate.canUse(theme)
        let swatchTint = Color.accentColor
        let barHeights: [CGFloat] = [14, 22, 10]
        return Button {
            if locked {
                showLockedThemeHint = true
            } else {
                cardTheme = theme
                showLockedThemeHint = false
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(theme.baseFill)
                    RoundedRectangle(cornerRadius: 12).fill(swatchTint.opacity(theme.tintWashOpacity))
                    HStack(spacing: 3) {
                        ForEach(barHeights.indices, id: \.self) { i in
                            // SwiftUI's Capsule shape — the app's `Capsule` model shadows it.
                            SwiftUI.Capsule().fill(swatchTint).frame(width: 4, height: barHeights[i])
                        }
                    }
                }
                .frame(width: 64, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.accentColor : theme.strokeColor(tint: swatchTint),
                                lineWidth: isSelected ? 2 : theme.strokeWidth)
                )
                .overlay(alignment: .topTrailing) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .padding(3)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(3)
                    }
                }
                .opacity(locked ? 0.7 : 1)
                Text(theme.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.label))
        .accessibilityValue(locked ? Text("Locked") : (isSelected ? Text("Selected") : Text("")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func purchase(_ product: Product) {
        Task {
            do {
                let success = try await store.purchase(product)
                if success { dismiss() }
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }
}

// MARK: - Components

private struct ProFeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A vertical pricing card (Dynamic-Type-safe: nothing relies on a fixed-width
/// horizontal row that could clip the price or disclosure at accessibility
/// sizes). Shows the localized `displayName` + `displayPrice` from StoreKit, the
/// per-plan disclosure, then a full-width buy button.
private struct PricingCard: View {
    let product: Product
    let sublabel: LocalizedStringKey
    /// e.g. "/ year" for the annual; nil for the one-time lifetime.
    let pricePeriodSuffix: LocalizedStringKey?
    let actionTitle: LocalizedStringKey
    let isPurchasing: Bool
    let onPurchase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(product.displayName)
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(product.displayPrice)
                    .font(.title3.weight(.bold))
                if let pricePeriodSuffix {
                    Text(pricePeriodSuffix)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(sublabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onPurchase) {
                Group {
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Text(actionTitle).fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPurchasing)
            .accessibilityLabel(Text(actionTitle) + Text(" ") + Text(product.displayName))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ProPaywallView()
        .environment(StoreService(autoStart: false))
}
