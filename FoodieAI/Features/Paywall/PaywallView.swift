import SwiftUI
import StoreKit

/// Phase 23 — trial-led Pro paywall (annual-first with a 3-day free trial).
///
/// Design follows the high-MRR calorie-app playbook: lead with the free
/// trial, make the annual plan the default selection, show a concrete
/// "what happens when" trial timeline, and keep one prominent CTA. When no
/// intro offer is configured (or the user already used their trial), it
/// degrades gracefully to a plain annual-first paywall.
///
/// Apple's App Review checklist for IAP paywalls (all still satisfied):
///   • Value prop in plain language
///   • Both products with price + period, prices pulled from StoreKit
///   • Period label ("month" / "year") clearly visible
///   • Annual marked as best value
///   • Free-trial terms + auto-renewal disclosure (standard Apple language)
///   • Restore Purchases (functional)
///   • Privacy Policy + Terms of Use links
///
/// Prices are NEVER hardcoded — we render `product.displayPrice`, which
/// reflects the storefront's currency.
struct PaywallView: View {
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    /// Phase 24. When non-nil, the paywall is embedded as the onboarding offer
    /// step rather than a sheet. There is no sheet to dismiss, so the close
    /// control, the secondary "Continue with Free" button, AND a completed
    /// purchase all call this to advance the flow. Nil = normal sheet
    /// presentation (post-onboarding in-app upsells).
    var onFinish: (() -> Void)? = nil

    /// Tags the `paywall_viewed` event so onboarding-offer exposure is
    /// separable in analytics from post-onboarding in-app upsells. Defaults to
    /// the in-app surfaces; onboarding passes "onboarding".
    var analyticsContext: String = "in_app"

    /// Onboarding-only. A one-line callback to the plan the user just saw on
    /// the reveal (e.g. "On track to hit your goal weight by November 2026"),
    /// shown as a banner above the header so the offer reads as the next step
    /// toward THEIR goal, not a generic sales page. Nil for in-app upsells and
    /// for users who skipped physiology (header then stays generic).
    var planCallback: String? = nil

    /// Which plan the user has selected (radio). Defaults to yearly once
    /// products load.
    @State private var selectedProductID: String?
    /// Non-nil while a purchase is in flight (drives the CTA spinner state).
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
                    if let planCallback { planCallbackBanner(planCallback) }
                    header
                    if showTrialForSelection { trialTimeline }
                    valueProps
                    planSelector
                    VStack(spacing: AppSpacing.sm) {
                        primaryCTA
                        Text(ctaSubcopy)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    legalDisclosure
                    actionsRow
                    if onFinish != nil { continueWithFreeButton }
                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(Color.bgCanvas)

            Button {
                Haptics.tap()
                if let onFinish { onFinish() } else { dismiss() }
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
            AnalyticsService.shared.track(AnalyticsService.Event.paywallViewed,
                                          ["context": analyticsContext])
            // Subscriptions bootstrap happens at app launch, but a cold
            // re-open of the paywall still benefits from a fresh product
            // fetch + eligibility check — StoreKit may have lost the cache.
            if subscriptions.products.isEmpty {
                await subscriptions.bootstrap()
            } else {
                await subscriptions.refreshTrialEligibility()
            }
            if selectedProductID == nil {
                selectedProductID = subscriptions.yearlyProduct?.id
                    ?? subscriptions.monthlyProduct?.id
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
            // In onboarding a completed purchase advances the flow (no sheet to
            // close); as an in-app sheet it dismisses back to where it opened.
            if completed {
                if let onFinish { onFinish() } else { dismiss() }
            }
        }
    }

    // MARK: - Plan callback

    /// A quiet, brand-tinted banner that echoes the plan reveal the user just
    /// saw, so the paywall reads as "here's how to hit the goal you just set"
    /// rather than a cold upsell. Rendered only when `planCallback` is non-nil.
    private func planCallbackBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "target")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.brandDeep)
            Text(text)
                .appFont(.captionStrong)
                .foregroundStyle(Color.brandDeep)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.brandSoft)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(headerTitle)
                .appFont(.display1)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(headerSubtitle)
                .appFont(.bodyLG)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerTitle: String {
        showTrialForSelection ? "Try Pro, free for \(trialPhrase)" : "FoodieAI Pro"
    }

    private var headerSubtitle: String {
        showTrialForSelection
            ? "Full access now, we'll remind you before your trial ends."
            : "More scans. Same coach. Whole day covered."
    }

    // MARK: - Trial timeline

    private var trialTimeline: some View {
        VStack(spacing: AppSpacing.md) {
            timelineRow(icon: "lock.open.fill", day: "Today",
                        title: "Full access unlocked",
                        detail: "Unlimited scans and everything in Pro.")
            timelineRow(icon: "bell.fill", day: "Day \(max(1, trialDays - 1))",
                        title: "Trial reminder",
                        detail: "A heads-up before your free trial ends.")
            timelineRow(icon: "checkmark.seal.fill", day: "Day \(trialDays)",
                        title: "Your plan begins",
                        detail: "\(subscriptions.yearlyProduct?.displayPrice ?? "")/year, cancel anytime before.")
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.3), lineWidth: 1)
        )
    }

    private func timelineRow(icon: String, day: String,
                             title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle().fill(Color.brandSoft).frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.brandDeep)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(day)
                    .appFont(.labelEyebrow)
                    .foregroundStyle(Color.brandDeep)
                Text(title)
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                Text(detail)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Value props

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            valueRow(icon: "camera.fill",
                     title: "Log every meal, no rationing",
                     detail: "Two scans a day doesn't cover breakfast, lunch, and dinner. Pro lets you snap all of it, plus the snacks and drinks that quietly add up.")
            valueRow(icon: "chart.line.uptrend.xyaxis",
                     title: "Totals you can actually trust",
                     detail: "When every meal is logged, your calories and macros reflect your real day, not a half-tracked one. That's the difference between guessing and knowing.")
            valueRow(icon: "sparkles",
                     title: "A coach that sees your whole day",
                     detail: "Your coach can only speak to what you log. Give it the full picture and its nudges and recaps get sharper.")
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

    // MARK: - Plan selector

    private var planSelector: some View {
        VStack(spacing: AppSpacing.md) {
            if subscriptions.products.isEmpty {
                loadingProducts
            } else {
                if let yearly = subscriptions.yearlyProduct {
                    planRow(product: yearly, periodLabel: "year")
                }
                if let monthly = subscriptions.monthlyProduct {
                    planRow(product: monthly, periodLabel: "month")
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

    private func planRow(product: Product, periodLabel: String) -> some View {
        let selected = selectedProduct?.id == product.id
        let isYearly = product.id == SubscriptionManager.yearlyProductID
        let showTrialBadge = isYearly && subscriptions.offersYearlyFreeTrial

        return Button {
            Haptics.selection()
            selectedProductID = product.id
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selected ? Color.brand : Color.borderHairline)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: AppSpacing.sm) {
                        Text(isYearly ? "Yearly" : "Monthly")
                            .appFont(.title1)
                            .foregroundStyle(Color.ink)
                        if showTrialBadge {
                            badge("\(trialAdjective.uppercased()) FREE TRIAL")
                        } else if isYearly {
                            badge("BEST VALUE")
                        }
                    }
                    Text(planSubcopy(product: product, isYearly: isYearly, showTrial: showTrialBadge))
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
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(selected ? Color.brandSoft.opacity(0.6) : Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(selected ? Color.brand : Color.borderHairline,
                            lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(purchasingProductID != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .appFont(.labelEyebrow)
            .foregroundStyle(Color.brandDeep)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.brandSoft))
    }

    private func planSubcopy(product: Product, isYearly: Bool, showTrial: Bool) -> String {
        if showTrial { return "Free for \(trialPhrase), then billed yearly" }
        if isYearly {
            return savingsCopy(for: product, periodLabel: "year",
                               comparedToMonthly: subscriptions.monthlyProduct)
                ?? "Auto-renews yearly"
        }
        return "Auto-renews monthly"
    }

    // MARK: - Primary CTA

    private var primaryCTA: some View {
        PrimaryButton(title: ctaTitle,
                      isDisabled: selectedProduct == nil || purchasingProductID != nil) {
            if let product = selectedProduct {
                Task { await buy(product: product) }
            }
        }
    }

    private var ctaTitle: String {
        if purchasingProductID != nil { return "Starting…" }
        if showTrialForSelection { return "Start my \(trialAdjective) free trial" }
        return "Subscribe"
    }

    private var ctaSubcopy: String {
        guard let product = selectedProduct else { return "" }
        let period = selectedIsYearly ? "year" : "month"
        if showTrialForSelection {
            return "First \(trialPhrase) free, then \(product.displayPrice)/\(period). Cancel anytime."
        }
        return "\(product.displayPrice)/\(period). Cancel anytime."
    }

    // MARK: - Legal

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

    /// Onboarding-only escape hatch. Deliberately a quiet text link, NOT a
    /// full-width bordered button: the old co-equal button gave the exit the
    /// same visual weight as the buy CTA, which suppressed trial starts. The
    /// offer still never hard-blocks (this link + the top-right X both call
    /// `onFinish`), the free path is just no longer competing with the trial
    /// for the eye.
    private var continueWithFreeButton: some View {
        Button {
            Haptics.tap()
            onFinish?()
        } label: {
            Text("Not now, I'll use the free plan")
                .appFont(.captionStrong)
                .foregroundStyle(Color.inkMute)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue with the free plan")
    }

    // MARK: - Derived selection state

    private var selectedProduct: Product? {
        if let id = selectedProductID,
           let match = subscriptions.products.first(where: { $0.id == id }) {
            return match
        }
        return subscriptions.yearlyProduct ?? subscriptions.monthlyProduct
    }

    private var selectedIsYearly: Bool {
        selectedProduct?.id == SubscriptionManager.yearlyProductID
    }

    /// Trial UI shows only when the yearly plan is selected AND the user is
    /// eligible for the free trial (offer exists + not yet used).
    private var showTrialForSelection: Bool {
        selectedIsYearly && subscriptions.offersYearlyFreeTrial
    }

    /// "3 days" style noun phrase; "" when no offer.
    private var trialPhrase: String {
        subscriptions.yearlyIntroOffer.map { SubscriptionManager.trialLengthPhrase($0) } ?? ""
    }

    /// "3-day" style adjective; "" when no offer.
    private var trialAdjective: String {
        subscriptions.yearlyIntroOffer.map { SubscriptionManager.trialDurationText($0) } ?? ""
    }

    private var trialDays: Int {
        subscriptions.yearlyIntroOffer.map { SubscriptionManager.trialDayCount($0) } ?? 3
    }

    // MARK: - Copy helpers

    private var autoRenewalDisclosure: String {
        let base = "Subscription auto-renews unless cancelled at least 24 hours before the end of the current period. Your Apple ID is charged for renewal within 24 hours prior to the end of each period. Manage or cancel anytime in Settings → Apple ID → Subscriptions."
        if showTrialForSelection {
            return "Your \(trialAdjective) free trial automatically converts to a paid subscription unless cancelled at least 24 hours before it ends. " + base
        }
        return base
    }

    /// "Save XX% vs monthly" when yearly is cheaper than 12 × monthly.
    /// Returns nil for monthly or when the math doesn't favor yearly.
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
        // Funnel sensor: fire the instant they commit, before StoreKit opens.
        // This is the step that was invisible between paywall_viewed and a
        // fully-validated trial_started, so a "0 trials" day is now diagnosable.
        AnalyticsService.shared.track(AnalyticsService.Event.checkoutStarted,
                                      ["product": product.id, "context": analyticsContext])
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        let outcome = await subscriptions.purchase(product)
        switch outcome {
        case .success:
            // Revenue events (trial_started / pro_purchased) fire inside purchase().
            didCompletePurchase = true
        case .userCancelled:
            AnalyticsService.shared.track(AnalyticsService.Event.checkoutAbandoned,
                                          ["product": product.id, "context": analyticsContext])
        case .pending:
            AnalyticsService.shared.track(AnalyticsService.Event.checkoutPending,
                                          ["product": product.id, "context": analyticsContext])
            bannerError = "Your purchase is pending approval. We'll unlock Pro when it's approved."
        case .failed(let message):
            AnalyticsService.shared.track(AnalyticsService.Event.checkoutFailed,
                                          ["product": product.id, "reason": message,
                                           "context": analyticsContext])
            bannerError = message
        case .validationFailed(let message):
            AnalyticsService.shared.track(AnalyticsService.Event.validationFailed,
                                          ["product": product.id, "context": analyticsContext])
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
