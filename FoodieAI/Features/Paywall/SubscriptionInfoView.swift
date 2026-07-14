import SwiftUI

/// Phase 22 — comparison page between Free and Pro.
///
/// This sheet is *marketing-only* — it doesn't touch StoreKit. Purchase
/// happens in `PaywallView`, which this view presents from its
/// "Continue to Upgrade" button. Keeping the two screens separate
/// means the comparison can be opened anywhere we want to explain
/// what Pro buys you without immediately throwing a purchase sheet
/// in the user's face.
///
/// For pro users (opened from Profile → Manage), the layout flips to
/// a status summary with a link to iOS Settings → Subscriptions for
/// cancellation / billing management — Apple's required path.
///
/// Honest copy: the only feature gated by tier in v1 is the daily AI
/// scan cap (2/day free, 4/day in the first week; Pro is unlimited).
/// The comparison table reflects exactly that. No invented perks.
/// (Server keeps a silent abuse cap on Pro that users never see.)
struct SubscriptionInfoView: View {
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingPaywall = false

    private static let manageSubscriptionsURL =
        URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    header
                    if subscriptions.tier == .pro {
                        proStatusBlock
                    } else {
                        comparisonTable
                        whyProBlock
                    }
                    actionRow
                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl2)
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
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .environmentObject(subscriptions)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            TierBadge(tier: subscriptions.tier)
            Text("FoodieAI Pro")
                .appFont(.display1)
                .foregroundStyle(Color.ink)
            Text(headerSubtitle)
                .appFont(.bodyLG)
                .foregroundStyle(Color.inkMute)
        }
    }

    private var headerSubtitle: String {
        subscriptions.tier == .pro
            ? "You're on Pro. Thanks for supporting us."
            : "More scans for the days you snap every meal."
    }

    // MARK: - Free → Pro comparison

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            comparisonHeaderRow
            comparisonRow(
                label: "Photo scans per day",
                free: "2  (4 for your first week)",
                pro: "Unlimited"
            )
            comparisonRow(
                label: "Manual logging",
                free: "Unlimited",
                pro: "Unlimited"
            )
            comparisonRow(
                label: "FoodOS, story, recap",
                free: "Included",
                pro: "Included"
            )
            comparisonRow(
                label: "Cancel anytime",
                free: "-",
                pro: "Yes"
            )
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("FREE")
                .appFont(.labelEyebrow)
                .foregroundStyle(Color.inkMute)
                .frame(width: 110, alignment: .center)
            Text("PRO")
                .appFont(.labelEyebrow)
                .foregroundStyle(Color.brandDeep)
                .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
    }

    private func comparisonRow(label: String, free: String, pro: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(free)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .frame(width: 110, alignment: .center)
            Text(pro)
                .appFont(.captionStrong)
                .foregroundStyle(Color.brandDeep)
                .multilineTextAlignment(.center)
                .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.borderHairline)
                .frame(height: 1)
        }
    }

    // MARK: - Honest framing

    private var whyProBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Most people never hit the free limit.")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            Text("Pro is for the days you scan every meal, you get unlimited photo scans so you can keep going without rationing photos. The rest of the app (insights, recaps, FoodOS) is the same.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft.opacity(0.6))
        )
    }

    // MARK: - Pro status

    private var proStatusBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            statusRow(label: "Plan", value: "Pro")
            // Pro reads as unlimited — never expose the silent safety cap
            // as "X of N". Gate on tier, not just the server `isUnlimited`
            // flag: this block only renders for Pro, and a Pro response that
            // omits the flag must still read "Unlimited" (the flag defaults
            // false), never the count.
            statusRow(label: "Today",
                      value: (subscriptions.isUnlimited || subscriptions.tier == .pro)
                          ? "Unlimited"
                          : "\(subscriptions.scansUsedToday) of \(subscriptions.dailyLimit) scans")
            if let expiry = subscriptions.proExpiresAt {
                statusRow(label: "Renews", value: Self.expiryFormatter.string(from: expiry))
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.inkMute)
            Spacer()
            Text(value)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.ink)
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        switch subscriptions.tier {
        case .free:
            PrimaryButton(title: "Continue to Upgrade",
                          leadingSystemImage: "crown.fill") {
                showingPaywall = true
            }
        case .pro:
            VStack(spacing: AppSpacing.md) {
                Link(destination: Self.manageSubscriptionsURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 16, weight: .heavy))
                        Text("Manage in Settings")
                            .appFont(.title2)
                    }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(
                        Capsule().stroke(Color.ink, lineWidth: 1.5)
                    )
                }
                Text("Cancel or change your plan in Settings → Apple ID → Subscriptions.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#if DEBUG
#Preview("Free") {
    SubscriptionInfoView()
        .environmentObject(SubscriptionManager.shared)
}
#endif
