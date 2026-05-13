import SwiftUI

// MARK: - Goal warning model (shared)

/// Threshold state for a tracked nutrition goal. Used by both
/// MacroProgressBar and ProgressRing so calorie + macro rows share the
/// exact same approaching/reached logic.
enum GoalWarningState: Equatable {
    case safe
    case approaching
    case reached

    /// progress = consumed / goal, with goal-0 / negative-input / NaN
    /// guarded. Thresholds (per spec):
    ///   safe:        progress < 0.80
    ///   approaching: 0.80 ≤ progress < 1.00
    ///   reached:     progress ≥ 1.00
    static func resolve(consumed: Double, goal: Double) -> GoalWarningState {
        guard goal > 0, consumed.isFinite, goal.isFinite else { return .safe }
        let p = max(consumed, 0) / goal
        if p >= 1.0 { return .reached }
        if p >= 0.80 { return .approaching }
        return .safe
    }
}

/// Phase 14: a single macro row on Tracker.
///
/// Visual structure (matches mockup-3-tracker.svg, lines 58–77):
///   Carbs                    142 / 250 g
///   ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░
///
/// Three of these stack on Tracker:
///   - Carbs   tinted `brand`        (#B8CA38)
///   - Sugar   tinted `accentWarm`   (#E27B2C)
///   - Protein tinted `accentCool`   (#5B7F8F)
///
/// On appear the fill bar animates from 0 width to its target under
/// `.motionReveal`. Numbers are tabular.
///
/// Warning behavior: once `value/goal ≥ 0.80`, the fill tints toward
/// `.error`; at `≥ 1.00` the fill is full `.error` and an inline caption
/// surfaces under the bar ("Approaching your <label> goal" /
/// "<Label> goal reached"). Width is always capped to the track even if
/// `value` exceeds `goal` — text still shows the true value.
struct MacroProgressBar: View {
    let label: String
    let value: Double
    let goal: Double
    var unit: String = "g"
    let tint: Color

    @State private var fillProgress: Double = 0
    /// One-shot reached pulse: scales the fill bar's tint up briefly when
    /// the goal first crosses into `.reached`. Latched so refreshes that
    /// remain in `.reached` don't replay it.
    @State private var didFlashReached: Bool = false
    @State private var reachedPulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedProgress: Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
    }

    private var warningState: GoalWarningState {
        GoalWarningState.resolve(consumed: value, goal: goal)
    }

    /// Safe → existing tint. Approaching → `.error` blended over the
    /// hairline track at 0.35 → 0.75 alpha across [0.80, 1.00). Reached →
    /// full `.error`. The blend with the borderHairline track is what
    /// reads as "light red" rather than harsh red.
    private var fillColor: Color {
        guard goal > 0 else { return tint }
        let p = max(value, 0) / goal
        if p >= 1.0 { return .error }
        if p >= 0.80 {
            let t = (p - 0.80) / 0.20            // 0…1
            return Color.error.opacity(0.35 + t * 0.40)
        }
        return tint
    }

    private var warningCopy: String? {
        switch warningState {
        case .safe:        return nil
        case .approaching: return "Approaching your \(label.lowercased()) goal"
        case .reached:     return "\(label) goal reached"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(label)
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
                Spacer()
                HStack(spacing: 0) {
                    Text.number(value)
                        .appFont(.captionStrong)
                    Text(" / ")
                        .appFont(.captionStrong)
                    Text.number(goal)
                        .appFont(.captionStrong)
                    Text(" \(unit)")
                        .appFont(.captionStrong)
                }
                .foregroundStyle(Color.inkMute)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.borderHairline)
                        .frame(height: 6)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(0, geo.size.width * fillProgress),
                               height: 6)
                        .scaleEffect(y: reachedPulse ? 1.55 : 1.0, anchor: .center)
                        .animation(.easeInOut(duration: 0.2),
                                   value: warningState)
                }
            }
            .frame(height: 6)

            if let copy = warningCopy {
                Text(copy)
                    .appFont(.caption)
                    .foregroundStyle(
                        warningState == .reached ? Color.error : Color.inkMute
                    )
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label) \(Int(value.rounded())) of \(Int(goal.rounded())) \(unit)"
            + (warningCopy.map { ". \($0)" } ?? "")
        )
        .onAppear {
            // Phase 14 delight: bar visibly overshoots before settling.
            // Reduce Motion swaps the bouncy spring for a calm ease so the
            // fill still animates from 0 → target (the user needs the
            // visual delta to read the value), just without the overshoot.
            let curve: Animation = reduceMotion
                ? .appReduced
                : .appBouncy.delay(0.05)
            withAnimation(curve) {
                fillProgress = clampedProgress
            }
            // Latch reached-on-first-paint so we don't fire the pulse for
            // a goal that was already met when the screen appeared — only
            // celebrate the *transition* into reached, not the steady state.
            if warningState == .reached { didFlashReached = true }
        }
        .onChange(of: clampedProgress) { _, new in
            withAnimation(reduceMotion ? .appReduced : .appBouncy) {
                fillProgress = new
            }
        }
        .onChange(of: warningState) { _, state in
            // Single-shot pulse when the goal flips into reached. Skipped
            // entirely under Reduce Motion.
            guard !reduceMotion,
                  state == .reached,
                  !didFlashReached else { return }
            didFlashReached = true
            Task { @MainActor in
                withAnimation(.appStamp) { reachedPulse = true }
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.appPress) { reachedPulse = false }
            }
        }
    }
}

#if DEBUG
#Preview("MacroProgressBar — three rows") {
    VStack(spacing: AppSpacing.xl) {
        MacroProgressBar(
            label: "Carbs",   value: 142, goal: 250, tint: .brand
        )
        MacroProgressBar(
            label: "Sugar",   value: 28,  goal: 50,  tint: .accentWarm
        )
        MacroProgressBar(
            label: "Protein", value: 52,  goal: 90,  tint: .accentCool
        )
        MacroProgressBar(
            label: "Carbs",   value: 215, goal: 250, tint: .brand
        )
        MacroProgressBar(
            label: "Sugar",   value: 60,  goal: 50,  tint: .accentWarm
        )
    }
    .padding(AppSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
