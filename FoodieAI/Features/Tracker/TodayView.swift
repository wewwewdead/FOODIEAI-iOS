import SwiftUI
import HealthKit
import CoreMotion

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
    let isActive: Bool
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
    /// Tracks whether we've ever drawn the meal list with data, so the
    /// per-row stagger only plays on the first load. Pull-to-refresh and
    /// subsequent inserts use the cheaper opacity transition instead of
    /// re-rippling every row's bouncy spring.
    @State private var hasShownInitialMeals: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Eat-to-goal suggestion dismissal flag. Lives for the current
    /// view-model session; pull-to-refresh recomputes the suggestion from
    /// the current logs + totals + time, so a genuine refresh re-surfaces
    /// the card if the user is still under goal.
    @State private var eatSuggestionDismissed: Bool = false
    @State private var automaticRefreshTask: Task<Void, Never>? = nil

    /// HealthKit activity reader (steps + active energy). Guarded — shows
    /// nothing on devices without Health or before the user grants access.
    ///
    /// NOT `@ObservedObject`: live step/active-energy ticks must not invalidate
    /// this whole (~2,400-line) body. The paired rings observe `health`
    /// themselves inside `DailyLoopHeroView`; here we only call lifecycle
    /// methods and take non-reactive reads for the widget snapshot + eat-to-goal
    /// card (which don't need to update per step).
    private let health = HealthActivityService.shared
    @ObservedObject private var streakService = StreakService.shared
    @ObservedObject private var streakRepairStore = StreakRepairStore.shared

    /// Scan-first onboarding lands new users on default goals; this presents
    /// the physiology editor so they can tailor them. Session-dismissable.
    @State private var showingPhysiologyEditor = false
    @State private var personalizeDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                dateHeader
                streakRepairBanner
                personalizeGoalsCard
                freezeNoticeBanner
                eatToGoalCard
                DailyLoopHeroView(
                    calories: caloriesFromState,
                    calorieGoal: profileStore.calorieGoal,
                    profile: profileStore.profile
                )
                macroBars
                mealsSection
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
            .onAppear {
                refreshWidgetSnapshot()
                streakRepairStore.refresh()
            }
            // Widget refreshes on app-open (onAppear / foreground below) and on
            // calorie changes — NOT per live step. A per-step reload fired a
            // cross-process WidgetCenter reload on every footstep; the widget is
            // meant to reflect the latest state when opened, not stream live.
            .onChange(of: caloriesFromState) { _, _ in refreshWidgetSnapshot() }
            .sheet(isPresented: $showingPhysiologyEditor) {
                NavigationStack {
                    PhysiologyEditorView()
                        .environmentObject(profileStore)
                }
            }
        }
        .background(
            // Premium-polish wave: canvas + slow aurora wash + ambient
            // floater anchored behind the ring. Painted as the
            // ScrollView background so it stays put when the user
            // scrolls; content slides over it for a parallax-lite feel.
            ZStack {
                Color.bgCanvas
                AuroraWash(intensity: 0.32, isActive: isActive)
                VStack {
                    AmbientFloater(intensity: 0.35, isActive: isActive)
                        .frame(height: 480)
                    Spacer(minLength: 0)
                }
            }
            .ignoresSafeArea()
        )
        .refreshable {
            // Explicit refresh re-arms the eat-to-goal suggestion so a user
            // who pulled the screen down genuinely *wants* to see the
            // current state, not an earlier dismissal.
            eatSuggestionDismissed = false
            await viewModel.refresh(reason: .pullToRefresh, tab: .tracker)
        }
        .task {
            guard isActive else { return }
            scheduleAutomaticRefresh(reason: .initialAppear)
            // Live step/energy updates: the ring climbs as the user walks
            // while this tab is on screen. Torn down when the tab goes
            // inactive or the app backgrounds (see below).
            health.startLiveUpdates(weightKg: profileStore.profile?.weightKg)
        }
        .onChange(of: isActive) { _, active in
            if active {
                scheduleAutomaticRefresh(reason: .tabBecameActive)
                health.startLiveUpdates(weightKg: profileStore.profile?.weightKg)
            } else {
                automaticRefreshTask?.cancel()
                automaticRefreshTask = nil
                health.stopLiveUpdates()
            }
        }
        // Weight drives the live active-energy estimate; it may load after the
        // streams start, so feed it in when it arrives/changes.
        .onChange(of: profileStore.profile?.weightKg) { _, kg in
            health.setMovementWeight(kg)
        }
        .onChange(of: scenePhase) { _, phase in
            // HealthKit can't push while backgrounded, so stop polling there
            // and, on return to foreground, pull once + re-arm so steps taken
            // with the app away show up immediately.
            switch phase {
            case .active:
                guard isActive else { return }
                health.startLiveUpdates(weightKg: profileStore.profile?.weightKg)
                // Pull fresh data on reopen, then sync the widget to it (the
                // widget updates on app-open, not per live step).
                Task { await health.refreshToday(); refreshWidgetSnapshot() }
            case .background, .inactive:
                // The user is about to look at the home screen — push the
                // freshest numbers first so the widget isn't stuck on a stale,
                // pre-HealthKit snapshot (steps load async, so the .onAppear
                // write often captured 0). `health.today` still holds the live
                // step/energy values gathered while the tab was on screen.
                refreshWidgetSnapshot()
                health.stopLiveUpdates()
            @unknown default:
                break
            }
        }
        .onDisappear {
            // Switching Tracker segments (Today → Records / History) tears this
            // view down while the Tracker tab stays active, so stop the sensors
            // here too — `isActive`/`scenePhase` only cover tab-switch + the
            // app backgrounding. Reappearing re-arms via `.task`.
            health.stopLiveUpdates()
        }
    }

    private func scheduleAutomaticRefresh(reason: RefreshReason) {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor in
            TabPerformanceProbe.appeared(.tracker)
            await Task.yield()
            guard !Task.isCancelled, isActive else { return }
            TabPerformanceProbe.firstFrameYielded(.tracker)
            await viewModel.refresh(reason: reason, tab: .tracker)
        }
    }

    // MARK: - Eat-to-goal suggestion

    /// The inverse of the over-goal "burn it off" nudge: when the user is
    /// under their calorie goal, suggest *what to eat* — meal-aware (the
    /// meal they still owe vs. an add-on snack), time-aware, budget-aware,
    /// and protein-aware. See `MealSuggestionEngine`.
    ///
    /// Uses the same surface treatment (BgSurface + hairline + shadow) as
    /// the weekly recap banner so it reads as a peer card. "Scan a meal"
    /// jumps to Home; the inline × dismisses for the session.
    @ViewBuilder
    private var eatToGoalCard: some View {
        if !eatSuggestionDismissed, let suggestion = eatToGoalSuggestion {
            EatToGoalCard(
                suggestion: suggestion,
                onScan: {
                    Haptics.tap()
                    eatSuggestionDismissed = true
                    notifRouter.requestTab(0)
                },
                onDismiss: {
                    Haptics.tap()
                    withAnimation(.appReveal) {
                        eatSuggestionDismissed = true
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Build the suggestion purely from data already loaded on this tab —
    /// today's logs + totals from the view model and the goals from the
    /// shared profile store. No fetch, so the card costs zero egress.
    /// `nil` (no card) when data isn't loaded, the goal is invalid, the
    /// user has already reached goal, or the engine has nothing to say.
    private var eatToGoalSuggestion: MealSuggestionEngine.Suggestion? {
        guard case .loaded(let logs, let totals) = viewModel.state else { return nil }
        // Honor the movement earn-back so "what to eat" reflects the room the
        // user moved back into their day (consistent with the Daily Loop hero).
        let status = DailyCalorieGoalStatus.compute(
            consumed: totals.totalCalories,
            goal: profileStore.calorieGoal + movementCreditKcal
        )
        guard status.hasValidGoal, status.warningState != .reached else { return nil }
        let proteinRemaining = max(0, profileStore.proteinGoal - totals.totalProtein)
        return MealSuggestionEngine.suggestion(
            todaysLogs: logs,
            remaining: status.remaining,
            proteinRemaining: proteinRemaining,
            goalDirection: profileStore.profile?.weightGoalDirection,
            now: Date(),
            timeZone: .current
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
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentWarm)
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

    // MARK: - Streak repair offer (recover a recently-broken streak)

    /// Shown for a short window after a meaningful streak resets. "Restore"
    /// undoes the break (one-tap, non-punitive); × declines. The offer self-
    /// expires (see `StreakRepairStore`), so it never lingers.
    @ViewBuilder
    private var streakRepairBanner: some View {
        if let broken = streakRepairStore.offer {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                ZStack {
                    Circle().fill(Color.brandSoft).frame(width: 42, height: 42)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.brandDeep)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get your \(broken)-day streak back")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                    Text("You missed a few days — no worries. Restore your run and pick up right where you left off.")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Haptics.tap()
                        Task {
                            try? await StreakService.shared.repair(profileStore: profileStore)
                            await viewModel.refresh()
                        }
                    } label: {
                        Text("Restore streak")
                            .appFont(.captionStrong)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.brandDeep))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    withAnimation(.appReveal) { streakRepairStore.consume() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.inkLight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
            )
            .appShadow(.shadowCard)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Personalize-your-goals nudge (scan-first deferred setup)

    /// New users land on default goals (scan-first onboarding skips the
    /// survey). Weight is the core input the calorie target needs, so its
    /// absence is our "hasn't personalized yet" signal.
    private var needsPersonalization: Bool {
        profileStore.profile != nil && profileStore.profile?.weightKg == nil
    }

    /// Gentle, dismissible nudge to tailor the default goals. Opens the same
    /// `PhysiologyEditorView` Profile uses; once physiology is saved the card
    /// self-hides (weight becomes non-nil). Session-dismissable so it isn't
    /// naggy but returns next launch until the user personalizes.
    @ViewBuilder
    private var personalizeGoalsCard: some View {
        if needsPersonalization && !personalizeDismissed {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Button {
                    Haptics.tap()
                    showingPhysiologyEditor = true
                } label: {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        ZStack {
                            Circle().fill(Color.brandSoft).frame(width: 42, height: 42)
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.brandDeep)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make these goals yours")
                                .appFont(.bodyEmphasis)
                                .foregroundStyle(Color.ink)
                            Text("Your targets are a general default right now. Add a few details and we'll tailor calories and macros to your body and goal.")
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Text("Personalize")
                                    .appFont(.captionStrong)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .heavy))
                            }
                            .foregroundStyle(Color.brandDeep)
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    withAnimation(.appReveal) { personalizeDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.inkLight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
            )
            .appShadow(.shadowCard)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Freeze-saved-your-streak notice

    /// One-time, non-shaming banner shown when a banked freeze kept a live
    /// streak alive — so the freeze buffer isn't invisible. Tap anywhere to
    /// dismiss; the notice is ephemeral (cleared from `StreakService`).
    @ViewBuilder
    private var freezeNoticeBanner: some View {
        if let notice = streakService.pendingFreezeNotice {
            Button {
                Haptics.tap()
                withAnimation(.appReveal) {
                    streakService.pendingFreezeNotice = nil
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    ZStack {
                        Circle().fill(Color.brandSoft).frame(width: 38, height: 38)
                        Image(systemName: "snowflake")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.accentCool)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A freeze saved your streak")
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.ink)
                        Text("You missed a day, but your \(notice.streakDays)-day run is still going. No pressure — pick back up whenever.")
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.inkLight)
                }
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(Color.bgSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(Color.accentCool.opacity(0.30), lineWidth: 1)
                )
                .appShadow(.shadowCard)
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel("A freeze saved your \(notice.streakDays)-day streak. Tap to dismiss.")
        }
    }

    /// Push the current daily-loop numbers to the home-screen widget's shared
    /// container. No-ops until the widget + App Group are set up
    /// (`WIDGET_SETUP.md`), so it's safe to call on every render.
    private func refreshWidgetSnapshot() {
        // Reuse the same engine the day-standing card uses so the widget's
        // coach line is identical: burn-off ("a 15-min walk evens it out")
        // when over, eat-to-goal ("room for a balanced meal") when under,
        // direction-aware. Computed against the base goal to match the
        // widget's over/under numbers.
        let standing = DayCalorieStanding.compute(
            dayCalories: caloriesFromState,
            goal: profileStore.calorieGoal,
            direction: profileStore.profile?.weightGoalDirection,
            bodyWeightKg: profileStore.profile?.weightKg
        )
        // Steps arrive from HealthKit asynchronously, so `health.today` is nil
        // for a beat after the screen appears / a meal is logged. In that window
        // keep the last step count we wrote rather than clobbering the widget
        // back to 0 — but only if it's from *today*, so we never resurrect
        // yesterday's count across local midnight. Real data (and the background
        // write above) corrects it once HealthKit reports.
        let steps = health.today?.steps ?? WidgetBridge.read().rolledOver(to: Date()).steps
        WidgetSnapshotUpdater.write(
            streakDays: viewModel.streakDays ?? profileStore.profile?.currentStreakDays ?? 0,
            caloriesConsumed: Int(caloriesFromState.rounded()),
            calorieGoal: Int(profileStore.calorieGoal.rounded()),
            steps: steps,
            stepGoal: dailyStepGoal,
            suggestion: standing?.recommendation ?? ""
        )
    }

    // MARK: - Daily Loop hero (paired rings: energy in + movement)

    /// Evidence-based daily step goal, derived from the user's goal direction
    /// Today's movement guidance — the calorie-adjusted step goal AND the line
    /// that explains it, computed together so they always agree. The goal flexes
    /// with the day's eating vs the *base* calorie goal (over → more steps to
    /// walk the excess off; under → eased toward a health floor); gain stays at
    /// its base. See `MovementGuidance`.
    private var movementGuidance: MovementGuidance.Result {
        MovementGuidance.compute(
            direction: profileStore.profile?.weightGoalDirection,
            ageYears: profileStore.profile?.ageYears,
            currentSteps: health.today?.steps ?? 0,
            consumed: caloriesFromState,
            calorieGoal: profileStore.calorieGoal,
            weightKg: profileStore.profile?.weightKg
        )
    }

    /// Calorie-adjusted daily step goal (drives the ring, sub-line, widget).
    private var dailyStepGoal: Int { movementGuidance.stepGoal }

    /// Calories of eating room earned back by moving *more* than the user's
    /// goal already assumes. 0 when we can't compute it honestly (no full
    /// physiology, or no movement above baseline) — see `MovementEnergy`.
    private var movementCreditKcal: Double {
        guard let profile = profileStore.profile, let activity = health.today else { return 0 }
        return MovementEnergy.budgetCredit(
            profile: profile,
            activeEnergyKcal: activity.activeEnergyKcal,
            steps: activity.steps
        )
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

            Text("Miss a day and your streak survives once — that's your grace day. Log every day for a week and we refill it.")
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
private struct EatToGoalCard: View {
    let suggestion: MealSuggestionEngine.Suggestion
    let onScan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: suggestion.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentCool)
            }

            VStack(alignment: .leading, spacing: 4) {
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
            .accessibilityLabel("Dismiss suggestion")
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


// MARK: - Metric ring (paired Daily Loop hero)

/// A compact progress ring with a number + unit at its center. Sized by
/// `diameter`; the center type scales with it so one component serves both
/// the solo calorie hero (large) and the paired calorie/movement rings
/// (smaller). Animates its arc on appear and when the value changes.
private struct MetricRing: View {
    let value: Double
    let goal: Double
    let number: String
    let unit: String
    let tint: Color
    var diameter: CGFloat = 128
    var stroke: CGFloat = 12

    @State private var arc: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
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
            }
        }
        .onChange(of: progress) { _, p in
            withAnimation(reduceMotion ? .appReduced : .motionProgressFill) { arc = p }
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
private struct RecordCelebrationBanner: View {
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
                Text("Your longest streak yet — \(days) day\(days == 1 ? "" : "s").")
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
private struct WeeklyChallengeCard: View {
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
                 : "Log meals \(challenge.target) days")
                .appFont(.title2)
                .foregroundStyle(Color.ink)

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

    private var footnote: String {
        if challenge.isComplete {
            return completedWeeks == 1 ? "1 week done" : "\(completedWeeks) weeks done"
        }
        let left = challenge.daysLeftInWeek == 1
            ? "Last day"
            : "\(challenge.daysLeftInWeek) days left"
        if challenge.lastWeekCount > 0 {
            return "\(left) · beat last week (\(challenge.lastWeekCount))"
        }
        return left
    }

    private var accessibilityText: String {
        challenge.isComplete
            ? "Weekly challenge complete. \(completedWeeks) weeks done."
            : "Weekly challenge: log meals \(challenge.target) days. "
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
private struct StreakDetailSheet: View {
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

            Text("Miss a day and your streak survives once — that's your grace day. Log every day for a week and we refill it. We don't penalize humans.")
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
private final class ConsistencyLoader: ObservableObject {
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
private struct ConsistencyCard: View {
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

// MARK: - Shareable record card

/// Branded, screenshot-ready card for sharing a streak / record to the iOS
/// share sheet — Strava's "flex" without a social backend. Rendered to a
/// flat image by `ShareCardRenderer`; no network, just pixels. Square so it
/// drops cleanly into stories, posts, and messages.
struct StreakShareCard: View {
    let days: Int
    let label: String   // "day streak" / "best streak"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.brandBright, Color.brand],
                startPoint: .top, endPoint: .bottom
            )

            // Soft ring flourish echoing the Month/Week header motif.
            Circle()
                .strokeBorder(Color.brandDeep.opacity(0.10), lineWidth: 2)
                .frame(width: 420, height: 420)
                .offset(x: 150, y: -170)

            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.system(size: 76, weight: .bold))
                    .foregroundStyle(Color.accentWarm)
                Text("\(days)")
                    .font(.custom(AppFont.PS.mplusBlack, size: 150))
                    .kerning(-3)
                    .foregroundStyle(Color.brandDeep)
                Text(label.uppercased())
                    .font(.custom(AppFont.PS.nunitoExtraBold, size: 25))
                    .tracking(3)
                    .foregroundStyle(Color.brandDeep.opacity(0.85))
                Spacer()
                Text("FoodieAI")
                    .font(.custom(AppFont.PS.mplusBlack, size: 22))
                    .foregroundStyle(Color.brandDeep.opacity(0.70))
                    .padding(.bottom, 28)
            }
            .padding(30)
        }
        .frame(width: 360, height: 360)
    }
}

/// Rasterizes a SwiftUI view into a shareable `Image` using the native
/// `ImageRenderer` (iOS 16+). Main-actor isolated because ImageRenderer is.
@MainActor
enum ShareCardRenderer {
    static func render<V: View>(_ view: V, scale: CGFloat = 3) -> Image? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let ui = renderer.uiImage else { return nil }
        return Image(uiImage: ui)
    }

    static func streakImage(days: Int, label: String) -> Image? {
        render(StreakShareCard(days: days, label: label))
    }
}


/// Reads today's movement from HealthKit (steps + active energy) so the goal
/// loop can reflect "I moved" — the activity half of the energy loop. Fully
/// guarded: every path no-ops when Health data is unavailable or read access
/// hasn't been granted, so the app behaves identically when HealthKit isn't
/// set up. Read-only — we never write to Health.
///
/// NOTE (device pass): functional only once the **HealthKit capability** is
/// added in Xcode → Signing & Capabilities (which registers the App ID
/// capability under automatic signing) and the user grants read access on a
/// real device. Adding the entitlement by hand without that registration is
/// what risks breaking signing, so it's intentionally left to the Xcode UI.
@MainActor
final class HealthActivityService: ObservableObject {
    static let shared = HealthActivityService()

    struct TodayActivity: Equatable {
        let steps: Int
        let activeEnergyKcal: Double
    }

    @Published private(set) var today: TodayActivity?
    /// True once the user has run the auth request without it erroring — i.e.
    /// the capability/provisioning is in place and they opted in. Read access
    /// itself is opaque (Apple hides it), so this only means "connected," not
    /// "granted." Persisted so the movement ring keeps showing across launches
    /// even before today's first steps land — e.g. just after local midnight.
    @Published private(set) var connected: Bool

    private let store = HKHealthStore()
    private let defaults: UserDefaults
    private let connectedKey = "foodie.health.connected.v1"
    /// Live-update plumbing — observer queries + a polling timer that run only
    /// while a movement surface is on screen (see `startLiveUpdates`).
    private var liveObservers: [HKObserverQuery] = []
    private var liveTimer: Timer?
    /// True while the sensor streams are running. Guards against the 2–3
    /// `startLiveUpdates` calls that fire in a burst on a foreground+active-tab
    /// transition tearing down and rebuilding the sensors needlessly.
    private var isLive = false

    /// Core Motion pedometer for *real-time* step updates. HealthKit only
    /// commits steps in delayed batches, so the ring would lag behind an
    /// active walk; `CMPedometer` streams the live cumulative count straight
    /// from the motion chip (~1s cadence). Foreground + real-device only.
    private let pedometer = CMPedometer()
    /// Last values from each source. We publish the *max* of the two step
    /// counts so the ring never visibly drops (HealthKit may include Watch
    /// steps; the pedometer is iPhone-only but instant).
    private var hkSteps: Int?
    private var hkEnergy: Double?
    private var liveSteps: Int?
    /// Live active-energy estimate derived from `liveSteps` × bodyweight (see
    /// `MovementEnergy.activeKcalFromSteps`). HealthKit has no live-calorie
    /// stream, so this walking-only estimate is what makes the active-kcal
    /// figure climb in real time; the measured HK value overtakes it (we
    /// publish the max) once HealthKit commits. Needs `liveWeightKg`.
    private var liveActiveKcal: Double?
    private var liveWeightKg: Double?
    /// The local day the live streams were armed for. The pedometer's cumulative
    /// count is anchored to the midnight it started from, so if the app stays
    /// open across midnight we must re-arm to reset to the new day (see `tick`).
    private var liveStartDay: Date?
    /// Persistent HealthKit observer that keeps the home-screen widget fresh
    /// while the app is closed (see `enableWidgetBackgroundSync`). Distinct from
    /// `liveObservers` — this one is NOT torn down by `stopLiveUpdates`; it must
    /// outlive the foreground session so HealthKit can resume the app for it.
    private var widgetObserver: HKObserverQuery?
    /// True once `enableBackgroundDelivery` has succeeded, so we don't keep
    /// re-requesting it every foreground (it fails until step-read is granted).
    private var widgetBackgroundDeliveryOn = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.connected = defaults.bool(forKey: connectedKey)
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        return types
    }

    /// Request read access. HealthKit shows the system sheet at most once;
    /// returns false when Health is unavailable or the request errors (e.g.
    /// the capability isn't enabled yet).
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            if !connected {
                connected = true
                defaults.set(true, forKey: connectedKey)
            }
            // Now that read access is (likely) granted, arm the background
            // widget sync so it works this very session — not just after the
            // next foreground.
            enableWidgetBackgroundSync()
            return true
        } catch {
            return false
        }
    }

    /// Keep the home-screen widget's step count fresh while the app is closed,
    /// at low battery cost. iOS wakes the app in the background — at most
    /// **hourly** for steps, never per-footstep — when new step data lands; we
    /// query today's steps and update just the widget snapshot's `steps` field.
    /// This is the ceiling iOS allows: truly live (per-step) widget updates from
    /// a closed app aren't possible on the platform. Idempotent — safe to call
    /// on every foreground; re-requests background delivery until it succeeds
    /// (it fails until the user grants step-read access). Requires the HealthKit
    /// Background Delivery entitlement.
    func enableWidgetBackgroundSync(timeZone: TimeZone = .current) {
        guard isAvailable,
              let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }

        // Execute the long-lived observer once per process. Its handler is what
        // HealthKit invokes (by resuming the app) when new step data arrives.
        if widgetObserver == nil {
            let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    await self?.syncWidgetSteps(timeZone: timeZone)
                    completion()   // MUST signal completion or HealthKit stops delivering
                }
            }
            store.execute(query)
            widgetObserver = query
        }

        guard !widgetBackgroundDeliveryOn else { return }
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { [weak self] success, _ in
            guard success else { return }
            Task { @MainActor in self?.widgetBackgroundDeliveryOn = true }
        }
    }

    /// Background path: refresh only the widget's step count from HealthKit.
    /// The other daily figures are owned by the foreground app (a step doesn't
    /// change calories/streak), so we leave them as last written.
    func syncWidgetSteps(timeZone: TimeZone = .current) async {
        guard let steps = await sum(.stepCount, unit: .count(), timeZone: timeZone) else { return }
        WidgetSnapshotUpdater.updateSteps(Int(steps))
    }

    /// Load today's totals for the user's local day. Surfaces a card only
    /// when Health actually returned a value; otherwise clears it. Live
    /// pedometer steps (if any) are merged in via `publishActivity`.
    func refreshToday(timeZone: TimeZone = .current) async {
        guard isAvailable else { return }
        async let steps = sum(.stepCount, unit: .count(), timeZone: timeZone)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), timeZone: timeZone)
        let s = await steps
        let e = await energy
        hkSteps = s.map { Int($0) }
        hkEnergy = e
        publishActivity()
    }

    /// Combine the live + batched sources into the published `today`. Both
    /// steps and active energy publish the *larger* of (live, measured) so the
    /// ring never jumps backward; clears `today` only when nothing has data.
    private func publishActivity() {
        let steps = maxOptional(liveSteps, hkSteps)
        let energy = maxOptional(liveActiveKcal, hkEnergy)
        if steps == nil && energy == nil {
            today = nil
        } else {
            today = TodayActivity(steps: steps ?? 0, activeEnergyKcal: energy ?? 0)
        }
    }

    private func maxOptional<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (x?, y?): return Swift.max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    /// Apply a fresh live step count from the pedometer stream, and refresh the
    /// step-derived live active-energy estimate alongside it.
    private func applyLiveSteps(_ steps: Int) {
        liveSteps = steps
        if let kg = liveWeightKg {
            let est = MovementEnergy.activeKcalFromSteps(steps, weightKg: kg)
            liveActiveKcal = est >= 1 ? est : nil
        }
        publishActivity()
    }

    /// Supply the bodyweight used for the live active-energy estimate. Safe to
    /// call as the profile loads/changes; recomputes against the current live
    /// step count without restarting the sensor streams.
    func setMovementWeight(_ kg: Double?) {
        guard liveWeightKg != kg else { return }
        liveWeightKg = kg
        if let steps = liveSteps { applyLiveSteps(steps) }
    }

    /// Begin live-ish step/energy updates while a movement surface is visible.
    /// Two mechanisms, because HealthKit writes pedometer data in batches:
    ///   - an `HKObserverQuery` that re-fetches the instant new data lands, and
    ///   - a light 30s polling timer that catches the in-between so the ring
    ///     keeps climbing as you walk.
    /// Call from `.onAppear`; ALWAYS pair with `stopLiveUpdates()` on disappear
    /// so observers/timers don't leak. Foreground-only (no background delivery).
    func startLiveUpdates(timeZone: TimeZone = .current, weightKg: Double? = nil) {
        if let weightKg { liveWeightKg = weightKg }
        // Already streaming → don't churn the sensors. Callers fire this 2–3×
        // in a burst on a foreground+active-tab transition; just keep the
        // estimate weight current and bail.
        guard !isLive else {
            if let steps = liveSteps { applyLiveSteps(steps) }
            return
        }
        stopLiveUpdates()  // clean slate (also resets isLive)
        isLive = true

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: Date())
        liveStartDay = startOfDay

        // Real-time path: stream live cumulative steps since local midnight.
        // This is what actually makes the ring climb as you walk; the
        // HealthKit observers below only catch up energy + a Watch-inclusive
        // total in the background.
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startOfDay) { [weak self] data, error in
                guard let data, error == nil else { return }
                let steps = data.numberOfSteps.intValue
                Task { @MainActor in self?.applyLiveSteps(steps) }
            }
        }

        guard isAvailable else { return }
        for id in [HKQuantityTypeIdentifier.stepCount, .activeEnergyBurned] {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    await self?.refreshToday(timeZone: timeZone)
                    completion()
                }
            }
            store.execute(query)
            liveObservers.append(query)
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick(timeZone: timeZone) }
        }
    }

    /// Periodic live refresh. If the local day rolled over while the app stayed
    /// open, re-arm the streams so the pedometer restarts from the new midnight
    /// — its cumulative count is anchored to the day it started, so without this
    /// an app left open past midnight would keep showing yesterday's steps.
    private func tick(timeZone: TimeZone) async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if let day = liveStartDay, !cal.isDate(day, inSameDayAs: Date()) {
            let kg = liveWeightKg
            stopLiveUpdates()                                    // clears the stale live count
            startLiveUpdates(timeZone: timeZone, weightKg: kg)   // re-anchors to today's midnight
        }
        await refreshToday(timeZone: timeZone)
    }

    /// Tear down the live observers, polling timer, and pedometer stream.
    /// Idempotent. Clears the cached live count so a later restart (e.g. after
    /// a day rollover) can't briefly publish yesterday's total.
    func stopLiveUpdates() {
        for query in liveObservers { store.stop(query) }
        liveObservers.removeAll()
        liveTimer?.invalidate()
        liveTimer = nil
        if CMPedometer.isStepCountingAvailable() {
            pedometer.stopUpdates()
        }
        liveSteps = nil
        liveActiveKcal = nil
        liveStartDay = nil
        isLive = false
    }

    private func sum(_ id: HKQuantityTypeIdentifier,
                     unit: HKUnit,
                     timeZone: TimeZone) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}

// MARK: - Daily Loop hero (extracted observing subview)

/// The paired calories + movement rings, pulled out of `TodayView` into its own
/// view. `HealthActivityService` is `@ObservedObject` HERE (not on TodayView),
/// so a live step/active-energy tick invalidates ONLY this subview — not the
/// ~2,400-line TodayView body, which used to re-run `MealSuggestionEngine` +
/// `DayCalorieStanding` on every footstep. Calorie/profile inputs are passed in,
/// so a meal log re-renders the parent (and this), while a step re-renders only
/// this. The parent keeps its own non-observed reads of `health` for the widget
/// snapshot + eat-to-goal card, which don't need to update per step.
private struct DailyLoopHeroView: View {
    let calories: Double
    let calorieGoal: Double
    let profile: Profile?
    @ObservedObject var health = HealthActivityService.shared

    private var movementGuidance: MovementGuidance.Result {
        MovementGuidance.compute(
            direction: profile?.weightGoalDirection,
            ageYears: profile?.ageYears,
            currentSteps: health.today?.steps ?? 0,
            consumed: calories,
            calorieGoal: calorieGoal,
            weightKg: profile?.weightKg
        )
    }
    private var dailyStepGoal: Int { movementGuidance.stepGoal }
    private var movementGoalSuggestion: String { movementGuidance.line }
    private var movementCreditKcal: Double {
        guard let profile, let activity = health.today else { return 0 }
        return MovementEnergy.budgetCredit(
            profile: profile,
            activeEnergyKcal: activity.activeEnergyKcal,
            steps: activity.steps
        )
    }

    private enum CalorieRingStanding: Equatable { case under, approaching, onGoal, over }
    private static let calorieToleranceKcal = DayCalorieStanding.onGoalToleranceKcal
    private static func calorieRingStanding(consumed: Double, goal: Double) -> CalorieRingStanding {
        guard goal > 0, consumed.isFinite else { return .under }
        let tol = calorieToleranceKcal
        if consumed >= goal + tol { return .over }
        if consumed >= goal - tol { return .onGoal }
        if consumed >= 0.80 * goal { return .approaching }
        return .under
    }

    var body: some View {
        let baseGoal = calorieGoal
        let credit = movementCreditKcal
        let effectiveGoal = baseGoal + credit
        let standing = Self.calorieRingStanding(consumed: calories, goal: effectiveGoal)
        VStack(spacing: AppSpacing.md) {
            if health.today != nil || health.connected {
                let activity = health.today
                HStack(alignment: .top, spacing: AppSpacing.xl) {
                    ringColumn(
                        value: calories, goal: effectiveGoal,
                        number: Self.heroNumber(calories), unit: "kcal",
                        tint: standing == .over ? .error : .brand,
                        caption: "energy in",
                        sub: credit >= 1
                            ? "of \(Self.heroNumber(baseGoal)) +\(Self.heroNumber(credit)) moved"
                            : "of \(Self.heroNumber(baseGoal))",
                        diameter: 128
                    )
                    ringColumn(
                        value: Double(activity?.steps ?? 0),
                        goal: Double(dailyStepGoal),
                        number: Self.heroNumber(Double(activity?.steps ?? 0)),
                        unit: "steps",
                        tint: .accentCool,
                        caption: "moving",
                        sub: movementSubtitle(activity),
                        diameter: 128
                    )
                }
                if credit >= 1 {
                    movementCreditChip(credit)
                }
                Text(movementGoalSuggestion)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.sm)
            } else {
                MetricRing(
                    value: calories, goal: baseGoal,
                    number: Self.heroNumber(calories), unit: "kcal",
                    tint: standing == .over ? .error : .brand,
                    diameter: 172
                )
                Text("of \(Self.heroNumber(baseGoal)) kcal goal")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                if health.isAvailable {
                    connectMovementCard
                }
            }
            calorieWarningCaption(standing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, AppSpacing.md)
        .animation(.appReduced, value: standing)
        .task { await health.refreshToday() }
    }

    private func movementCreditChip(_ credit: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .bold))
            Text("Moving earned back ~\(Self.heroNumber(credit)) kcal of room")
                .appFont(.captionStrong)
        }
        .foregroundStyle(Color.accentCool)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.brandSoft))
        .accessibilityLabel("Moving earned back about \(Self.heroNumber(credit)) calories of eating room.")
    }

    private func movementSubtitle(_ activity: HealthActivityService.TodayActivity?) -> String {
        guard let activity else { return "no data yet" }
        if activity.activeEnergyKcal >= 1 {
            return "~\(Int(activity.activeEnergyKcal.rounded())) kcal active"
        }
        return "goal \(Self.heroNumber(Double(dailyStepGoal)))"
    }

    private func ringColumn(value: Double, goal: Double,
                            number: String, unit: String, tint: Color,
                            caption: String, sub: String,
                            diameter: CGFloat) -> some View {
        VStack(spacing: AppSpacing.xs) {
            MetricRing(value: value, goal: goal, number: number,
                       unit: unit, tint: tint, diameter: diameter)
            Text(caption.uppercased())
                .appFont(.labelEyebrow)
                .foregroundStyle(Color.inkMute)
            Text(sub)
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectMovementCard: some View {
        Button {
            Task {
                await health.requestAuthorization()
                await health.refreshToday()
            }
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                ZStack {
                    Circle().fill(Color.brandSoft).frame(width: 42, height: 42)
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentCool)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your movement")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                    Text("Connect Apple Health to show today's steps and active calories next to your goal — your full energy loop, in and out.")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Connect Apple Health")
                            .appFont(.captionStrong)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundStyle(Color.brandDeep)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(
                        LinearGradient(
                            colors: [Color.brandSoft.opacity(0.85), Color.bgSurface],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
            )
            .appShadow(.shadowCard)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(.plain)
        .padding(.top, AppSpacing.sm)
        .accessibilityLabel("Add your movement. Connect Apple Health to show today's steps and active calories next to your goal.")
    }

    @ViewBuilder
    private func calorieWarningCaption(_ standing: CalorieRingStanding) -> some View {
        switch standing {
        case .under:
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
        case .onGoal:
            VStack(spacing: 2) {
                Text("Right on your goal today")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Text("Nicely balanced — a little room either way is fine.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        case .over:
            VStack(spacing: 2) {
                Text("A little over today")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Text("No big deal — tomorrow's a fresh start.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        }
    }

    private static func heroNumber(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return heroFormatter.string(from: NSNumber(value: v.rounded()))
            ?? "\(Int(v.rounded()))"
    }
    private static let heroFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
