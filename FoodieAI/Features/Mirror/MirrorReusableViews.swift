import SwiftUI
import UIKit

// Extracted from FoodMirrorView.swift (2026-07) to shrink the file.
// Reusable Mirror UI bits: badges, content card, story shell, fly-in, stat rows, food bar, skeleton, live dot, progress capsule, quick-stat tiles, hero orb. Types are module-scoped so the parent view still references them.

// MARK: - Reusable bits

/// Small icon badge consumed by `MirrorContentCard`.
struct MirrorBadge {
    let symbol: String
    let tint: Color
    let bg: Color
}

/// Premium content card for the Mirror tab. Layered surface
/// (bgSurface + hairline border + soft shadow), a small SF Symbol
/// badge at the top-leading corner, an UPPERCASE eyebrow, then the
/// caller's own content.
struct MirrorContentCard<Content: View>: View {
    let badge: MirrorBadge
    let eyebrow: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(badge.bg)
                        .frame(width: 36, height: 36)
                    Image(systemName: badge.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(badge.tint)
                }
                Text(eyebrow)
                    .eyebrow()
                    .foregroundStyle(Color.inkMute)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }
}

/// Story-page shell used by every page in the Wrapped-style
/// carousel. Mirrors the badge + eyebrow language of
/// `MirrorContentCard` but is laid out as a full-bleed page —
/// generous internal padding, larger badge, content vertically
/// centred so a single headline reads as the page's whole idea.
/// No outer card chrome of its own; the parent story container
/// supplies the rounded "stage" background.
/// Card scaffold every story page is rendered through. Owns the
/// pinned header (badge + eyebrow) and a scrollable content column.
///
/// The Duolingo-style per-element fly-in lives here: callers pass
/// `elements: [AnyView]` (an ordered list of children) and StoryShell
/// applies `FlyIn` to each one with a sequential per-index delay, so
/// the contents visibly arrive ONE AT A TIME after the card slide
/// settles. Centralising the cascade here means every page type
/// (moment, headline, quick stats, most-common-foods) gets the
/// stagger automatically — no per-renderer wiring required.
///
/// The pinned header flies in as element 0; content elements follow
/// as 1, 2, 3, … in array order. Reduce Motion short-circuits the
/// stagger to instant via `FlyIn`'s internal guard.
struct StoryShell: View {
    let badge: MirrorBadge
    let eyebrow: String
    /// Per-card phase flag (the parent's `contentAppeared`). False
    /// while the card is sliding in, true after — drives the fly-in.
    let appeared: Bool
    let reduceMotion: Bool
    /// Ordered content children. Each becomes one fly-in step. Group
    /// tightly-coupled content (e.g. the two-bar reveal + its bars)
    /// into a single AnyView to keep the cascade reading as one
    /// beat per "idea" rather than per primitive view.
    let elements: [AnyView]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            // Pinned header — badge + eyebrow stay at the top of
            // the card, outside the scrollable region, so they're
            // always the first thing the user sees on a tall page.
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(badge.bg)
                        .frame(width: 44, height: 44)
                    Image(systemName: badge.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(badge.tint)
                }
                Text(eyebrow)
                    .eyebrow()
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
            }
            .modifier(FlyIn(appeared: appeared,
                            order: 0,
                            reduceMotion: reduceMotion))

            // Scrollable content. The inner Spacers vertically
            // centre short content within the available space, but
            // collapse to zero when the content is tall enough to
            // scroll — so the moment card (title + body + evidence
            // + action chip + feedback chips) can no longer spill
            // past the 500pt container into the hero above.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Spacer(minLength: 0)
                    ForEach(Array(elements.enumerated()),
                            id: \.offset) { i, element in
                        element
                            .modifier(FlyIn(appeared: appeared,
                                            order: i + 1,
                                            reduceMotion: reduceMotion))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity,
                       minHeight: 0,
                       alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity,
               maxHeight: .infinity,
               alignment: .topLeading)
    }
}

/// Duolingo-style per-element entrance: each card child arrives in
/// turn (eyebrow → title → body → evidence → chips), springing up
/// from a small offset with a slight overshoot. The leading anchor
/// on the scale makes elements feel like they settle from the left,
/// matching the card's left-aligned text rhythm.
///
/// Timing:
/// - `delay = 0.07 + order × 0.07`. The 0.07 base hold lets the
///   card slide finish before the cascade starts, so the user sees
///   "card arrives, THEN words fly in" rather than overlap mush.
/// - `spring(response: 0.48, dampingFraction: 0.72)`. The 0.72
///   damping gives the visible overshoot — the "alive" feel — while
///   staying short enough that a 5-element cascade finishes around
///   ~450ms total.
///
/// Reduce Motion: opacity is the only state change (handled by the
/// `appeared` ternary on offset/scale), and the animation falls
/// through to `.appReduced` so VoiceOver / motion-sensitive users
/// get an instant rest state with no spring, no offset, no scale.
struct FlyIn: ViewModifier {
    let appeared: Bool
    let order: Int
    let reduceMotion: Bool

    private var delay: Double {
        reduceMotion ? 0 : 0.07 + Double(order) * 0.07
    }

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 24)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.94,
                         anchor: .leading)
            .animation(
                reduceMotion
                    ? .appReduced
                    : .spring(response: 0.48, dampingFraction: 0.72)
                        .delay(delay),
                value: appeared
            )
    }
}

/// Single row used by the opening "your week at a glance" story
/// page. Larger than the inline `QuickStatView` tile because each
/// stat now gets the full width of a story page.
struct StoryStatRow: View {
    let tile: QuickStatTile

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: tile.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tile.value)")
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
                Text(tile.label)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(tile.value) \(tile.label)"))
    }
}

/// Small horizontal frequency bar used inside the "Most common foods"
/// card. Gradient fill matches the learning-state capsule so the
/// visual language of "this is a measurement" is consistent across
/// the Mirror.
struct MostCommonFoodBar: View {
    let fraction: Double
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.bgSurfaceSoft)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.brand, Color.brandDeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(6, geo.size.width
                                   * CGFloat(max(0.0, min(fraction, 1.0))))
                    )
                    .animation(
                        reduceMotion ? .appReduced : .motionProgressFill,
                        value: fraction
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Skeleton placeholder used while the first refresh is in flight.
/// Shape mirrors `MirrorContentCard` (small circle badge, eyebrow
/// line, two body lines) so the swap to real content reads as the
/// page filling in rather than a hard replacement. Pulses opacity
/// on a slow loop; skipped entirely under Reduce Motion.
struct MirrorSkeletonCard: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Circle()
                    .fill(Color.bgSurfaceSoft)
                    .frame(width: 36, height: 36)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.bgSurfaceSoft)
                    .frame(width: 120, height: 10)
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgSurfaceSoft)
                .frame(height: 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgSurfaceSoft)
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgSurfaceSoft)
                .frame(height: 14)
                .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .opacity(pulse ? 0.7 : 1.0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
    }
}

/// Tiny pulsing dot used in the hero eyebrow row to signal that the
/// Mirror is a live, always-updating surface. Inner brandDeep dot
/// with a soft brand halo that fades in/out under `.appBreathing`.
/// Static under Reduce Motion.
struct LiveDot: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.brand.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .opacity(pulse ? 0.0 : 0.7)
            Circle()
                .fill(Color.brandDeep)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
    }
}

/// Gradient progress capsule used by the Mirror's learning state.
/// Animates fill on value change with `.motionProgressFill`; falls
/// back to `.appReduced` when the user has enabled Reduce Motion.
struct MirrorProgressCapsule: View {
    let value: Int
    let total: Int
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.bgSurfaceSoft)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.brand, Color.brandDeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(
                            14,
                            geo.size.width
                                * CGFloat(value)
                                / CGFloat(max(total, 1))
                        )
                    )
                    .animation(
                        reduceMotion ? .appReduced : .motionProgressFill,
                        value: value
                    )
            }
        }
    }
}

/// Payload for a single tile in the Mirror's quick-stats strip.
/// Identifiable so it can be iterated inside a ForEach.
struct QuickStatTile: Identifiable {
    let symbol: String
    let value: Int
    let label: String
    var id: String { "\(symbol)-\(label)" }
}

/// Single tile used by the quick-stats strip. Compact surface card
/// with a small SF Symbol, a monospaced number, and a one-line
/// label. Fills its share of the row's available width so the
/// strip lays out evenly regardless of how many tiles are visible.
struct QuickStatView: View {
    let tile: QuickStatTile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
            }
            Text("\(tile.value)")
                .appFont(.chipNumber)
                .foregroundStyle(Color.ink)
                .monospacedDigit()
            Text(tile.label)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowFloating)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(tile.value) \(tile.label)"))
    }
}

/// Larger orb badge for the Mirror tab hero. Same idea as the Home
/// preview's `MirrorOrb` but tuned to sit at display-text scale.
struct MirrorHeroOrb: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.brandSoft,
                            Color.brandSoft.opacity(0.6)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 28
                    )
                )
                .frame(width: 44, height: 44)
                .overlay(
                    Circle()
                        .strokeBorder(Color.brand.opacity(0.4), lineWidth: 1)
                )
                .scaleEffect(pulse ? 1.07 : 1.0)
                // Constant shadow radius — animating it re-rasterizes the
                // shadow every frame of the breathing loop; the scale pulse
                // already carries the "alive" feel.
                .shadow(color: Color.brand.opacity(0.22),
                        radius: 10, x: 0, y: 3)
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
    }
}
