import SwiftUI

/// Today segment of the Tracker tab — Phase 14 redesign.
///
/// Layout matches mockup-3-tracker.svg:
///   - SATURDAY eyebrow + display2 "May 9" header (no brand gradient)
///   - ProgressRing centered (calories vs daily goal)
///   - Three MacroProgressBars (carbs / sugar / protein) — fat & fiber
///     hide behind a "Show all macros" toggle so the headline stays calm
///   - YOUR MEALS eyebrow + brand-colored count
///   - MealCard rows for each saved meal (replaces v1 MealRow in this list)
///
/// Empty state replaces the v1 perpetual bouncing-badge reminder
/// ("Daily tracker resets every 12:00 am") with a quiet
/// `AmbientEmptyState` saying "Today's a fresh start" — gentle, gone as
/// soon as the user logs something.
///
/// Failed state uses the v2 ink/error palette via the existing
/// AmbientEmptyState pattern + a PrimaryButton retry. The
/// pull-to-refresh and tab-appear refresh policies from Phase 6 are
/// preserved verbatim.
struct TodayView: View {
    @ObservedObject var viewModel: TrackerViewModel
    /// Daily goals come from the shared ProfileStore — owned by
    /// MainTabView so Profile edits propagate here without a manual
    /// refresh. Calorie/carb/sugar are user-editable (persisted in
    /// `public.profiles`); protein/fat/fiber stay on design-reference
    /// values until the schema gains columns for them.
    @EnvironmentObject private var profileStore: ProfileStore
    /// Phase 17 — observe notification taps so a recap-notification
    /// landing on the Tracker tab opens the sheet automatically.
    @EnvironmentObject private var notifRouter: NotificationRouter

    @State private var showAllMacros: Bool = false
    /// Phase 17 — "This week" sheet presentation flag. The sheet hosts
    /// a NavigationStack so RecapView's NavigationLinks (Past recaps)
    /// have a host without bleeding navigation state into the tab bar.
    @State private var showingRecap: Bool = false
    /// Tracks whether we've ever drawn the meal list with data, so the
    /// per-row stagger only plays on the first load. Pull-to-refresh and
    /// subsequent inserts use the cheaper opacity transition instead of
    /// re-rippling every row's bouncy spring.
    @State private var hasShownInitialMeals: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Phase 20 — end-of-day under-calorie reminder dismissal flag.
    /// Lives for the current view-model session; pull-to-refresh
    /// recomputes visibility from the current totals + time, so a
    /// genuine refresh re-surfaces the card if conditions still hold.
    @State private var underCalorieReminderDismissed: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                dateHeader
                weeklyRecapBanner
                underCalorieReminderCard
                ringBlock
                macroBars
                patternsSection
                coachObservationSection
                mealsSection
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.bgCanvas)
        .refreshable {
            // Explicit refresh re-arms the inline reminder so a user
            // who pulled the screen down genuinely *wants* to see the
            // current end-of-day state, not yesterday's dismissal.
            underCalorieReminderDismissed = false
            await viewModel.refresh()
        }
        .task {
            await viewModel.refresh()
        }
        .onChange(of: notifRouter.requestedRecap) { _, requested in
            // Phase 17 — react to a recap notification tap by opening
            // the recap sheet here on the Today screen.
            guard requested else { return }
            // Refresh first to make sure `latestRecap` is loaded.
            Task {
                await viewModel.refresh()
                await MainActor.run {
                    if viewModel.latestRecap != nil {
                        showingRecap = true
                    }
                    notifRouter.clearRecapRequest()
                }
            }
        }
        .sheet(isPresented: $showingRecap) {
            if let recap = viewModel.latestRecap {
                NavigationStack {
                    RecapView(recap: recap)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingRecap = false }
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Weekly recap banner (Phase 17)

    /// Hidden when there's no recap yet. The banner is visually distinct
    /// from the meal/pattern cards (slightly cooler accent) so it reads
    /// as a separate moment, not just another row.
    ///
    /// When a recap exists, render the full banner. When no recap exists
    /// but the user has been logging consistently this week (3+ days),
    /// surface a quiet, non-clickable "building" hint so the reflection
    /// surface doesn't feel absent. The hint reads purely from the local
    /// rhythm store — no fetch, no AI call.
    @ViewBuilder
    private var weeklyRecapBanner: some View {
        if let recap = viewModel.latestRecap {
            WeeklyRecapBanner(recap: recap) {
                Haptics.tap()
                showingRecap = true
            }
        } else if loggedDaysThisWeekLocal >= 3 {
            WeeklyRecapBuildingHint()
        }
    }

    /// Count of distinct local-day keys logged within the current ISO
    /// week (Monday–Sunday). Read directly from the rhythm store —
    /// cheap, pure, no query.
    ///
    /// The week interval is computed with an explicit ISO-8601 calendar
    /// pinned to the user's current time zone, so the Mon–Sun window
    /// doesn't drift based on `Calendar.current`'s region-default week
    /// start (which can fall on Sun or Sat for some locales).
    private var loggedDaysThisWeekLocal: Int {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = .current
        let now = Date()
        guard let interval = iso.dateInterval(of: .weekOfYear, for: now) else {
            return 0
        }
        // The rhythm store carries `yyyy-MM-dd` keys in the user's
        // local calendar. Reuse its shared key formatter so a date
        // produced here is byte-equal to whatever `markToday()` stored.
        // We hand `dayKey` the user's *local* calendar (not the ISO
        // one) — the rhythm store's keys are formatted against
        // `Calendar.current`, so we must match it for set-membership.
        let dayCal = Calendar.current

        let logged = LoggingRhythmStore.shared.loggedDays
        var cursor = interval.start
        var count = 0
        while cursor < interval.end {
            if logged.contains(LoggingRhythmStore.dayKey(for: cursor, calendar: dayCal)) {
                count += 1
            }
            guard let next = iso.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return count
    }

    // MARK: - Under-calorie reminder (Phase 20)

    /// Inline reminder card. Visible only when:
    ///   - local time is in the 22:00–23:59 window
    ///   - the user has a valid daily calorie goal
    ///   - they're still under goal (consumed < goal)
    ///   - they haven't dismissed it this session (or just refreshed)
    ///
    /// Uses the same surface treatment (BgSurface + hairline + shadow)
    /// as the weekly recap banner so it reads as a peer card, not a
    /// banner ad. Tapping the body switches to Home; the inline ×
    /// dismisses without action.
    @ViewBuilder
    private var underCalorieReminderCard: some View {
        if !underCalorieReminderDismissed,
           let status = currentCalorieStatus,
           CalorieReminderService.shouldShowEndOfDayUnderGoalReminder(
               now: Date(), status: status
           )
        {
            UnderCalorieReminderCard(
                remaining: status.remaining,
                onScan: {
                    Haptics.tap()
                    underCalorieReminderDismissed = true
                    notifRouter.requestTab(0)
                },
                onDismiss: {
                    Haptics.tap()
                    withAnimation(.appReveal) {
                        underCalorieReminderDismissed = true
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Pull a `DailyCalorieGoalStatus` out of the tracker view model's
    /// current state. `nil` when the data isn't loaded yet, which
    /// hides the card — we don't surface a reminder against an
    /// indeterminate goal.
    private var currentCalorieStatus: DailyCalorieGoalStatus? {
        guard case .loaded(_, let totals) = viewModel.state else { return nil }
        return DailyCalorieGoalStatus.compute(
            consumed: totals.totalCalories,
            goal: profileStore.calorieGoal
        )
    }

    // MARK: - Date header

    /// Phase 21 — local presentation flag for the streak detail sheet.
    @State private var showingStreakDetail: Bool = false

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .center) {
                Text(eyebrowDate(Date())).eyebrow()
                    .foregroundStyle(Color.inkMute)
                Spacer()
                streakChip
            }
            Text(headlineDate(Date()))
                .appFont(.display2)
                .foregroundStyle(Color.ink)
        }
        .sheet(isPresented: $showingStreakDetail) {
            StreakDetailSheet(
                current: viewModel.streakDays ?? 0,
                longest: viewModel.longestStreakDays ?? 0,
                graceRemaining: viewModel.graceDaysRemaining ?? 0
            )
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
    }

    /// Phase 21 — small chip showing the current streak. Hidden when
    /// the user hasn't started a streak yet (count == 0) so day-zero
    /// users don't get "0 days" rendered at them.
    @ViewBuilder
    private var streakChip: some View {
        if let streak = viewModel.streakDays, streak > 0 {
            Button {
                Haptics.tap()
                showingStreakDetail = true
            } label: {
                HStack(spacing: 4) {
                    Text("🔥")
                        .font(.system(size: 12))
                    Text("\(streak) day\(streak == 1 ? "" : "s")")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.ink)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.brandSoft))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Current streak: \(streak) days. Tap for details.")
        }
    }

    // MARK: - Progress ring

    @ViewBuilder
    private var ringBlock: some View {
        let calories = caloriesFromState
        let calorieState = GoalWarningState.resolve(
            consumed: calories, goal: profileStore.calorieGoal
        )
        VStack(spacing: AppSpacing.sm) {
            ProgressRing(
                value: calories,
                goal: profileStore.calorieGoal,
                label: "Calories"
            )
            switch calorieState {
            case .safe:
                EmptyView()
            case .approaching:
                VStack(spacing: 2) {
                    Text("You're close to today's goal")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                    Text("Small choices now keep dinner flexible.")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)
                        .multilineTextAlignment(.center)
                }
                .transition(.opacity)
            case .reached:
                VStack(spacing: 2) {
                    Text("You've reached today's goal")
                        .appFont(.caption)
                        .foregroundStyle(Color.error)
                    Text("You can still log — this just keeps the day honest.")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)
                        .multilineTextAlignment(.center)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, AppSpacing.md)
        .animation(.appReduced, value: calorieState)
    }

    // MARK: - Macro bars

    @ViewBuilder
    private var macroBars: some View {
        let totals = totalsFromState
        VStack(spacing: AppSpacing.lg) {
            MacroProgressBar(
                label: "Carbs",
                value: totals.totalCarbs,
                goal: profileStore.carbGoal,
                tint: .brand
            )
            MacroProgressBar(
                label: "Sugar",
                value: totals.totalSugar,
                goal: profileStore.sugarGoal,
                tint: .accentWarm
            )
            MacroProgressBar(
                label: "Protein",
                value: totals.totalProtein,
                goal: profileStore.proteinGoal,
                tint: .accentCool,
                reachedPraise: "Nice — this supports fullness and recovery."
            )

            if showAllMacros {
                MacroProgressBar(
                    label: "Fat",
                    value: totals.totalFat,
                    goal: profileStore.fatGoal,
                    tint: .ink
                )
                MacroProgressBar(
                    label: "Fiber",
                    value: totals.totalFiber,
                    goal: profileStore.fiberGoal,
                    tint: .success,
                    reachedPraise: "Nice — fiber helps fullness and digestion."
                )
            }

            Button {
                Haptics.tap()
                withAnimation(.motionReveal) {
                    showAllMacros.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(showAllMacros ? "Show fewer" : "Show all macros")
                        .appFont(.captionStrong)
                    Image(systemName: showAllMacros ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .heavy))
                }
                .foregroundStyle(Color.brandDeep)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
    }

    // MARK: - Patterns section (Phase 15)

    /// Hidden when there are no patterns — empty observations would be
    /// filler. Cards have the same surface treatment as MealCard so the
    /// section reads as a peer of the meal list, not a banner.
    @ViewBuilder
    private var patternsSection: some View {
        if !viewModel.patterns.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("Patterns").eyebrow()
                    .foregroundStyle(Color.inkMute)
                VStack(spacing: AppSpacing.sm) {
                    ForEach(viewModel.patterns) { pattern in
                        PatternCard(pattern: pattern)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(.appReveal, value: viewModel.patterns)
        }
    }

    // MARK: - Coach observation card (Phase 16)

    /// Editorial card showing the active coach observation. Hidden when
    /// `viewModel.activeObservation` is nil — that already encodes
    /// every guardrail (dismissed, account-age too new, no patterns).
    @ViewBuilder
    private var coachObservationSection: some View {
        if let observation = viewModel.activeObservation {
            CoachObservationCard(
                observation: observation,
                onDismiss: {
                    Haptics.tap()
                    Task { await viewModel.dismissActiveObservation() }
                }
            )
            .transition(.opacity)
            .animation(.appReveal, value: observation.id)
        }
    }

    // MARK: - Meals section

    @ViewBuilder
    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            mealsHeader
            mealsBody
        }
    }

    @ViewBuilder
    private var mealsHeader: some View {
        let count = mealCount
        HStack(alignment: .center) {
            Text("Your meals").eyebrow()
                .foregroundStyle(Color.inkMute)
            Spacer()
            if count > 0 {
                Text("\(count) today")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brand)
            }
        }
    }

    @ViewBuilder
    private var mealsBody: some View {
        switch viewModel.state {
        case .loading:
            VStack(spacing: AppSpacing.md) {
                MealRowSkeleton()
                MealRowSkeleton()
                MealRowSkeleton()
            }
        case .empty:
            AmbientEmptyState(
                iconSystemName: "tray",
                message: "Today's a fresh start"
            )
            .padding(.top, AppSpacing.xl)
        case .loaded(let logs, _):
            VStack(spacing: AppSpacing.md) {
                ForEach(Array(logs.enumerated()), id: \.element.id) { idx, log in
                    ExpandableMealCard(log: log, onDelete: {
                        Task { await viewModel.deleteLog(log) }
                    })
                    // Asymmetric so insert keeps its staggered entrance
                    // (top slide + fade) but removal is just an opacity
                    // dropout — the card itself already played its
                    // squash-and-vanish in-place, so we don't want to
                    // play it a second time on list-row removal.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                    // First-load stagger only. Subsequent refreshes /
                    // inserts use a flat reveal — the per-row delay was
                    // re-rippling every row on every refresh, which both
                    // jankified pull-to-refresh and looked like a bug.
                    .animation(
                        rowAnimation(index: idx),
                        value: logs.count
                    )
                }
            }
            .onAppear { hasShownInitialMeals = true }
        case .failed(let error):
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.error.opacity(0.85))
                Text("Couldn't load today's meals")
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text(error.localizedDescription)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "Try again",
                              leadingSystemImage: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
                .padding(.top, AppSpacing.sm)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, AppSpacing.xl2)
        }
    }

    // MARK: - State accessors

    private var caloriesFromState: Double {
        if case .loaded(_, let totals) = viewModel.state {
            return totals.totalCalories
        }
        return 0
    }

    private var totalsFromState: LocalDailyTotals {
        if case .loaded(_, let totals) = viewModel.state {
            return totals
        }
        return .empty
    }

    private var mealCount: Int {
        if case .loaded(let logs, _) = viewModel.state {
            return logs.count
        }
        return 0
    }

    // MARK: - Row animation

    /// First paint: bouncy with a small per-index delay so the rows
    /// cascade in. After the first paint: a calm reveal (or nothing under
    /// Reduce Motion) so refreshes and inserts don't replay the cascade.
    private func rowAnimation(index: Int) -> Animation? {
        if reduceMotion { return .appReduced }
        if !hasShownInitialMeals {
            return .appBouncy.delay(Double(index) * 0.04)
        }
        return .appReveal
    }

    // MARK: - Date formatting

    /// Cached DateFormatter for the weekday eyebrow ("MONDAY"). Allocating
    /// a fresh DateFormatter per body render was hot under pull-to-refresh
    /// — keeping the formatter around avoids the per-frame ICU bootstrap.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE"
        return f
    }()

    /// Cached DateFormatter for the headline date ("May 9").
    private static let headlineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM d"
        return f
    }()

    private func eyebrowDate(_ date: Date) -> String {
        Self.weekdayFormatter.string(from: date)
    }

    private func headlineDate(_ date: Date) -> String {
        Self.headlineFormatter.string(from: date)
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
private struct PatternCard: View {
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
private struct WeeklyRecapBanner: View {
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

// MARK: - Under-calorie reminder card (Phase 20)

/// Inline card surfaced on the Today screen between 22:00 and 23:59
/// local time when the user is still under their daily calorie goal.
///
/// Visual treatment mirrors the weekly recap banner — BgSurface fill,
/// hairline border, shadowCard — so it reads as a peer of the existing
/// Today cards rather than a banner or modal. The leading icon uses
/// `accentCool` to nudge a softer, "evening" feel without introducing
/// a new color.
///
/// `onScan` routes to the Home tab via the shared NotificationRouter
/// (the same channel notification taps use), so the user lands on the
/// capture flow with one tap. `onDismiss` only clears the card for
/// this session — pull-to-refresh re-arms visibility if conditions
/// still hold.
private struct UnderCalorieReminderCard: View {
    let remaining: Double
    let onScan: () -> Void
    let onDismiss: () -> Void

    private var remainingLabel: String {
        let value = max(0, remaining)
        let rounded: Int
        if value >= 100 {
            rounded = Int((value / 10).rounded()) * 10
        } else {
            rounded = Int((value / 5).rounded()) * 5
        }
        if rounded <= 0 {
            return "a little room"
        }
        return "about \(rounded) calories"
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: "moon.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentCool)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Still room left today")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You have \(remainingLabel) left today.")
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
                    .padding(.top, 2)
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
            .accessibilityLabel("Dismiss reminder")
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Weekly recap building hint

/// Quiet, non-clickable placeholder shown when the user has logged
/// 3+ local days this week but no recap exists yet. Communicates
/// that the reflection surface is alive even before the server has
/// generated a recap. Local-only — no fetch, no AI call, no timer.
private struct WeeklyRecapBuildingHint: View {
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 32, height: 32)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
            }
            Text("Your weekly reflection is building.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your weekly reflection is building.")
    }
}

// MARK: - Streak detail sheet (Phase 21)

/// Small explanatory sheet presented when the user taps the streak
/// chip. Displays current streak, longest streak, grace remaining,
/// and a one-line description of the grace-day mechanic.
private struct StreakDetailSheet: View {
    let current: Int
    let longest: Int
    let graceRemaining: Int

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

            Text("Miss a day and your streak survives once — that's your grace day. Log every day for a week and we refill it. We don't penalize humans.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCanvas)
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
