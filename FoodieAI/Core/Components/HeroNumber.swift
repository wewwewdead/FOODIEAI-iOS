import SwiftUI

/// Phase 14: the one-number-per-screen treatment.
///
/// Renders an UPPERCASE eyebrow label, the number itself in M PLUS Black
/// 88pt (or 56pt for `.medium`, used inside the ProgressRing), and an
/// optional unit subtitle ("of 2,000"). Numbers are tabular via
/// `Text.number(_:)` so digit columns don't dance during the count-up.
///
/// The count-up entrance reuses Phase 13's `AnimatedNumber` infrastructure
/// — the digit-roll + interpolated `displayed` Double — but switches the
/// animation token to `.motionHero` (0.8s easeOut) so the hero number
/// "lands" with confidence on first reveal. After landing, subsequent
/// value changes still tick smoothly via Phase 13's same mechanism.
struct HeroNumber: View {
    enum HeroSize {
        /// 88pt — Result screen calorie display.
        case large
        /// 56pt — fits inside the Tracker progress ring.
        case medium
    }

    let label: String
    let value: Double
    var unit: String? = nil
    var size: HeroSize = .large
    /// When false, renders the number at `value` immediately without the
    /// count-up entrance. Used inside parent compositions that drive their
    /// own staged appearance.
    var animateOnAppear: Bool = true

    private var fontSize: CGFloat {
        switch size {
        case .large:  88
        case .medium: 56
        }
    }

    private var kerning: CGFloat {
        switch size {
        case .large:  -3
        case .medium: -2
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: AppSpacing.xs) {
            Text(label).eyebrow()
                .foregroundStyle(Color.inkMute)

            HeroAnimatedNumber(
                value: value,
                fontSize: fontSize,
                kerning: kerning,
                animateOnAppear: animateOnAppear
            )

            if let unit, !unit.isEmpty {
                Text(unit)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(Int(value.rounded()))" +
                            (unit.map { ", \($0)" } ?? ""))
    }
}

/// Internal: an animated digit-roll Text styled at the hero scale, with
/// monospacedDigit applied so the count-up doesn't shift columns.
/// Mirrors Phase 13's `AnimatedNumber` but uses `.motionHero` instead of
/// `.motionBase` for the on-appear interpolation.
private struct HeroAnimatedNumber: View {
    let value: Double
    let fontSize: CGFloat
    let kerning: CGFloat
    let animateOnAppear: Bool

    @State private var displayed: Double = 0
    @State private var didAppear: Bool = false
    /// Phase 14 delight: scale-stamp landing applied at the end of the
    /// count-up — 1.0 → 1.06 → 1.0 spring so the number lands with weight.
    @State private var stampScale: CGFloat = 1.0

    var body: some View {
        Text("\(Int(displayed.rounded()))")
            .monospacedDigit()
            .font(.custom(AppFont.PS.mplusBlack, size: fontSize))
            .kerning(kerning)
            .foregroundStyle(Color.ink)
            .contentTransition(.numericText(value: displayed))
            .scaleEffect(stampScale)
            .onAppear {
                guard !didAppear else { return }
                didAppear = true
                if animateOnAppear {
                    withAnimation(.motionHero) {
                        displayed = value
                    }
                    // After the count-up settles (~0.7s), stamp the number
                    // with a brief scale overshoot so it lands with weight.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 700)
                        withAnimation(.appStamp) {
                            stampScale = 1.06
                        }
                        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 160)
                        withAnimation(.appStamp) {
                            stampScale = 1.0
                        }
                    }
                } else {
                    displayed = value
                }
            }
            .onChange(of: value) { _, newValue in
                withAnimation(.motionBase) {
                    displayed = newValue
                }
            }
    }
}

#if DEBUG
#Preview("HeroNumber — large + medium") {
    VStack(alignment: .leading, spacing: AppSpacing.xl) {
        HeroNumber(
            label: "Calories",
            value: 285,
            unit: "of 2,000",
            size: .large
        )
        HeroNumber(
            label: "Calories",
            value: 1247,
            unit: "of 2,000",
            size: .medium
        )
    }
    .padding(AppSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
