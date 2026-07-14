import WidgetKit
import SwiftUI

// The home-screen "Daily Loop" widget. Lives in the FoodieAIWidget extension
// target. Depends only on the shared `WidgetSnapshot.swift` (a member of both
// the app and this target). `@main` lives in FoodieAIWidgetBundle.swift.

// MARK: - Local palette
// The app's `AppColor`/`AppFont` are in the app target and aren't visible to an
// extension, so the widget carries a tiny brand-matched palette of its own.
// Values are 1:1 with the app's theme so the widget reads identically to the
// Today page's Daily Loop rings.
private enum WidgetPalette {
    static let brand     = Color(red: 0.722, green: 0.792, blue: 0.220) // #B8CA38
    static let brandDeep = Color(red: 0.290, green: 0.341, blue: 0.075) // #4A5713
    static let brandSoft = Color(red: 0.957, green: 0.973, blue: 0.867) // #F4F8DD
    static let cream     = Color(red: 0.988, green: 1.0,   blue: 0.973) // #FCFFF8
    static let ink       = Color(red: 0.13,  green: 0.14,  blue: 0.12)  // #181715-ish
    static let inkMute   = Color(red: 0.42,  green: 0.45,  blue: 0.40)  // #6B6862-ish
    static let accent    = Color(red: 0.357, green: 0.498, blue: 0.561) // #5B7F8F accentCool
    static let warm      = Color(red: 0.886, green: 0.482, blue: 0.173) // #E27B2C accentWarm
    static let track     = Color.black.opacity(0.08)
    static let over      = Color(red: 0.784, green: 0.243, blue: 0.243) // #C83E3E errorV2
}

// MARK: - Timeline

struct FoodieEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct FoodieProvider: TimelineProvider {
    func placeholder(in context: Context) -> FoodieEntry {
        FoodieEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (FoodieEntry) -> Void) {
        completion(FoodieEntry(date: Date(), snapshot: WidgetBridge.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FoodieEntry>) -> Void) {
        // Read today's steps straight from HealthKit, in the widget's own
        // process, so the step ring stays fresh even when the app is force-quit
        // and can't push updates. Everything else in the snapshot (calories,
        // streak, goal, coach line) is owned by the app and only changes when
        // the user opens it, so we keep whatever it last wrote.
        WidgetHealthSteps.todaySteps { liveSteps in
            let now = Date()
            let cal = Calendar.current

            // Start from the last snapshot the app wrote, rolled over to today so
            // a stale (previous-day) snapshot doesn't leak yesterday's figures.
            var snapshot = WidgetBridge.read().rolledOver(to: now)
            // Merge in the live HealthKit count. Taking the max means the widget
            // never shows fewer steps than the app last wrote — HealthKit commits
            // samples in batches and can briefly lag the app's live pedometer, so
            // a raw overwrite could make the count visibly drop.
            if let live = liveSteps {
                snapshot.steps = max(snapshot.steps, live)
            }
            // Stamp "now" so the view's own `rolledOver(to:)` keeps these merged
            // steps for the live entry, and still zeroes them on the midnight
            // entry below (whose date lands on the next day).
            snapshot.updatedAt = now

            // The "now" entry renders the merged snapshot.
            var entries = [FoodieEntry(date: now, snapshot: snapshot)]

            // A second entry exactly at the next local midnight, so the daily
            // figures (steps, calories) flip to 0 at the day rollover even if the
            // app is never opened. The view zeroes them because the entry's date
            // is on the new day.
            if let midnight = cal.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) {
                entries.append(FoodieEntry(date: midnight, snapshot: snapshot))
            }

            // Ask WidgetKit to reload us again soon. This is now the PRIMARY way
            // steps stay current while the app is force-quit, so we request a
            // tight cadence; WidgetKit still throttles to the widget's daily
            // budget (~40-70 reloads/day, roughly every 15-60 min). App-driven
            // reloads on foreground don't count against that budget, so opening
            // the app remains instant on top of this.
            let next = cal.date(byAdding: .minute, value: 15, to: now)
                ?? now.addingTimeInterval(15 * 60)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

// MARK: - Rings

/// Bare progress ring: a full track, a base "lap" arc in `tint`, and an
/// optional warm "bonus lap" arc layered over a full ring once the metric
/// passes its goal. This is the widget's port of the Today page's
/// `MetricRing.celebratesOverflow` treatment — over-goal *movement* reads as a
/// second lap (10k ≠ 6k) instead of silently capping at a full ring.
private struct OverflowRing: View {
    let progress: Double            // 0…1 base lap (already clamped)
    var overflow: Double = 0        // 0…1 warm bonus lap; 0 hides it
    let tint: Color
    var overflowTint: Color = WidgetPalette.warm
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(WidgetPalette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if overflow > 0 {
                // Bonus lap over the (now full) base ring — Strava-style "you
                // lapped your goal." Only movement earns this; the calorie ring
                // never passes an overflow value.
                Circle()
                    .trim(from: 0, to: min(overflow, 1))
                    .stroke(overflowTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

private struct StreakChip: View {
    let days: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WidgetPalette.brand)
            Text(days > 0 ? "\(days)-day streak" : "Start your streak")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.ink)
        }
    }
}

/// A ring with the value + unit stacked in the center — used for the paired
/// calories+steps "Daily Loop" on the medium widget. When `reached` the unit
/// line gets a warm check so hitting the goal reads at a glance, matching the
/// Today page's celebratory over-goal treatment for movement.
private struct MiniMetricRing: View {
    let progress: Double
    var overflow: Double = 0
    let tint: Color
    let value: String
    let unit: String
    var reached: Bool = false

    var body: some View {
        OverflowRing(progress: progress, overflow: overflow, tint: tint, lineWidth: 7)
            .frame(width: 56, height: 56)
            .overlay {
                VStack(spacing: 1) {
                    Text(value)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if reached {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .heavy))
                            Text(unit)
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(WidgetPalette.warm)
                    } else {
                        Text(unit)
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(WidgetPalette.inkMute)
                    }
                }
                .padding(.horizontal, 4)
            }
    }
}

/// Compact steps ring + label — used on the small widget where a full second
/// metric ring won't fit beside the calorie hero. The ring center swaps a
/// walking glyph for a warm check the moment the step goal is met, and the
/// bonus lap shows any surplus.
private struct StepsRingRow: View {
    let steps: Int
    let progress: Double
    let overflow: Double
    let reached: Bool

    var body: some View {
        HStack(spacing: 8) {
            OverflowRing(progress: progress, overflow: overflow,
                         tint: WidgetPalette.accent, lineWidth: 6)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: reached ? "checkmark" : "figure.walk")
                        .font(.system(size: reached ? 11 : 12, weight: .bold))
                        .foregroundStyle(reached ? WidgetPalette.warm : WidgetPalette.accent)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(FoodieWidgetView.groupedSteps(steps))
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(WidgetPalette.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(reached ? "step goal hit" : "steps")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(reached ? WidgetPalette.warm : WidgetPalette.inkMute)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Widget view

struct FoodieWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FoodieEntry

    // Zero out the daily figures (steps, calories) when the cached snapshot is
    // from an earlier day, so the widget resets at local midnight even if the
    // app isn't opened. `entry.date` is "now" for the live entry and the next
    // midnight for the rollover entry the provider schedules below.
    private var s: WidgetSnapshot { entry.snapshot.rolledOver(to: entry.date) }
    // All calorie over/left math keys off the EFFECTIVE goal (base + today's
    // movement credit), the same denominator the in-app ring uses, so the
    // widget never says "over" while the app says "on goal" on an active day.
    private var over: Bool { s.effectiveCalorieGoal > 0 && s.caloriesConsumed > s.effectiveCalorieGoal }
    // Round the displayed left/over figure to a friendly multiple (nearest 10
    // at/above 100, else 5) so the widget reads identically to the app's
    // calorie copy — mirrors `MealSuggestionEngine.roundKcal` in the app.
    private var remaining: Int { Self.friendlyKcal(max(0, s.effectiveCalorieGoal - s.caloriesConsumed)) }
    private var overBy: Int { Self.friendlyKcal(max(0, s.caloriesConsumed - s.effectiveCalorieGoal)) }

    private static func friendlyKcal(_ v: Int) -> Int {
        let value = max(0, v)
        if value >= 100 { return Int((Double(value) / 10).rounded()) * 10 }
        return Int((Double(value) / 5).rounded()) * 5
    }

    private var stepProgress: Double {
        guard s.stepGoal > 0 else { return 0 }
        return min(max(Double(s.steps) / Double(s.stepGoal), 0), 1)
    }

    /// Fraction of a *second* lap walked past the step goal, capped at one full
    /// bonus lap — the widget port of `MetricRing.overflowProgress`. 0 until the
    /// goal is passed, so the warm lap only appears on genuine surplus.
    private var stepOverflow: Double {
        guard s.stepGoal > 0, s.steps > s.stepGoal else { return 0 }
        return min(Double(s.steps - s.stepGoal) / Double(s.stepGoal), 1)
    }

    private var stepGoalReached: Bool { s.stepGoal > 0 && s.steps >= s.stepGoal }

    /// Abbreviated step count for the tight ring center: 4,200 → "4.2k", 12,000 → "12k".
    static func abbrevSteps(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        return "\(n)"
    }

    /// Thousands-grouped step count for the steps row: 4200 → "4,200".
    static func groupedSteps(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let chars = Array(String(n))
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0 && (chars.count - i) % 3 == 0 { out += "," }
            out.append(c)
        }
        return out
    }

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            StreakChip(days: s.streakDays)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 10) {
                OverflowRing(progress: s.calorieProgress,
                             tint: over ? WidgetPalette.over : WidgetPalette.brand,
                             lineWidth: 8)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(over ? overBy : remaining)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(WidgetPalette.ink)
                    Text(over ? "over" : "left")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(WidgetPalette.inkMute)
                }
            }
            Spacer(minLength: 0)
            // Steps — a compact ring so the "over goal" bonus lap reads here too.
            StepsRingRow(steps: s.steps, progress: stepProgress,
                         overflow: stepOverflow, reached: stepGoalReached)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    StreakChip(days: s.streakDays)
                    Spacer(minLength: 0)
                    Text(over ? "\(overBy) over" : "\(remaining) kcal left")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                    Text("of \(s.effectiveCalorieGoal) goal")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(WidgetPalette.inkMute)
                }
                Spacer(minLength: 0)
                // The app's signature "Daily Loop": energy-in beside movement.
                // The steps ring celebrates surplus with a warm bonus lap + a
                // goal-hit check, exactly like the Today page's paired rings.
                HStack(spacing: 10) {
                    MiniMetricRing(
                        progress: s.calorieProgress,
                        tint: over ? WidgetPalette.over : WidgetPalette.brand,
                        value: "\(s.caloriesConsumed)", unit: "kcal"
                    )
                    MiniMetricRing(
                        progress: stepProgress,
                        overflow: stepOverflow,
                        tint: WidgetPalette.accent,
                        value: Self.abbrevSteps(s.steps), unit: "steps",
                        reached: stepGoalReached
                    )
                }
            }
            // Coach line from the app: burn-off when over, eat-to-goal when
            // under. The icon + tint cue which kind it is.
            if let tip = s.suggestion, !tip.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: over ? "figure.walk" : "fork.knife")
                        .font(.system(size: 11, weight: .bold))
                    Text(tip)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(over ? WidgetPalette.accent : WidgetPalette.brand)
            }
        }
    }
}

// MARK: - Widget configuration

struct FoodieAIWidget: Widget {
    let kind = "FoodieAIWidget"

    // A soft cream→brandSoft diagonal wash gives the rings a little depth
    // without competing with them — the widget-safe stand-in for the app's
    // layered card surfaces.
    private var backdrop: LinearGradient {
        LinearGradient(
            colors: [WidgetPalette.cream, WidgetPalette.brandSoft],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FoodieProvider()) { entry in
            // Guard containerBackground in case the extension's deployment
            // target is below iOS 17 (Xcode widget templates sometimes are).
            if #available(iOS 17.0, *) {
                FoodieWidgetView(entry: entry)
                    .containerBackground(for: .widget) { backdrop }
            } else {
                FoodieWidgetView(entry: entry)
                    .padding()
                    .background(backdrop)
            }
        }
        .configurationDisplayName("Daily Loop")
        .description("Your streak, calories, and steps today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
