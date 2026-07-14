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

    /// NOVEL_DIRECTIONS Idea 2 — the user's meal repertoire (name / calories /
    /// slot / mood), built once from ~30 days of history and reused by the Meal
    /// Twin card. One cached fetch; refetched when the tab first activates and
    /// after a new save (`twinRepertoireToken`), never per render.
    @State private var twinRepertoire: [TwinMeal] = []
    @State private var twinRepertoireToken = 0
    private let twinLogService = FoodLogService()

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

    /// Activation: a one-time "scan your first meal" nudge for brand-new users
    /// who haven't logged anything yet — the single highest-leverage action.
    /// `firstScanLogged` is loaded per-user from UserDefaults on appear / when
    /// the account changes (see `loadFirstScanFlag`); the dismiss is
    /// session-only. Built from already-loaded state, so zero egress.
    @State private var firstScanLogged = false
    @State private var firstScanNudgeDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                dateHeader
                streakRepairBanner
                personalizeGoalsCard
                freezeNoticeBanner
                firstScanNudge
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
                loadFirstScanFlag()
            }
            // Account changed (sign-in / switch / delete+recreate) → reload the
            // per-user flag so the nudge reflects the new account, not the old.
            .onChange(of: profileStore.profile?.id) { _, _ in loadFirstScanFlag() }
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
        // Meal Twin repertoire: load on appear + whenever the token bumps
        // (tab first activates / a meal is saved). The fetch/build run off-main;
        // only the assignment lands here on the main actor.
        .task(id: twinRepertoireToken) {
            guard isActive else { return }
            twinRepertoire = await fetchTwinRepertoire()
        }
        .onReceive(NotificationCenter.default.publisher(for: .foodLogDidChange)) { _ in
            twinRepertoireToken &+= 1
        }
        .onChange(of: isActive) { _, active in
            if active {
                scheduleAutomaticRefresh(reason: .tabBecameActive)
                health.startLiveUpdates(weightKg: profileStore.profile?.weightKg)
                // First activation with no repertoire yet → fetch it once.
                if twinRepertoire.isEmpty { twinRepertoireToken &+= 1 }
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
        if !eatSuggestionDismissed, topSoftNudge == .eatToGoal, let suggestion = eatToGoalSuggestion {
            EatToGoalCard(
                suggestion: suggestion,
                twin: twinData,
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

    // MARK: - One Brain surface policy (NOVEL_DIRECTIONS Idea 1)

    /// Among the eligible *soft* advisory nudges (first-scan, eat-to-goal,
    /// personalize), the single most relevant one to show, chosen by
    /// `SurfacePolicy`. The two time-critical banners (streak repair, freeze
    /// notice) are NOT arbitrated here and always show. This collapses an
    /// up-to-three-card stack into one, so Today speaks with one voice instead
    /// of piling advice. `nil` when no soft nudge is eligible.
    private var topSoftNudge: SurfaceKind? {
        let ctx = softNudgeContext
        var candidates: [SurfaceCandidate] = []
        if showFirstScanNudge {
            candidates.append(SurfacePolicy.make(.firstScan, basePriority: 50, eligible: true, context: ctx))
        }
        if !eatSuggestionDismissed, eatToGoalSuggestion != nil {
            candidates.append(SurfacePolicy.make(.eatToGoal, basePriority: 50, eligible: true, context: ctx))
        }
        if needsPersonalization, !personalizeDismissed {
            candidates.append(SurfacePolicy.make(.personalize, basePriority: 50, eligible: true, context: ctx))
        }
        return SurfacePolicy.top(candidates)?.kind
    }

    /// The state vector the soft-nudge policy scores against, from data already
    /// loaded on this tab (zero egress). Only `hour` and the remaining-budget
    /// fraction actually move these kinds; the rest are neutral here.
    private var softNudgeContext: SurfaceContext {
        var remainingFraction = 1.0
        if case .loaded(_, let totals) = viewModel.state {
            let goal = Double(max(1, profileStore.calorieGoal + movementCreditKcal))
            remainingFraction = min(max((goal - Double(totals.totalCalories)) / goal, 0), 1)
        }
        return SurfaceContext(
            hour: Calendar.current.component(.hour, from: Date()),
            remainingBudgetFraction: remainingFraction,
            streakAtRisk: false,
            daysSinceLastLog: 0,
            recentMoodPositiveRate: 0.5
        )
    }

    // MARK: - Meal Twin (NOVEL_DIRECTIONS Idea 2)

    /// One cached ~30-day history fetch, turned into the repertoire. Best-effort.
    private func fetchTwinRepertoire() async -> [TwinMeal] {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        guard let logs = try? await twinLogService.logs(from: start, to: now) else { return [] }
        return TwinMealBuilder.build(from: logs, timeZone: .current)
    }

    /// The Meal Twin card payload — a forward projection + one mood-aware move —
    /// or nil when there's no repertoire/move yet (the card then shows the
    /// generic suggestion fallback, so the surface never blanks). Built from
    /// data already loaded here + the cached repertoire; the engine is pure.
    private var twinData: EatToGoalCard.TwinData? {
        guard case .loaded(let logs, let totals) = viewModel.state,
              !twinRepertoire.isEmpty else { return nil }
        let effectiveGoal = profileStore.calorieGoal + movementCreditKcal
        let loggedSlots = Set(logs.compactMap {
            MealSuggestionEngine.MealSlot.forHour(
                Calendar.current.component(.hour, from: $0.eatenAt))
        })
        let context = MealTwinContext(
            hour: Calendar.current.component(.hour, from: Date()),
            consumedSoFar: totals.totalCalories,
            goal: effectiveGoal,
            direction: profileStore.profile?.weightGoalDirection,
            loggedSlots: loggedSlots,
            typicalMeals: twinRepertoire
        )
        let projection = MealTwinEngine.project(context)
        guard let move = projection.move else { return nil }
        return EatToGoalCard.TwinData(
            headline: twinHeadline(vsGoal: projection.baselineVsGoal),
            move: move,
            consumed: totals.totalCalories,
            projectedLanding: projection.baselineLandingKcal,
            goal: effectiveGoal
        )
    }

    /// Factual, direction-agnostic framing of the "do nothing" trajectory —
    /// the move row carries the goal-aware judgment.
    private func twinHeadline(vsGoal: Double) -> String {
        let tolerance = DayCalorieStanding.onGoalToleranceKcal
        if abs(vsGoal) <= tolerance { return "On track for today" }
        let rounded = Int((abs(vsGoal) / 10).rounded() * 10)
        return vsGoal > 0 ? "Heading to \(rounded) over" : "\(rounded) to go today"
    }

    // MARK: - First-scan activation nudge

    /// Shown to a brand-new user (recently onboarded, nothing logged yet) with
    /// an empty day, to drive the most important activation action: their first
    /// scan. "Scan a meal" jumps to the Home/capture tab; × dismisses for the
    /// session. Reuses the peer-card treatment with a brand-tinted border so it
    /// reads as the day's primary call to action.
    @ViewBuilder
    private var firstScanNudge: some View {
        if showFirstScanNudge, topSoftNudge == .firstScan {
            FirstScanCard(
                onScan: {
                    Haptics.tap()
                    markFirstScanLogged()       // acting on it, don't re-nag
                    notifRouter.requestTab(0)
                },
                onDismiss: {
                    Haptics.tap()
                    withAnimation(.appReveal) { firstScanNudgeDismissed = true }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var showFirstScanNudge: Bool {
        guard isRecentlyOnboarded, !firstScanLogged, !firstScanNudgeDismissed else { return false }
        if case .empty = viewModel.state { return true }
        return false
    }

    /// True for the first week after onboarding — the window where driving the
    /// first scan matters. Keeps the nudge off returning users' ordinary empty
    /// days (they'd never have a nil `onboardingCompletedAt` from long ago).
    private var isRecentlyOnboarded: Bool {
        guard let completedAt = profileStore.profile?.onboardingCompletedAt else { return false }
        return Date().timeIntervalSince(completedAt) < 7 * 24 * 3600
    }

    /// (Re)load the per-user first-scan flag. Called on appear AND whenever the
    /// signed-in account changes, so the flag always reflects THIS account and
    /// can't inherit a prior account's state on the same device.
    private func loadFirstScanFlag() {
        firstScanLogged = UserDefaults.standard.bool(
            forKey: ActivationFlags.firstScanLoggedKey(profileStore.profile?.id))
    }

    /// Persist that this account has logged its first meal — retires the nudge
    /// for good, for this account only (survives relaunch).
    private func markFirstScanLogged() {
        guard !firstScanLogged else { return }
        firstScanLogged = true
        UserDefaults.standard.set(
            true, forKey: ActivationFlags.firstScanLoggedKey(profileStore.profile?.id))
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
                    Text("You missed a few days, no worries. Restore your run and pick up right where you left off.")
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
        if needsPersonalization, !personalizeDismissed, topSoftNudge == .personalize {
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
                        Text("You missed a day, but your \(notice.streakDays)-day run is still going. No pressure, pick back up whenever.")
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
        // direction-aware. Computed against the EFFECTIVE goal (base +
        // movement credit) — the same denominator the in-app ring uses — so
        // the widget's coach line and over/under never contradict the ring on
        // an active day. The credit is passed to the snapshot too; the widget
        // recombines base + credit via `effectiveCalorieGoal`.
        let credit = movementCreditKcal
        let standing = DayCalorieStanding.compute(
            dayCalories: caloriesFromState,
            goal: profileStore.calorieGoal + credit,
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
            calorieGoal: Int(profileStore.calorieGoal.rounded()),   // BASE goal; credit passed separately
            steps: steps,
            stepGoal: dailyStepGoal,
            suggestion: standing?.recommendation ?? "",
            movementCreditKcal: Int(credit.rounded())
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
                reachedPraise: "Nice, this supports fullness and recovery."
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
                    reachedPraise: "Nice, fiber helps fullness and digestion."
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
            .onAppear {
                hasShownInitialMeals = true
                // They've logged at least one meal — retire the first-scan
                // nudge for good, for this account (survives relaunch).
                markFirstScanLogged()
            }
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



