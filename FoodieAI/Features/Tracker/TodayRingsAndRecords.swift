import SwiftUI
import UIKit

// Extracted from TodayView.swift (2026-07) to shrink the file.
// The metric ring, record-celebration banner, weekly-challenge card, record-celebration store, streak-detail sheet, and consistency card. Types are module-scoped so the parent view still references them.

// MARK: - Metric ring (paired Daily Loop hero)

/// A compact progress ring with a number + unit at its center. Sized by
/// `diameter`; the center type scales with it so one component serves both
/// the solo calorie hero (large) and the paired calorie/movement rings
/// (smaller). Animates its arc on appear and when the value changes.
struct MetricRing: View {
    let value: Double
    let goal: Double
    let number: String
    let unit: String
    let tint: Color
    var diameter: CGFloat = 128
    var stroke: CGFloat = 12
    /// When true, going *over* goal draws a second "bonus lap" arc in a warm
    /// tint over the full ring, so over-delivery reads visually (10k ≠ 6k)
    /// instead of capping silently at a full ring. Opt-in: only the movement
    /// ring celebrates surplus — an over-eating calorie ring should not.
    var celebratesOverflow: Bool = false

    @State private var arc: Double = 0
    @State private var arcOver: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
    }

    /// Fraction of a *second* lap completed past goal, capped at one full
    /// bonus lap. 0 unless `celebratesOverflow` and the user is over goal.
    private var overflowProgress: Double {
        guard celebratesOverflow, goal > 0, value > goal else { return 0 }
        return min((value - goal) / goal, 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: stroke / 2)
                .stroke(Color.borderHairline,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            Circle()
                .inset(by: stroke / 2)
                .trim(from: 0, to: arc)
                .stroke(tint,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Bonus lap: a warm arc layered over the full ring once the user
            // goes past goal, so surplus reads at a glance (Strava-style "you
            // lapped your goal"). Only present when `celebratesOverflow`.
            if celebratesOverflow {
                Circle()
                    .inset(by: stroke / 2)
                    .trim(from: 0, to: arcOver)
                    .stroke(Color.accentWarm,
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(number)
                    .font(.custom(AppFont.PS.mplusBlack, size: diameter * 0.26))
                    .kerning(-1)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .padding(.horizontal, stroke + 6)
        }
        .frame(width: diameter, height: diameter)
        .appShadow(.shadowFloating)
        .onAppear {
            withAnimation(reduceMotion ? .appReduced : .motionProgressFill.delay(0.1)) {
                arc = progress
                arcOver = overflowProgress
            }
        }
        .onChange(of: progress) { _, p in
            withAnimation(reduceMotion ? .appReduced : .motionProgressFill) { arc = p }
        }
        .onChange(of: overflowProgress) { _, o in
            withAnimation(reduceMotion ? .appReduced : .motionProgressFill) { arcOver = o }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number) \(unit)")
    }
}

// MARK: - Record celebration banner (PR moment)

/// Strava-style "new personal record" moment, shown on Today when the
/// user's all-time-longest streak crosses a milestone. Celebratory but
/// on-brand: brand-soft fill, flame glyph, and a one-shot BrandConfetti
/// burst over the card. Dismissible; never re-fires for the same record
/// (see `RecordCelebrationStore`).
struct RecordCelebrationBanner: View {
    let days: Int
    let confettiActive: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "flame.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.accentWarm)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("New personal record!")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                Text("Your longest streak yet, \(days) day\(days == 1 ? "" : "s").")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.inkLight)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.brandSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.35), lineWidth: 1)
        )
        .overlay(BrandConfetti(active: confettiActive))
        .appShadow(.shadowCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New personal record. Your longest streak yet, \(days) days.")
    }
}

// MARK: - Weekly challenge card

/// "This week" adaptive logging challenge — a clean progress card: eyebrow,
/// goal title, a single progress bar, and a footnote that either nudges
/// ("2 days left · beat last week") or celebrates ("3 weeks done"). One
/// BrandConfetti burst on first completion. Same surface treatment as the
/// other Today cards so it reads as a peer, not a banner.
struct WeeklyChallengeCard: View {
    let challenge: WeeklyChallenge
    let completedWeeks: Int
    let confettiActive: Bool

    private var fraction: Double {
        guard challenge.target > 0 else { return 0 }
        return min(1, Double(challenge.progress) / Double(challenge.target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("THIS WEEK").eyebrow()
                    .foregroundStyle(Color.brandDeep)
                Spacer()
                if challenge.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.success)
                }
            }

            Text(challenge.isComplete
                 ? "Challenge complete!"
                 : "Log meals on \(challenge.target) days")
                .appFont(.title2)
                .foregroundStyle(Color.ink)

            if !challenge.isComplete {
                Text(subtitle)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.borderHairline)
                    Capsule()
                        .fill(challenge.isComplete ? Color.success : Color.brand)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)

            HStack(spacing: 6) {
                Text("\(challenge.progress) / \(challenge.target) days")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(footnote)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .overlay(BrandConfetti(active: confettiActive))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Plain-language "what is this and why" line, so the card explains itself.
    private var subtitle: String {
        "A gentle weekly goal for staying consistent. It adjusts to your recent pace."
    }

    private var footnote: String {
        if challenge.isComplete {
            return completedWeeks == 1 ? "1 week done" : "\(completedWeeks) weeks done"
        }
        return challenge.daysLeftInWeek == 1
            ? "Last day this week"
            : "\(challenge.daysLeftInWeek) days left this week"
    }

    private var accessibilityText: String {
        challenge.isComplete
            ? "Weekly challenge complete. \(completedWeeks) weeks done."
            : "Weekly challenge: log meals on \(challenge.target) days. "
                + "\(challenge.progress) of \(challenge.target) done."
    }
}

// MARK: - Record celebration store

/// Local, UserDefaults-backed tracker for streak personal records, mirroring
/// the LoggingRhythmStore / FavoritesStore pattern. Decides when the
/// all-time-longest streak has crossed a celebration-worthy milestone —
/// purely from the value the Tracker already loads, so it costs no egress.
///
/// The first observation silently adopts the current best, so we never
/// retroactively celebrate a streak earned before this shipped (and a failed
/// profile load, which leaves the streak nil and never calls in, can't
/// trigger a false record). Progress is marked on read, so the same record
/// can't re-fire when the user re-opens Today.
@MainActor
final class RecordCelebrationStore {
    static let shared = RecordCelebrationStore()

    /// Ascending ladder of streak milestones worth a celebration.
    static let streakMilestones = [3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 300, 365]

    private let defaults: UserDefaults
    private let seenKey = "foodie.records.v1.lastSeenLongestStreak"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The highest milestone the longest streak crossed since we last saw
    /// it, or nil when there's nothing new to celebrate. Advances the stored
    /// high-water mark as a side effect.
    func consumePendingStreakRecord(longestStreak: Int) -> Int? {
        guard longestStreak >= 0 else { return nil }
        guard defaults.object(forKey: seenKey) != nil else {
            // First ever observation — adopt silently, celebrate nothing.
            defaults.set(longestStreak, forKey: seenKey)
            return nil
        }
        let lastSeen = defaults.integer(forKey: seenKey)
        guard longestStreak > lastSeen else { return nil }
        let crossed = Self.streakMilestones.filter { $0 > lastSeen && $0 <= longestStreak }
        defaults.set(longestStreak, forKey: seenKey)
        return crossed.max()
    }

    #if DEBUG
    /// Test hook: forget all record history.
    func reset() { defaults.removeObject(forKey: seenKey) }
    #endif
}

// MARK: - Streak detail sheet (Phase 21)

/// Small explanatory sheet presented when the user taps the streak
/// chip. Displays current streak, longest streak, grace remaining,
/// and a one-line description of the grace-day mechanic.
struct StreakDetailSheet: View {
    let current: Int
    let longest: Int
    let graceRemaining: Int

    /// Pre-rendered share card image, prepared on appear so the ShareLink
    /// has something to hand the share sheet immediately.
    @State private var shareImage: Image?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("YOUR STREAK").eyebrow()
                    .foregroundStyle(Color.inkMute)
                Text("\(current) day\(current == 1 ? "" : "s")")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
            }

            HStack(spacing: AppSpacing.lg) {
                statBlock(label: "BEST", value: "\(longest)")
                statBlock(label: "GRACE", value: "\(graceRemaining)")
            }

            Text("Miss a day and your streak survives once, that's your grace day. Log every day for a week and we refill it. We don't penalize humans.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)

            shareButton

            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCanvas)
        .onAppear(perform: renderShareImage)
    }

    /// A branded "flex" card the user can post anywhere. Hidden until the
    /// image is ready, and only when there's an actual streak to show.
    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            ShareLink(
                item: shareImage,
                preview: SharePreview("My FoodieAI streak", image: shareImage)
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                    Text(current > 0 ? "Share my streak" : "Share my record")
                        .appFont(.captionStrong)
                }
                .foregroundStyle(Color.brandDeep)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(Capsule().fill(Color.brandSoft))
            }
        }
    }

    private func renderShareImage() {
        let days = current > 0 ? current : longest
        guard days > 0 else { return }
        let label = current > 0 ? "day streak" : "best streak"
        shareImage = ShareCardRenderer.streakImage(days: days, label: label)
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).eyebrow()
                .foregroundStyle(Color.inkMute)
            Text(value)
                .appFont(.title1)
                .foregroundStyle(Color.ink)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }
}

// MARK: - Consistency record card

/// Owns the 30-day history fetch + consistency computation for the Today
/// record card. Self-contained so the card can be dropped into the Today
/// layout with one line; reloads on `.foodLogDidChange` so a fresh save is
/// reflected without leaving the tab.
@MainActor
final class ConsistencyLoader: ObservableObject {
    @Published var stats: ConsistencyStats?
    /// Day buckets parallel to `stats?.days` (same order, oldest → newest,
    /// same length). Retained so the record dot-grid can open a day's full
    /// log detail without a second query — the consistency fetch already
    /// pulled every log in the 30-day window into memory.
    @Published var buckets: [DailyBucket] = []
    private let logService = FoodLogService()

    func load(goal: Double,
              direction: CalorieGoalCalculator.GoalDirection?,
              days: Int = 30) async {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        guard let from = cal.date(byAdding: .day, value: -(days - 1), to: startToday),
              let to = cal.date(byAdding: .day, value: 1, to: startToday) else { return }
        do {
            let logs = try await logService.logs(from: from, to: to)
            let buckets = DailyBucketing.bucket(logs, from: from, to: to, calendar: cal)
            stats = ConsistencyStats.compute(
                buckets: buckets, goal: goal, direction: direction)
            self.buckets = buckets
        } catch {
            // Keep any prior stats; a transient failure (incl. task
            // cancellation when the goal changes) shouldn't blank the card.
        }
    }
}

/// The "Strava for food" proof loop for scale-free users: how many of the
/// last 30 days you stayed on goal, your best and current runs, a glanceable
/// day grid, and a few earned milestones. Hides itself until there's at
/// least one tracked day so new users don't see an empty shell.
struct ConsistencyCard: View {
    let goal: Double
    let direction: CalorieGoalCalculator.GoalDirection?
    var bodyWeightKg: Double? = nil
    @StateObject private var loader = ConsistencyLoader()
    /// Day whose detail sheet is open. Set when a tracked dot is tapped.
    @State private var selectedBucket: DailyBucket?

    var body: some View {
        // Always render a concrete host (zero-height when empty) so the
        // `.task` reliably mounts — a `Group` that resolves to nothing when
        // `stats` is nil can skip the task and the card would never load.
        content
            .task(id: goal) {
                await loader.load(goal: goal, direction: direction)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .foodLogDidChange)
            ) { _ in
                Task { await loader.load(goal: goal, direction: direction) }
            }
            .sheet(item: $selectedBucket) { bucket in
                // Reuse the same day-detail surface as Week/Month. A delete
                // here is the only path that needs a re-fetch (rare, explicit
                // action) so the grid settles to the new totals.
                DayDetailSheet(
                    bucket: bucket,
                    onDeleted: {
                        Task { await loader.load(goal: goal, direction: direction) }
                    },
                    goal: goal,
                    direction: direction,
                    bodyWeightKg: bodyWeightKg
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if let stats = loader.stats, stats.daysTracked > 0 {
            card(stats)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder
    private func card(_ stats: ConsistencyStats) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("YOUR RECORD").eyebrow()
                .foregroundStyle(Color.brandDeep)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stats.daysOnGoal)")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                Text(direction == .gain ? "days on target" : "days on goal")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
            }
            Text("of \(stats.daysTracked) tracked \(stats.daysTracked == 1 ? "day" : "days") · last 30 days")
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)

            dotGrid(stats)
                .padding(.top, 2)

            if stats.bestStreak > 0 {
                HStack(spacing: AppSpacing.lg) {
                    streakStat(value: stats.currentStreak, label: "current")
                    streakStat(value: stats.bestStreak, label: "best run")
                }
            }

            let badges = earnedBadges(stats)
            if !badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        HStack(spacing: 4) {
                            Image(systemName: "rosette")
                                .font(.system(size: 10, weight: .bold))
                            Text(badge).appFont(.caption)
                        }
                        .foregroundStyle(Color.brandDeep)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.brandSoft))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }

    private func streakStat(value: Int, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(value > 0 ? Color.brand : Color.inkLight)
            Text("\(value)")
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.ink)
            Text(label)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
    }

    private func dotGrid(_ stats: ConsistencyStats) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 8), spacing: 5), count: 10)
        return LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(stats.days.enumerated()), id: \.offset) { index, state in
                dayDot(index: index, state: state)
            }
        }
    }

    /// One day square. Tracked days — on-goal (green) *and* over-goal (red)
    /// — are tappable and open that day's full log detail. The bucket comes
    /// from `loader.buckets`, which is parallel to `stats.days` and already
    /// in memory, so opening a day costs no extra Supabase egress.
    /// Untracked days have nothing to show, so they stay inert.
    @ViewBuilder
    private func dayDot(index: Int, state: ConsistencyStats.DayState) -> some View {
        let bucket = index < loader.buckets.count ? loader.buckets[index] : nil
        if let bucket, bucket.hasLogs {
            Button {
                Haptics.selection()
                selectedBucket = bucket
            } label: {
                dotShape(state)
            }
            .buttonStyle(CalendarCellButtonStyle())
            .accessibilityLabel(dotAccessibilityLabel(bucket: bucket, state: state))
        } else {
            dotShape(state)
                .accessibilityHidden(true)
        }
    }

    private func dotShape(_ state: ConsistencyStats.DayState) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color(for: state))
            .aspectRatio(1, contentMode: .fit)
    }

    /// Cached so building 30 labels doesn't bootstrap 30 ICU formatters.
    private static let dotDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        return f
    }()

    private func dotAccessibilityLabel(bucket: DailyBucket,
                                       state: ConsistencyStats.DayState) -> String {
        let dateStr = Self.dotDateFormatter.string(from: bucket.date)
        let count = bucket.logs.count
        let mealStr = "\(count) meal\(count == 1 ? "" : "s")"
        let verdict = state == .onGoal ? "on goal" : "over goal"
        return "\(dateStr), \(mealStr), \(verdict). Tap to view details."
    }

    private func color(for state: ConsistencyStats.DayState) -> Color {
        switch state {
        case .onGoal:    return Color.brand
        case .off:       return Color.error.opacity(0.65)
        case .untracked: return Color.borderHairline
        }
    }

    private func earnedBadges(_ stats: ConsistencyStats) -> [String] {
        var out: [String] = []
        if stats.bestStreak >= 7 { out.append("7-day streak") }
        if stats.daysOnGoal >= 20 { out.append("20 on-goal days") }
        if stats.totalMeals >= 50 { out.append("50 meals") }
        return out
    }
}
