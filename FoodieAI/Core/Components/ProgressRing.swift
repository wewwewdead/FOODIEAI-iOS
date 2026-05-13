import SwiftUI

/// Phase 14: the Tracker's hero metric.
///
/// A 92pt-radius ring (184pt diameter) drawn with `Canvas` so we can
/// stroke a gradient along the arc. Background ring is `borderHairline`
/// at the same stroke width; the foreground arc is a brand gradient
/// (`brand` → `#8DA12C`) with `.round` end-caps. The center stack is an
/// eyebrow label, a `HeroNumber.medium` (56pt), and an "of {goal}"
/// caption.
///
/// On appear the arc length animates from 0 → progress under
/// `.motionReveal`; the center number ticks via `HeroNumber`'s own
/// count-up (also reveal-class).
struct ProgressRing: View {
    let value: Double
    let goal: Double
    let label: String
    var strokeWidth: CGFloat = 14
    var ringRadius: CGFloat = 92

    @State private var arcProgress: Double = 0
    @State private var didFlashReached: Bool = false
    @State private var reachedPulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var warningState: GoalWarningState {
        GoalWarningState.resolve(consumed: value, goal: goal)
    }

    private var rawProgress: Double {
        guard goal > 0 else { return 0 }
        return value / goal
    }

    /// Visual progress is clamped to [0, 1]. Going over goal renders as a
    /// full ring; the user sees the over-amount in the centered text
    /// instead of a confusing wraparound arc.
    private var clampedProgress: Double { min(max(rawProgress, 0), 1) }

    private var diameter: CGFloat { ringRadius * 2 }

    /// Arc gradient stops. Safe → brand → muted-brand. Approaching →
    /// brand fades toward `.error` as progress climbs through [0.80, 1.00).
    /// Reached → solid `.error` (both stops). Canvas redraws imperatively
    /// so this resolves once per render with no animation loop.
    private var arcGradientStops: [Color] {
        let defaultStops: [Color] = [
            .brand,
            Color(red: 141/255, green: 161/255, blue: 44/255)
        ]
        guard goal > 0 else { return defaultStops }
        let p = max(value, 0) / goal
        if p >= 1.0 { return [.error, .error] }
        if p >= 0.80 {
            let t = (p - 0.80) / 0.20
            return [
                .brand.opacity(1 - t * 0.6),
                Color.error.opacity(0.35 + t * 0.40)
            ]
        }
        return defaultStops
    }

    var body: some View {
        ZStack {
            // Two-canvas layering: background hairline ring + animated
            // gradient arc on top. The gradient uses an angular sweep
            // so the color varies subtly from start to end of the arc.
            Canvas { context, size in
                let lineWidth = strokeWidth
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = (min(size.width, size.height) - lineWidth) / 2

                var bgPath = Path()
                bgPath.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360),
                    clockwise: false
                )
                context.stroke(
                    bgPath,
                    with: .color(.borderHairline),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

                guard arcProgress > 0 else { return }

                var arcPath = Path()
                arcPath.addArc(
                    center: center,
                    radius: radius,
                    // Start at 12 o'clock; sweep clockwise.
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * arcProgress),
                    clockwise: false
                )
                context.stroke(
                    arcPath,
                    with: .linearGradient(
                        Gradient(colors: arcGradientStops),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: size.width, y: size.height)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(reachedPulse ? 1.035 : 1.0)
            .appShadow(.shadowFloating)

            VStack(spacing: 2) {
                Text(label).eyebrow()
                    .foregroundStyle(Color.inkLight)
                Text.number(value, formatter: Self.kFormatter)
                    .font(.custom(AppFont.PS.mplusBlack, size: 56))
                    .kerning(-2)
                    .foregroundStyle(Color.ink)
                Text("of \(Self.kFormatter(goal))")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label) \(Int(value.rounded())) of \(Int(goal.rounded())), " +
            "\(Int(clampedProgress * 100)) percent"
        )
        .onAppear {
            // Phase 14 delight: bouncy fill so the arc visibly overshoots
            // its target before settling — feels alive, not just a value.
            // Reduce Motion keeps the count-up (the user needs to see the
            // arc grow to read the value) but swaps the overshoot for a
            // calm ease.
            let curve: Animation = reduceMotion ? .appReduced : .appBouncy.delay(0.1)
            withAnimation(curve) {
                arcProgress = clampedProgress
            }
            if warningState == .reached { didFlashReached = true }
        }
        .onChange(of: clampedProgress) { _, new in
            withAnimation(reduceMotion ? .appReduced : .appBouncy) {
                arcProgress = new
            }
        }
        .onChange(of: warningState) { _, state in
            // Single-shot scale pulse the first time we enter `.reached`.
            // Skipped under Reduce Motion and skipped if reached on first
            // paint (e.g. revisiting a day already at goal).
            guard !reduceMotion,
                  state == .reached,
                  !didFlashReached else { return }
            didFlashReached = true
            Task { @MainActor in
                withAnimation(.appStamp) { reachedPulse = true }
                try? await Task.sleep(nanoseconds: 260_000_000)
                withAnimation(.appPress) { reachedPulse = false }
            }
        }
    }

    /// Tabular-style integer formatter with thousands separator: 1247 → "1,247".
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static func kFormatter(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return numberFormatter.string(from: NSNumber(value: v.rounded()))
            ?? "\(Int(v.rounded()))"
    }
}

#if DEBUG
#Preview("ProgressRing — three states") {
    VStack(spacing: AppSpacing.xl) {
        ProgressRing(value: 0,    goal: 2000, label: "Calories")
        ProgressRing(value: 1247, goal: 2000, label: "Calories")
        ProgressRing(value: 2380, goal: 2000, label: "Calories") // over goal
    }
    .padding(AppSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.bgCanvas)
}
#endif
