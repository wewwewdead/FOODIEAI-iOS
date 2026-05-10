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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                dateHeader
                weeklyRecapBanner
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
    @ViewBuilder
    private var weeklyRecapBanner: some View {
        if let recap = viewModel.latestRecap {
            Button {
                Haptics.tap()
                showingRecap = true
            } label: {
                HStack(spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.brandSoft)
                            .frame(width: 36, height: 36)
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.brandDeep)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This week")
                            .appFont(.captionStrong)
                            .foregroundStyle(Color.inkMute)
                        Text(recap.headlineStat ?? recap.coachName)
                            .appFont(.title2)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
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
                        .strokeBorder(Color.borderHairline, lineWidth: 1)
                )
                .appShadow(.shadowCard)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("This week's recap. Tap to read.")
        }
    }

    // MARK: - Date header

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(eyebrowDate(Date())).eyebrow()
                .foregroundStyle(Color.inkMute)
            Text(headlineDate(Date()))
                .appFont(.display2)
                .foregroundStyle(Color.ink)
        }
    }

    // MARK: - Progress ring

    @ViewBuilder
    private var ringBlock: some View {
        let calories = caloriesFromState
        VStack(spacing: 0) {
            ProgressRing(
                value: calories,
                goal: profileStore.calorieGoal,
                label: "Calories"
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, AppSpacing.md)
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
                tint: .accentCool
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
                    tint: .success
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
                    .animation(
                        .appBouncy.delay(Double(idx) * 0.04),
                        value: logs.count
                    )
                }
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

    // MARK: - Date formatting

    private func eyebrowDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func headlineDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM d"
        return f.string(from: date)
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
