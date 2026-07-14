import SwiftUI
import UIKit

// Extracted from TodayView.swift (2026-07) to shrink the file.
// The Records (Strava) segment, pattern card, weekly-recap banner, eat-to-goal card, activation flags, and first-scan card. Types are module-scoped so the parent view still references them.

// MARK: - Records segment (the Strava surface)

/// The "how am I doing over time" home — streak hero (with Share), this
/// week's challenge, and the 30-day record. PR-milestone + challenge-complete
/// celebrations fire here. Shares the Tracker view model for streak data;
/// the consistency card and weekly challenge load their own (local for the
/// challenge, a single 30-day query for consistency — same as before, just
/// relocated off Today).
struct RecordsView: View {
    @ObservedObject var viewModel: TrackerViewModel
    let isActive: Bool

    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject private var rhythm = LoggingRhythmStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var recordCelebrationDays: Int? = nil
    @State private var recordConfettiActive = false
    @State private var challengeConfettiActive = false
    @State private var shareImage: Image?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                recordCelebrationBanner
                streakHero
                weeklyChallengeSection
                consistencySection
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .refreshable {
            await viewModel.refresh(reason: .pullToRefresh, tab: .tracker)
        }
        .task {
            guard isActive else { return }
            await viewModel.refresh(reason: .initialAppear, tab: .tracker)
            renderShareImage()
            maybeCelebrateWeeklyChallenge()
        }
        .onChange(of: viewModel.longestStreakDays) { _, _ in
            maybeCelebrateRecord()
        }
        .onChange(of: viewModel.streakDays) { _, _ in renderShareImage() }
        .onChange(of: rhythm.loggedDays) { _, _ in maybeCelebrateWeeklyChallenge() }
    }

    // MARK: Streak hero

    private var streakHero: some View {
        let current = viewModel.streakDays ?? 0
        let longest = viewModel.longestStreakDays ?? 0
        let grace = viewModel.graceDaysRemaining ?? 0
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.accentWarm)
                Text("\(current > 0 ? current : longest)")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                Text(current > 0
                     ? "day streak"
                     : (longest > 0 ? "best streak" : "no streak yet"))
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
            }

            HStack(spacing: AppSpacing.lg) {
                statChip(label: "BEST", value: "\(longest)")
                statChip(label: "GRACE", value: "\(grace)")
            }

            if current > 0 || longest > 0, let shareImage {
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

            Text("Miss a day and your streak survives once, that's your grace day. Log every day for a week and we refill it.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(
                    LinearGradient(
                        colors: [Color.brandSoft.opacity(0.85), Color.bgSurface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .overlay(BrandConfetti(active: recordConfettiActive))
    }

    private func statChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).eyebrow().foregroundStyle(Color.inkMute)
            Text(value).appFont(.title1).foregroundStyle(Color.ink)
        }
    }

    private func renderShareImage() {
        let current = viewModel.streakDays ?? 0
        let longest = viewModel.longestStreakDays ?? 0
        let days = current > 0 ? current : longest
        guard days > 0 else { return }
        shareImage = ShareCardRenderer.streakImage(
            days: days, label: current > 0 ? "day streak" : "best streak")
    }

    // MARK: Record celebration (PR moment)

    @ViewBuilder
    private var recordCelebrationBanner: some View {
        if let days = recordCelebrationDays {
            RecordCelebrationBanner(
                days: days,
                confettiActive: recordConfettiActive,
                onDismiss: {
                    Haptics.tap()
                    withAnimation(.appReveal) {
                        recordCelebrationDays = nil
                        recordConfettiActive = false
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func maybeCelebrateRecord() {
        guard let longest = viewModel.longestStreakDays else { return }
        guard let milestone = RecordCelebrationStore.shared
                .consumePendingStreakRecord(longestStreak: longest) else { return }
        withAnimation(.appReveal) { recordCelebrationDays = milestone }
        Haptics.success()
        if !reduceMotion { recordConfettiActive = true }
    }

    // MARK: Weekly challenge

    @ViewBuilder
    private var weeklyChallengeSection: some View {
        if !rhythm.loggedDays.isEmpty {
            WeeklyChallengeCard(
                challenge: weeklyChallenge,
                completedWeeks: WeeklyChallengeStore.shared.completedCount,
                confettiActive: challengeConfettiActive
            )
        }
    }

    private var weeklyChallenge: WeeklyChallenge {
        WeeklyChallengeEngine.compute(loggedDays: rhythm.loggedDays, now: Date())
    }

    private func maybeCelebrateWeeklyChallenge() {
        let challenge = weeklyChallenge
        guard challenge.isComplete else { return }
        if WeeklyChallengeStore.shared.markCompleted(weekKey: challenge.weekKey) {
            Haptics.success()
            if !reduceMotion { challengeConfettiActive = true }
        }
    }

    // MARK: Consistency record

    private var consistencySection: some View {
        ConsistencyCard(
            goal: profileStore.calorieGoal,
            direction: profileStore.profile?.weightGoalDirection,
            bodyWeightKg: profileStore.profile?.weightKg
        )
    }
}

// MARK: - Pattern card (Phase 15)

/// One row in the Today → Patterns section. Same surface treatment as
/// MealCard (white, radius-lg, hairline border, shadow-card) so the
/// section reads as a peer of the meal list.
///
/// Icon mapping:
///   - .frequent       → arrow.counterclockwise.circle  (brand)
///   - .firstThisWeek  → sparkles                       (accentCool)
///   - .streak         → flame.fill                     (accentWarm)
///   - .moodCluster    → cloud.rain                     (inkMute)
struct PatternCard: View {
    let pattern: Pattern

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(pattern.title)
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = pattern.detail, !detail.isEmpty {
                    Text(detail)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .appShadow(.shadowCard)
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch pattern.kind {
        case .frequent:      return "arrow.counterclockwise.circle"
        case .firstThisWeek: return "sparkles"
        case .streak:        return "flame.fill"
        case .moodCluster:   return "cloud.rain"
        }
    }

    private var iconColor: Color {
        switch pattern.kind {
        case .frequent:      return .brand
        case .firstThisWeek: return .accentCool
        case .streak:        return .accentWarm
        case .moodCluster:   return .inkMute
        }
    }
}

// MARK: - Weekly recap banner (Week 3 polish)

/// "This week" entry point for the latest recap. Lives only when
/// `latestRecap` is non-nil — we never show a teaser for a recap that
/// doesn't exist yet.
///
/// Week 3 polish:
///   - subtle reveal: opacity + 6pt upward drift on first appear, with
///     a small scale-in on the icon halo so the card lands rather than
///     popping in.
///   - copy: "Your week is ready" with a coach-attribution subtitle.
///     Uses the recap's `headlineStat` when present so the user sees a
///     concrete promise of content, falling back to the coach's name.
///   - respects Reduce Motion: drift and scale collapse to a flat fade.
///
/// No retained Tasks; no timers; the reveal is a one-shot driven by
/// `.onAppear` flipping a single `@State` flag.
struct WeeklyRecapBanner: View {
    let recap: WeeklyRecap
    let onTap: () -> Void

    @State private var revealed: Bool = false
    @State private var haloPulsed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Title is evergreen — the recap's body is the real content, so
    /// the entry point only needs to invite the tap.
    private var title: String { "Your week is ready" }

    /// Subtitle prefers a concrete promise (the headlineStat) but
    /// gracefully drops to a coach byline when the server returned
    /// without one. Never empty when the banner is on screen.
    private var subtitle: String {
        if let stat = recap.headlineStat, !stat.isEmpty {
            return stat
        }
        return "A short reflection from \(recap.coachName)"
    }

    /// Secondary line — coach byline when a headlineStat already
    /// occupies the subtitle. `nil` when the subtitle already conveys
    /// the coach's voice (no headlineStat) so the card doesn't stack
    /// redundant attribution.
    private var coachByline: String? {
        guard let stat = recap.headlineStat, !stat.isEmpty else { return nil }
        return "From \(recap.coachName)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.brandSoft)
                        .frame(width: 38, height: 38)
                        .scaleEffect(haloPulsed ? 1 : 0.85)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.brandDeep)
                    // Tiny sparkle accent floats off the halo so the
                    // banner reads as a small reward, not just another
                    // calendar entry. Static glyph (no infinite anim)
                    // honoring Reduce Motion — `haloPulsed` already
                    // gates the one-shot reveal scale.
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.accentWarm)
                        .offset(x: 14, y: -14)
                        .opacity(haloPulsed ? 1 : 0)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .appFont(.title2)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .lineLimit(1)
                    if let byline = coachByline {
                        Text(byline)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkLight)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.inkLight)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.35), lineWidth: 1)
            )
            .appShadow(.shadowCard)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            coachByline.map { "\(title). \(subtitle). \($0). Tap to read." }
                ?? "\(title). \(subtitle). Tap to read."
        )
        .opacity(revealed ? 1 : 0)
        .offset(y: (revealed || reduceMotion) ? 0 : 6)
        .onAppear {
            guard !revealed else { return }
            let revealAnim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(revealAnim) { revealed = true }
            if !reduceMotion {
                withAnimation(.appBouncy.delay(0.08)) { haloPulsed = true }
            } else {
                haloPulsed = true
            }
        }
    }
}

// MARK: - Eat-to-goal suggestion card

/// Inline card surfaced on the Today screen when the user is under their
/// daily calorie goal, with a smart, meal-aware suggestion of what to eat
/// (see `MealSuggestionEngine`). It's the inverse of the over-goal
/// "burn it off" walk/jog nudge.
///
/// Visual treatment mirrors the weekly recap banner — BgSurface fill,
/// hairline border, shadowCard — so it reads as a peer of the existing
/// Today cards. The leading icon is slot-specific (sunrise / sun / moon /
/// leaf) and tinted `accentCool` for a soft, non-judgmental feel.
///
/// `onScan` routes to the Home tab via the shared NotificationRouter
/// (the same channel notification taps use), so the user lands on the
/// capture flow with one tap. `onDismiss` only clears the card for
/// this session — pull-to-refresh re-arms it if the user is still under.
struct EatToGoalCard: View {
    let suggestion: MealSuggestionEngine.Suggestion
    /// NOVEL_DIRECTIONS Idea 2 — when present, the card renders the Meal Twin
    /// (forward projection + one mood-aware move) instead of the generic idea
    /// list. Defaulted nil so a new user with no history sees the fallback.
    var twin: TwinData? = nil
    let onScan: () -> Void
    let onDismiss: () -> Void

    /// Everything the Twin layout needs, precomputed by the caller (which has
    /// the goal direction to frame the headline).
    struct TwinData {
        /// Projection framing, e.g. "Heading to 180 over".
        let headline: String
        let move: MealTwinMove
        let consumed: Double
        /// Where the day lands on the current trajectory (the "do nothing"
        /// baseline the headline describes; the move is the fix).
        let projectedLanding: Double
        /// Effective goal (base + movement credit) — same denominator as the ring.
        let goal: Double
    }

    private var slotIcon: String { twin?.move.meal.slot.iconName ?? suggestion.systemImage }
    private var isBestMood: Bool { (twin?.move.meal.moodPositiveRate ?? 0) >= 0.6 }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: slotIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentCool)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let twin {
                    twinContent(twin)
                } else {
                    suggestionContent
                }
                scanButton
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
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                // Featured hairline when the Twin is speaking; plain otherwise.
                .strokeBorder(twin != nil ? Color.brand.opacity(0.3) : Color.borderHairline,
                              lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Twin layout

    @ViewBuilder
    private func twinContent(_ twin: TwinData) -> some View {
        Text(twin.headline)
            .appFont(.bodyEmphasis)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)

        DayTrajectoryStrip(consumed: twin.consumed,
                           projected: twin.projectedLanding,
                           goal: twin.goal)
            .padding(.top, 2)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if isBestMood {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.success)
                }
                Text(twin.move.meal.name)
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
            }
            Text(twin.move.reason)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    // MARK: - Fallback (generic suggestion) layout

    @ViewBuilder
    private var suggestionContent: some View {
        Text(suggestion.headline)
            .appFont(.bodyEmphasis)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
        Text(suggestion.detail)
            .appFont(.caption)
            .foregroundStyle(Color.inkMute)
            .fixedSize(horizontal: false, vertical: true)

        if !suggestion.ideas.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(suggestion.ideas, id: \.self) { idea in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(Color.brand)
                        Text(idea)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
        }

        if let note = suggestion.proteinNote {
            Text(note)
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var scanButton: some View {
        Button(action: onScan) {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .heavy))
                Text("Scan a meal")
                    .appFont(.captionStrong)
            }
            .foregroundStyle(Color.brandDeep)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan a meal")
    }

    private var accessibilityText: String {
        if let twin {
            return "\(twin.headline). \(twin.move.meal.name), \(twin.move.reason). Scan a meal."
        }
        return "\(suggestion.headline). \(suggestion.detail). Scan a meal."
    }
}

/// NOVEL_DIRECTIONS Idea 2 signature — a slim STATIC linear read of where the
/// day is heading: a `brand` fill for what's eaten so far, a marker for the
/// projected end-of-day landing (`ink`), and a marker for the goal (`brandDeep`).
/// No animation, no number — the card's headline carries the words.
private struct DayTrajectoryStrip: View {
    let consumed: Double
    let projected: Double
    let goal: Double

    private let trackHeight: CGFloat = 6
    private let markHeight: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let maxVal = max(goal, projected, consumed, 1) * 1.12
            let width = geo.size.width
            let x: (Double) -> CGFloat = { v in
                CGFloat(min(max(v, 0), maxVal) / maxVal) * width
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.bgSurfaceSoft)
                    .frame(height: trackHeight)
                Capsule().fill(Color.brand.opacity(0.5))
                    .frame(width: x(consumed), height: trackHeight)
                marker(color: Color.brandDeep, at: x(goal))       // your goal
                marker(color: Color.ink, at: x(projected))        // where you land
            }
            .frame(height: markHeight)
        }
        .frame(height: markHeight)
        .accessibilityHidden(true)   // the headline + move row already say it
    }

    private func marker(color: Color, at position: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.25)
            .fill(color)
            .frame(width: 2.5, height: markHeight)
            .offset(x: max(0, position - 1.25))
    }
}


/// Keys for the one-time first-scan nudge. The flag is device-local
/// (UserDefaults), so it is scoped PER USER by auth id: delete+recreate and
/// account switches each produce a distinct id → a distinct key → a clean
/// slate, which makes the cross-account leak structurally impossible (no reset
/// logic to remember). Falls back to the base key when signed out — never used
/// in practice, since TodayView only renders inside the signed-in tab bar.
enum ActivationFlags {
    private static let firstScanBase = "today.firstScan.logged"

    static func firstScanLoggedKey(_ userID: UUID?) -> String {
        guard let userID else { return firstScanBase }
        return "\(firstScanBase).\(userID.uuidString)"
    }
}

// MARK: - First-scan activation card

/// Brand-forward first-run prompt that drives a new user to their first scan —
/// the activation moment that predicts retention. Same peer-card surface as
/// `EatToGoalCard` but with a brand-tinted border so it stands out as the
/// day's primary action. `onScan` routes to the Home/capture tab; `onDismiss`
/// clears it for the session (it re-arms next launch while the user is still
/// new and hasn't logged).
struct FirstScanCard: View {
    let onScan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: "camera.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Snap your first meal")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                Text("Point your camera at any meal and Foodie breaks down the calories and nutrition in seconds.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onScan) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .heavy))
                        Text("Scan a meal")
                            .appFont(.captionStrong)
                    }
                    .foregroundStyle(Color.brandDeep)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan a meal")
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
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .contain)
    }
}
