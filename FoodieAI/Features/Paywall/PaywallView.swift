import SwiftUI
import StoreKit

/// Phase 22 — Pro subscription paywall.
///
/// Apple's App Review checklist for IAP-driven paywalls (all required;
/// missing any of these is a near-certain rejection):
///   • Value prop in plain language
///   • Both products with price + period, prices pulled from StoreKit
///   • Period label ("month" / "year") clearly visible
///   • Annual marked as best value
///   • Restore Purchases (functional, not just present)
///   • Auto-renewal disclosure text (the standard Apple language)
///   • Privacy Policy + Terms of Use links
///
/// Prices are NEVER hardcoded — we render `product.displayPrice`, which
/// reflects the storefront's currency. Even if all our App Store Connect
/// prices are USD, this means a regional storefront still gets formatted
/// money instead of a US-dollar literal.
struct PaywallView: View {
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, identifies which product the user tapped — drives
    /// the inline progress + disables the other purchase button.
    @State private var purchasingProductID: String?
    @State private var isRestoring: Bool = false
    @State private var bannerError: String?
    @State private var didCompletePurchase: Bool = false

    private static let termsURL   = URL(string: "https://thefoodieai.com/terms")!
    private static let privacyURL = URL(string: "https://thefoodieai.com/privacy")!

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    header
                    valueProps
                    productOptions
                    legalDisclosure
                    actionsRow
                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(Color.bgCanvas)

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.bgSurface))
                    .appShadow(.shadowCard)
            }
            .padding(.top, AppSpacing.md)
            .padding(.trailing, AppSpacing.md)
            .accessibilityLabel("Close")
        }
        .task {
            // Subscriptions bootstrap happens at app launch, but a cold
            // re-open of the paywall still benefits from a fresh
            // product fetch — StoreKit may have lost the cache.
            if subscriptions.products.isEmpty {
                await subscriptions.bootstrap()
            }
        }
        .alert("Purchase Error",
               isPresented: Binding(
                get: { bannerError != nil },
                set: { if !$0 { bannerError = nil } }
               ),
               actions: {
                   Button("OK", role: .cancel) { bannerError = nil }
               },
               message: {
                   Text(bannerError ?? "")
               })
        .onChange(of: didCompletePurchase) { _, completed in
            if completed { dismiss() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("FoodieAI Pro")
                .appFont(.display1)
                .foregroundStyle(Color.ink)
            Text("More scans. Same coach. Whole day covered.")
                .appFont(.bodyLG)
                .foregroundStyle(Color.inkMute)
        }
    }

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            valueRow(icon: "camera.fill",
                     title: "Unlimited photo scans",
                     detail: "Snap every meal without rationing your scans.")
            valueRow(icon: "sparkles",
                     title: "Smarter coach moments",
                     detail: "FoodOS, story, and recap stay free for everyone — Pro just removes the cap.")
            valueRow(icon: "clock.arrow.circlepath",
                     title: "Cancel anytime",
                     detail: "Manage from Settings → Apple ID → Subscriptions.")
        }
    }

    private func valueRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                Text(detail)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
            }
        }
    }

    private var productOptions: some View {
        VStack(spacing: AppSpacing.md) {
            if subscriptions.products.isEmpty {
                loadingProducts
            } else {
                if let yearly = subscriptions.yearlyProduct {
                    productCard(product: yearly,
                                periodLabel: "year",
                                badge: "Best value",
                                comparedTo: subscriptions.monthlyProduct)
                }
                if let monthly = subscriptions.monthlyProduct {
                    productCard(product: monthly,
                                periodLabel: "month",
                                badge: nil,
                                comparedTo: nil)
                }
            }
        }
    }

    private var loadingProducts: some View {
        HStack {
            ProgressView()
            Text("Loading prices…")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, AppSpacing.xl)
    }

    @ViewBuilder
    private func productCard(product: Product,
                             periodLabel: String,
                             badge: String?,
                             comparedTo monthly: Product?) -> some View {
        let isPurchasing = purchasingProductID == product.id
        let otherPurchasing = (purchasingProductID != nil) && !isPurchasing

        Button {
            Task { await buy(product: product) }
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: AppSpacing.sm) {
                        Text(product.displayName.isEmpty
                                ? defaultDisplayName(periodLabel: periodLabel)
                                : product.displayName)
                            .appFont(.title1)
                            .foregroundStyle(Color.ink)
                        if let badge {
                            Text(badge.uppercased())
                                .appFont(.labelEyebrow)
                                .foregroundStyle(Color.brandDeep)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(Color.brandSoft)
                                )
                        }
                    }
                    Text(savingsCopy(for: product, periodLabel: periodLabel, comparedToMonthly: monthly)
                            ?? "Auto-renews until cancelled")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .appFont(.title1)
                        .foregroundStyle(Color.ink)
                    Text("/ \(periodLabel)")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(badge != nil ? Color.brand : Color.borderHairline,
                            lineWidth: badge != nil ? 2 : 1)
            )
            .opacity(otherPurchasing ? 0.5 : 1.0)
            .overlay(alignment: .center) {
                if isPurchasing { ProgressView().tint(Color.ink) }
            }
        }
        .buttonStyle(.plain)
        .disabled(purchasingProductID != nil)
    }

    private var legalDisclosure: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(autoRenewalDisclosure)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
            HStack(spacing: AppSpacing.md) {
                Link("Terms of Use", destination: Self.termsURL)
                    .font(AppFont.font(.captionStrong))
                    .foregroundStyle(Color.ink)
                Link("Privacy Policy", destination: Self.privacyURL)
                    .font(AppFont.font(.captionStrong))
                    .foregroundStyle(Color.ink)
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                Task { await restore() }
            } label: {
                HStack(spacing: 8) {
                    if isRestoring { ProgressView().controlSize(.small) }
                    Text(isRestoring ? "Restoring…" : "Restore Purchases")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule().stroke(Color.borderHairline, lineWidth: 1)
                )
            }
            .disabled(isRestoring)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Copy helpers

    private var autoRenewalDisclosure: String {
        """
        Subscription auto-renews unless cancelled at least 24 hours before the end of the current period. Your Apple ID is charged for renewal within 24 hours prior to the end of each period. Manage or cancel anytime in Settings → Apple ID → Subscriptions.
        """
    }

    private func defaultDisplayName(periodLabel: String) -> String {
        "Pro · \(periodLabel)ly"
    }

    /// Compute a "Save XX% vs monthly" string when the yearly is cheaper
    /// than 12 × monthly. Returns nil for the monthly card or when
    /// the math doesn't favor yearly (shouldn't happen with our pricing
    /// but we don't want to ship a lie).
    private func savingsCopy(for product: Product,
                             periodLabel: String,
                             comparedToMonthly monthly: Product?) -> String? {
        guard periodLabel == "year",
              let monthly,
              monthly.price > 0 else { return nil }
        let twelveMonths = monthly.price * 12
        guard twelveMonths > product.price else { return nil }
        let savedFraction = NSDecimalNumber(decimal: (twelveMonths - product.price) / twelveMonths).doubleValue
        let pct = Int((savedFraction * 100).rounded())
        guard pct > 0 else { return nil }
        return "Save \(pct)% vs monthly"
    }

    // MARK: - Actions

    private func buy(product: Product) async {
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        let outcome = await subscriptions.purchase(product)
        switch outcome {
        case .success:
            didCompletePurchase = true
        case .userCancelled:
            break
        case .pending:
            bannerError = "Your purchase is pending approval. We'll unlock Pro when it's approved."
        case .failed(let message):
            bannerError = message
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        await subscriptions.restorePurchases()
        if subscriptions.tier == .pro {
            didCompletePurchase = true
        }
    }
}

#if DEBUG
#Preview("Paywall") {
    PaywallView()
        .environmentObject(SubscriptionManager.shared)
}
#endif
