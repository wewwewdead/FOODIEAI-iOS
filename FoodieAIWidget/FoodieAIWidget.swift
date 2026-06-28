import WidgetKit
import SwiftUI

// The home-screen "Daily Loop" widget. Lives in the FoodieAIWidget extension
// target. Depends only on the shared `WidgetSnapshot.swift` (a member of both
// the app and this target). `@main` lives in FoodieAIWidgetBundle.swift.

// MARK: - Local palette
// The app's `AppColor`/`AppFont` are in the app target and aren't visible to an
// extension, so the widget carries a tiny brand-matched palette of its own.
private enum WidgetPalette {
    static let brand   = Color(red: 0.722, green: 0.792, blue: 0.220) // #B8CA38
    static let cream   = Color(red: 0.988, green: 1.0,   blue: 0.973) // #FCFFF8
    static let ink     = Color(red: 0.13,  green: 0.14,  blue: 0.12)
    static let inkMute = Color(red: 0.42,  green: 0.45,  blue: 0.40)
    static let accent  = Color(red: 0.357, green: 0.498, blue: 0.561) // #5B7F8F
    static let track   = Color.black.opacity(0.08)
    static let over    = Color.red.opacity(0.85)
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
        let now = Date()
        let snapshot = WidgetBridge.read()
        let cal = Calendar.current

        // The "now" entry renders the snapshot as-is (or zeroed, if it's already
        // from a previous day — the view's `rolledOver(to:)` handles that).
        var entries = [FoodieEntry(date: now, snapshot: snapshot)]

        // A second entry exactly at the next local midnight, so the daily
        // figures (steps, calories) flip to 0 at the day rollover even if the
        // app is never opened. The view zeroes them because the entry's date is
        // on the new day.
        if let midnight = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) {
            entries.append(FoodieEntry(date: midnight, snapshot: snapshot))
        }

        // Opening the app pushes a fresh snapshot AND reloads timelines
        // immediately (see WidgetSnapshotUpdater), so the widget is current the
        // moment the user opens the app. This 5-hour cadence is only a
        // background safety net so a new streak still surfaces even if the app
        // isn't opened for a while.
        let next = cal.date(byAdding: .hour, value: 5, to: now)
            ?? now.addingTimeInterval(5 * 3600)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

// MARK: - Pieces

private struct CalorieRing: View {
    let progress: Double
    let over: Bool
    var lineWidth: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().stroke(WidgetPalette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(over ? WidgetPalette.over : WidgetPalette.brand,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
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

/// A small ring with the value + unit stacked in the center — used for the
/// paired calories+steps "Daily Loop" on the medium widget.
private struct MiniMetricRing: View {
    let progress: Double
    let tint: Color
    let value: String
    let unit: String
    var body: some View {
        ZStack {
            Circle().stroke(WidgetPalette.track, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(WidgetPalette.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.inkMute)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 56, height: 56)
    }
}

/// Compact steps row with a thin progress capsule — used where a second ring
/// won't fit (the small widget).
private struct StepsBar: View {
    let steps: Int
    let progress: Double
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.walk")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(WidgetPalette.accent)
            Text(FoodieWidgetView.groupedSteps(steps))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.ink)
                .layoutPriority(1)
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.track)
                GeometryReader { geo in
                    Capsule().fill(WidgetPalette.accent)
                        .frame(width: max(4, geo.size.width * progress))
                }
            }
            .frame(height: 5)
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
    private var over: Bool { s.calorieGoal > 0 && s.caloriesConsumed > s.calorieGoal }
    // Round the displayed left/over figure to a friendly multiple (nearest 10
    // at/above 100, else 5) so the widget reads identically to the app's
    // calorie copy — mirrors `MealSuggestionEngine.roundKcal` in the app.
    private var remaining: Int { Self.friendlyKcal(max(0, s.calorieGoal - s.caloriesConsumed)) }
    private var overBy: Int { Self.friendlyKcal(max(0, s.caloriesConsumed - s.calorieGoal)) }

    private static func friendlyKcal(_ v: Int) -> Int {
        let value = max(0, v)
        if value >= 100 { return Int((Double(value) / 10).rounded()) * 10 }
        return Int((Double(value) / 5).rounded()) * 5
    }

    private var stepProgress: Double {
        guard s.stepGoal > 0 else { return 0 }
        return min(max(Double(s.steps) / Double(s.stepGoal), 0), 1)
    }

    /// Abbreviated step count for the tight ring center: 4,200 → "4.2k", 12,000 → "12k".
    static func abbrevSteps(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        return "\(n)"
    }

    /// Thousands-grouped step count for the steps bar: 4200 → "4,200".
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
                CalorieRing(progress: s.calorieProgress, over: over)
                    .frame(width: 42, height: 42)
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
            // Steps — compact bar so it fits under the calorie readout.
            StepsBar(steps: s.steps, progress: stepProgress)
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
                    Text("of \(s.calorieGoal) goal")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(WidgetPalette.inkMute)
                }
                Spacer(minLength: 0)
                // The app's signature "Daily Loop": energy-in beside movement.
                HStack(spacing: 10) {
                    MiniMetricRing(
                        progress: s.calorieProgress,
                        tint: over ? WidgetPalette.over : WidgetPalette.brand,
                        value: "\(s.caloriesConsumed)", unit: "kcal"
                    )
                    MiniMetricRing(
                        progress: stepProgress,
                        tint: WidgetPalette.accent,
                        value: Self.abbrevSteps(s.steps), unit: "steps"
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
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FoodieProvider()) { entry in
            // Guard containerBackground in case the extension's deployment
            // target is below iOS 17 (Xcode widget templates sometimes are).
            if #available(iOS 17.0, *) {
                FoodieWidgetView(entry: entry)
                    .containerBackground(WidgetPalette.cream, for: .widget)
            } else {
                FoodieWidgetView(entry: entry)
                    .padding()
                    .background(WidgetPalette.cream)
            }
        }
        .configurationDisplayName("Daily Loop")
        .description("Your streak, calories, and steps today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
