import SwiftUI

/// Phase 14: the Tracker's hero metric.
///
/// A 92pt-radius ring (184pt diameter). Background ring is
/// `borderHairline` at the same stroke width; the foreground arc is a
/// brand gradient (`brand` → `#8DA12C`) with `.round` end-caps. The
/// center stack is an eyebrow label, a `HeroNumber.medium` (56pt), and
/// an "of {goal}" caption.
///
/// Drawn with `Circle().trim(from:to:).stroke(...)` (not `Canvas`) so
/// the arc length is an animatable Shape parameter — `withAnimation`
/// can tween the trim value frame-by-frame, whereas Canvas redraws
/// imperatively and would collapse the 0 → progress reveal into a
/// single-frame snap.
struct ProgressRing: View {
    let value: Double
    let goal: Double
    let label: String
    var strokeWidth: CGFloat = 14
    var ringRadius: CGFloat = 92

    @State private var arcProgress: Double = 0
    @State private var didFlashReached: Bool = false
    @State private var reachedPulse: Bool = false
    /// Tracks the last `value` we saw so we can distinguish first-paint
    /// (no prior value) from a real value-increase event triggered by a
    /// fresh save landing in the totals. `nil` until first appear.
    @State private var lastSeenValue: Double? = nil
    /// One-shot soft bump when the value goes up (meal was saved). Smaller
    /// in amplitude than the reached pulse and uses a quicker spring so it
    /// reads as "the ring noticed."
    @State private var increaseReaction: Bool = false
    /// Tracked tasks for the two one-shot pulse animations. Stored in
    /// @State so we can cancel a stale tail before starting a new one,
    /// and so `.onDisappear` can cancel anything in-flight rather than
    /// letting it wake against a defunct view's @State storage. Each
    /// pulse owns its own slot so a reached-pulse firing in the same
    /// frame as an increase-reaction doesn't tear down the other's tail.
    @State private var increaseReactionTask: Task<Void, Never>?
    @State private var reachedPulseTask: Task<Void, Never>?
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
            // Background hairline ring + animated gradient arc. Shapes
            // (not Canvas) so `arcProgress` tweens smoothly under any
            // animation transaction.
            ZStack {
                Circle()
                    .inset(by: strokeWidth / 2)
                    .stroke(
                        Color.borderHairline,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )

                Circle()
                    .inset(by: strokeWidth / 2)
                    .trim(from: 0, to: arcProgress)
                    .stroke(
                        LinearGradient(
                            colors: arcGradientStops,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    // Sweep starts at 12 o'clock, clockwise.
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(reachedPulse ? 1.035 : (increaseReaction ? 1.018 : 1.0))
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
        .accessibilityLabel(accessibilityCopy)
        .onAppear {
            // Phase 14 delight: ring fills with a deliberate, slightly
            // bouncy reveal so the arc reads as "here's where you are"
            // rather than a flick. Reduce Motion keeps the count-up (the
            // user needs to see the arc grow to read the value) but swaps
            // the spring for a calm ease.
            let curve: Animation = reduceMotion ? .appReduced : .motionProgressFill.delay(0.1)
            withAnimation(curve) {
                arcProgress = clampedProgress
            }
            // Seed the value tracker so the first refresh after appear
            // doesn't read as a "the value just went up" event — only
            // genuine post-appear increases trigger the reaction.
            lastSeenValue = value
            if warningState == .reached { didFlashReached = true }
        }
        .onChange(of: clampedProgress) { _, new in
            withAnimation(reduceMotion ? .appReduced : .motionProgressFill) {
                arcProgress = new
            }
        }
        .onChange(of: value) { _, new in
            runIncreaseReaction(newValue: new)
        }
        .onChange(of: warningState) { _, state in
            runReachedPulse(state: state)
        }
        .onDisappear {
            // Cancel any in-flight pulse tails so they don't wake after
            // the view is gone (and against @State storage that's about
            // to be torn down). Bools are reset synchronously — no
            // animation needed since the view is no longer on screen.
            increaseReactionTask?.cancel()
            increaseReactionTask = nil
            increaseReaction = false
            reachedPulseTask?.cancel()
            reachedPulseTask = nil
            reachedPulse = false
        }
    }

    private var accessibilityCopy: String {
        let v = Int(value.rounded())
        let g = Int(goal.rounded())
        let pct = Int(clampedProgress * 100)
        return "\(label) \(v) of \(g), \(pct) percent"
    }

    /// Run the one-shot increase reaction when a save's worth of calories
    /// lands in `value`. Extracted from the body chain so the type-checker
    /// can keep the modifier list within budget.
    ///
    /// Cancellation model: any prior in-flight pulse is cancelled before
    /// the new one starts, and `try await` propagates the cancellation
    /// out of the sleep so we don't apply the second `withAnimation`
    /// against a defunct view. `.onDisappear` cancels the slot too.
    private func runIncreaseReaction(newValue: Double) {
        if reduceMotion {
            lastSeenValue = newValue
            return
        }
        defer { lastSeenValue = newValue }
        guard let prior = lastSeenValue, newValue > prior + 1 else { return }
        increaseReactionTask?.cancel()
        increaseReactionTask = Task { @MainActor in
            withAnimation(.appStamp) { increaseReaction = true }
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                // Cancelled mid-flight (newer pulse arrived, view
                // disappeared). The newer pulse / `.onDisappear` is now
                // responsible for the bool — bail without overwriting it.
                return
            }
            withAnimation(.appPress) { increaseReaction = false }
        }
    }

    /// Single-shot reached pulse, fired the first time `warningState`
    /// flips into `.reached`. Same cancellation model as the increase
    /// reaction: prior task cancelled before a new one starts; the
    /// in-flight sleep is `try await`ed so cancellation propagates and
    /// the closing animation only runs if we made it through the sleep.
    private func runReachedPulse(state: GoalWarningState) {
        guard !reduceMotion,
              state == .reached,
              !didFlashReached else { return }
        didFlashReached = true
        reachedPulseTask?.cancel()
        reachedPulseTask = Task { @MainActor in
            withAnimation(.appStamp) { reachedPulse = true }
            do {
                try await Task.sleep(nanoseconds: 260_000_000)
            } catch {
                return
            }
            withAnimation(.appPress) { reachedPulse = false }
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
