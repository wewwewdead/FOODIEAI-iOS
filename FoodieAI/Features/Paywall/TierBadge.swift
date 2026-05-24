import SwiftUI

/// Phase 22 — tier indicator for Profile (and anywhere else we want to
/// show the user what plan they're on).
///
/// Two visual states keyed on `SubscriptionManager.Tier`:
///   • `.free` — quiet capsule, neutral palette, no motion. The point
///     of free is that it's invisible until contrasted against pro;
///     the badge confirms tier without nagging.
///   • `.pro` — gold gradient capsule with an animated diagonal shine
///     sweep every ~2.2s. Respects `accessibilityReduceMotion` — when
///     ON the badge renders the static gradient with no animation.
///
/// Rendering is pure SwiftUI: the gold gradient is built from literal
/// `Color(red:green:blue:)` values (the design system doesn't have a
/// canonical gold token yet). If a brand-aligned premium palette is
/// added later, swap the three stops without touching the geometry.
struct TierBadge: View {
    let tier: SubscriptionManager.Tier

    var body: some View {
        switch tier {
        case .free:  freeBadge
        case .pro:   ProBadgeShine()
        }
    }

    private var freeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 11, weight: .heavy))
            Text("Free")
                .appFont(.captionStrong)
                .tracking(0.3)
        }
        .foregroundStyle(Color.inkMute)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.bgSurface))
        .overlay(
            Capsule().strokeBorder(Color.inkMute.opacity(0.18), lineWidth: 1)
        )
    }
}

/// The pro badge, factored out so it can hold its own `@State` for the
/// shine sweep without forcing every render of the parent view to
/// re-animate.
private struct ProBadgeShine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    // Warm gold gradient — three stops give the capsule a real metallic
    // feel (darker at the edges, brighter through the center). Pure
    // RGB literals; substitute design-system gold tokens when they exist.
    private static let goldLeading  = Color(red: 0.788, green: 0.635, blue: 0.153)  // #C9A227
    private static let goldMid      = Color(red: 0.910, green: 0.784, blue: 0.290)  // #E8C84A
    private static let goldTrailing = Color(red: 0.722, green: 0.525, blue: 0.043)  // #B8860B

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 11, weight: .heavy))
            Text("PRO")
                .appFont(.captionStrong)
                .tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            ZStack {
                // Metallic base — gives the badge weight and depth.
                Capsule().fill(
                    LinearGradient(
                        colors: [Self.goldLeading, Self.goldMid, Self.goldTrailing],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                // Shine sweep — a soft diagonal highlight that glides
                // across the badge. The clear→white→clear stops produce
                // a thin band; the rotation + offset draw it diagonally
                // off-canvas and back. Capsule mask keeps the highlight
                // inside the pill so the bright streak doesn't bleed
                // onto neighbors.
                if !reduceMotion {
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.55),
                                .clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(20))
                    .offset(x: shimmer ? 120 : -120)
                    .mask(Capsule())
                }
            }
        )
        .shadow(color: Self.goldLeading.opacity(0.4), radius: 6, x: 0, y: 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .linear(duration: 2.2).repeatForever(autoreverses: false)
            ) {
                shimmer = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pro plan")
    }
}

#if DEBUG
#Preview("Tier badges") {
    VStack(spacing: 16) {
        TierBadge(tier: .free)
        TierBadge(tier: .pro)
    }
    .padding(40)
    .background(Color.bgCanvas)
}
#endif
