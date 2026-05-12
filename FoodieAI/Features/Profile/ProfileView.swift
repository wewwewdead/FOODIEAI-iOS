import SwiftUI

/// Profile tab. Read + UPDATE only — the row is auto-created by the
/// `handle_new_user` DB trigger.
///
/// Visual language: a hero identity card anchors the screen against a
/// soft brand-lime canvas wash. Below, eyebrow-labelled sections group
/// the form into "About you", "Daily targets", "Guidance", and
/// "Preferences". Goal rows are tagged with macro color-dots; nav rows
/// have tactile press states; sections cascade in with a staggered
/// spring on first paint.
struct ProfileView: View {
    @EnvironmentObject private var auth: AuthService
    /// Optional because the Phase 7 verification probes
    /// (LAUNCH_PROFILE_DIRECT, LAUNCH_PROFILE_UPDATE_PROBE) instantiate
    /// ProfileView outside the MainTabView host that supplies the store.
    /// In the normal user flow (RootView → MainTabView), the store is
    /// always present and changes propagate to Tracker.
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var viewModel: ProfileViewModel
    @State private var showingAbout = false
    @State private var hasAppeared = false
    @FocusState private var nameFieldFocused: Bool

    init() {
        // We can't read @EnvironmentObject during init; ProfileViewModel
        // takes the AuthService reference here for sign-out delegation.
        _viewModel = StateObject(wrappedValue: ProfileViewModel(auth: AuthService()))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                profileBackground
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.lastResolvedProfile) { _, newProfile in
            // Broadcast every successful load/save into the shared store
            // so Tracker (and any other observer) re-renders with the
            // updated daily goals without a manual refresh.
            if let profile = newProfile {
                profileStore.apply(profile)
            }
        }
        .sheet(isPresented: $showingAbout) {
            AboutSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    /// Soft atmospheric wash: bgCanvas tinted with two large radial
    /// glows in brand and brandBright. Painted via `.overlay` so the
    /// 560pt blob frames sit *on top of* the canvas without growing the
    /// parent ZStack — a plain `ZStack { Color … Circle.frame(560) }`
    /// adopts 560pt as its intrinsic width and shoves the entire
    /// ScrollView past the screen edges on phone form factors.
    /// `.clipped()` keeps the blurred edges inside the canvas bounds.
    private var profileBackground: some View {
        Color.bgCanvas
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.brand.opacity(0.22), Color.brand.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 280
                        )
                    )
                    .frame(width: 560, height: 560)
                    .offset(x: 160, y: -260)
                    .blur(radius: 10)
            }
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.brandBright.opacity(0.18), Color.brandBright.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 240
                        )
                    )
                    .frame(width: 480, height: 480)
                    .offset(x: -180, y: 180)
                    .blur(radius: 8)
            }
            .clipped()
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            loadingView
        case .loaded(let profile):
            loadedForm(profile: profile)
        case .failed(let error):
            failedView(error: error)
        }
    }

    private var loadingView: some View {
        VStack(spacing: AppSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.brand)
            Text("Loading your profile…")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loaded form

    private func loadedForm(profile: Profile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                heroCard(profile: profile)
                    .staggered(0, appeared: hasAppeared)

                sectionGroup(title: "ABOUT YOU", icon: "person.fill") {
                    displayNameSection
                }
                .staggered(1, appeared: hasAppeared)

                sectionGroup(title: "DAILY TARGETS", icon: "target") {
                    VStack(spacing: AppSpacing.md) {
                        personalizeTargetsRow
                        targetsExplainer(profile: profile)
                        goalsSection
                    }
                }
                .staggered(2, appeared: hasAppeared)

                sectionGroup(title: "GUIDANCE", icon: "sparkles") {
                    VStack(spacing: AppSpacing.sm) {
                        coachesSection
                        moodLogSection
                    }
                }
                .staggered(3, appeared: hasAppeared)

                sectionGroup(title: "PREFERENCES", icon: "slider.horizontal.3") {
                    notificationsSection
                }
                .staggered(4, appeared: hasAppeared)

                VStack(spacing: AppSpacing.sm) {
                    saveButton
                    if let saveError = viewModel.saveError {
                        errorBanner(saveError)
                    }
                }
                .staggered(5, appeared: hasAppeared)

                signOutSection
                    .staggered(6, appeared: hasAppeared)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if !hasAppeared { hasAppeared = true }
        }
    }

    // MARK: - Hero identity card

    private func heroCard(profile: Profile) -> some View {
        // Pull from the draft so editing the display-name field updates
        // the hero in real time — the most "alive" touch on the page.
        let resolvedName = !viewModel.displayNameDraft.isEmpty
            ? viewModel.displayNameDraft
            : (profile.displayName ?? "")
        let initial = String(resolvedName.prefix(1)).uppercased()
        let email = auth.session?.user.email ?? ""

        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.brand, Color.brandBright.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            DotGridDecoration()
                .opacity(0.16)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    avatarCircle(initial: initial)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hey \(resolvedName.isEmpty ? "there" : resolvedName) 👋")
                            .appFont(.display2)
                            .foregroundStyle(Color.greenCalorie)
                            .lineLimit(2)
                            .minimumScaleFactor(0.55)
                            .fixedSize(horizontal: false, vertical: true)
                        if !email.isEmpty {
                            Text(email)
                                .appFont(.caption)
                                .foregroundStyle(Color.greenCalorie.opacity(0.65))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Chip row falls back to a vertical stack on narrow
                // screens (notably mini/SE form factors) before either
                // chip gets clipped at the trailing edge of the hero.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppSpacing.sm) {
                        memberChip(date: profile.createdAt)
                        if let goal = profile.weightGoalDirection {
                            goalChip(goal: goal)
                        }
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        memberChip(date: profile.createdAt)
                        if let goal = profile.weightGoalDirection {
                            goalChip(goal: goal)
                        }
                    }
                }
            }
            .padding(AppSpacing.lg)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl2)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
        )
        .appShadow(.shadowCta)
    }

    private func avatarCircle(initial: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.bgSurface)
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
            Text(initial.isEmpty ? "F" : initial)
                .font(.custom(AppFont.PS.mplusBlack, size: 30))
                .foregroundStyle(Color.brandDeep)
        }
        .frame(width: 68, height: 68)
        .appShadow(.shadowFloating)
        .scaleEffect(hasAppeared ? 1.0 : 0.55)
        .rotationEffect(.degrees(hasAppeared ? 0 : -12))
        .animation(.appBouncy.delay(0.18), value: hasAppeared)
    }

    private func memberChip(date: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .heavy))
            Text("Since \(memberSince(date))")
                .appFont(.captionStrong)
        }
        .foregroundStyle(Color.greenCalorie)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.bgSurface.opacity(0.88)))
    }

    private func goalChip(goal: CalorieGoalCalculator.GoalDirection) -> some View {
        let icon: String = {
            switch goal {
            case .lose:     return "arrow.down.right"
            case .maintain: return "equal"
            case .gain:     return "arrow.up.right"
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .black))
            Text(goal.displayLabel)
                .appFont(.captionStrong)
        }
        .foregroundStyle(Color.greenCalorie)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.bgSurface.opacity(0.88)))
    }

    // MARK: - Section group

    private func sectionGroup<C: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .black))
                Text(title).eyebrow()
            }
            .foregroundStyle(Color.brandDeep)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Display name field

    private var displayNameSection: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "pencil.line")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(nameFieldFocused ? Color.brandDeep : Color.inkLight)

            TextField("How should we greet you?", text: $viewModel.displayNameDraft)
                .font(AppFont.font(.bodyEmphasis))
                .foregroundStyle(Color.textPrimary)
                .tint(Color.brand)
                .focused($nameFieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(TextInputAutocapitalization.words)

            if !viewModel.displayNameDraft.isEmpty {
                Button {
                    Haptics.tap()
                    viewModel.displayNameDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.inkLight)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(
                    nameFieldFocused ? Color.brand : Color.borderHairline,
                    lineWidth: nameFieldFocused ? 2 : 1.5
                )
        )
        .appShadow(.shadowCard)
        .animation(.appPress, value: nameFieldFocused)
        .animation(.appPress, value: viewModel.displayNameDraft.isEmpty)
    }

    // MARK: - Personalize targets row + explainer

    /// Phase 20. NavigationLink row → PhysiologyEditorView.
    private var personalizeTargetsRow: some View {
        NavigationLink {
            PhysiologyEditorView()
                .environmentObject(profileStore)
        } label: {
            navRowChrome(
                icon: "figure.mind.and.body",
                title: "Personalize my targets",
                subtitle: personalizeSummary
            )
        }
        .buttonStyle(PressableRowStyle())
    }

    private var personalizeSummary: String {
        guard let profile = profileStore.profile,
              profile.biologicalSex != nil,
              profile.ageYears != nil,
              profile.heightCm != nil,
              profile.weightKg != nil,
              profile.activityLevel != nil,
              profile.weightGoalDirection != nil else {
            return "Tap to compute targets from your physiology"
        }
        var parts: [String] = []
        if let activity = profile.activityLevel { parts.append(activity.shortLabel) }
        if let goal = profile.weightGoalDirection { parts.append(goal.displayLabel.lowercased()) }
        return parts.isEmpty ? "Tap to revise" : parts.joined(separator: " · ")
    }

    /// Phase 20. Hidden by default — only shown after the user has
    /// completed the physiology form.
    @ViewBuilder
    private func targetsExplainer(profile: Profile) -> some View {
        if let sex = profile.biologicalSex,
           let age = profile.ageYears,
           let height = profile.heightCm,
           let weight = profile.weightKg,
           let activity = profile.activityLevel,
           let goal = profile.weightGoalDirection {
            let phys = CalorieGoalCalculator.Physiology(
                sex: sex, ageYears: age, heightCm: height, weightKg: weight,
                activity: activity, goal: goal
            )
            let goals = CalorieGoalCalculator.compute(phys)
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .heavy))
                    Text("BEHIND YOUR NUMBERS").eyebrow()
                }
                .foregroundStyle(Color.brandDeep.opacity(0.85))

                explainerRow(label: "Resting energy (BMR)",  value: "\(goals.bmr) kcal")
                explainerRow(label: "Maintenance (TDEE)",    value: "\(goals.tdee) kcal")
                explainerRow(label: "Goal",                  value: goalDirectionLine(goal: goal))
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.brandSoft.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.28), lineWidth: 1.5)
            )
        }
    }

    private func explainerRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
            Spacer()
            Text(value)
                .appFont(.captionStrong)
                .foregroundStyle(Color.brandDeep)
                .monospacedDigit()
        }
    }

    private func goalDirectionLine(goal: CalorieGoalCalculator.GoalDirection) -> String {
        switch goal {
        case .lose:     return "Deficit: −500 kcal/day"
        case .maintain: return "Maintenance"
        case .gain:     return "Surplus: +500 kcal/day"
        }
    }

    // MARK: - Coaches / Mood / Notifications

    private var coachesSection: some View {
        NavigationLink {
            CoachPreferencesView()
                .environmentObject(profileStore)
        } label: {
            navRowChrome(
                icon: "person.2.crop.square.stack.fill",
                title: "Coaches",
                subtitle: coachesSummary
            )
        }
        .buttonStyle(PressableRowStyle())
    }

    private var coachesSummary: String {
        let count = profileStore.profile?.preferredCoaches.count ?? 0
        if count == 0 { return "Tap to star your favorites" }
        if count == 1 { return "1 starred" }
        return "\(count) starred"
    }

    private var moodLogSection: some View {
        NavigationLink {
            MoodLogView()
        } label: {
            navRowChrome(
                icon: "heart.text.square.fill",
                title: "Mood log",
                subtitle: "How meals have hit recently"
            )
        }
        .buttonStyle(PressableRowStyle())
    }

    private var notificationsSection: some View {
        NavigationLink {
            NotificationSettingsView()
                .environmentObject(profileStore)
        } label: {
            navRowChrome(
                icon: "bell.badge.fill",
                title: "Notifications",
                subtitle: notificationsSummary
            )
        }
        .buttonStyle(PressableRowStyle())
    }

    private var notificationsSummary: String {
        guard let profile = profileStore.profile else {
            return "Off"
        }
        if !profile.notificationsEnabled { return "Off" }
        var parts: [String] = []
        if profile.reminderBreakfast { parts.append("Breakfast") }
        if profile.reminderLunch     { parts.append("Lunch") }
        if profile.reminderDinner    { parts.append("Dinner") }
        if profile.weeklyRecapEnabled { parts.append("recap") }
        return parts.isEmpty ? "On (no reminders)" : parts.joined(separator: " · ")
    }

    /// Shared chrome for every nav-row card.
    private func navRowChrome(
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.brandDeep)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.inkLight)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1.5)
        )
        .appShadow(.shadowCard)
        .contentShape(Rectangle())
    }

    // MARK: - Goals

    /// Per-macro accent dots. Keys are the row's label string so the
    /// lookup site stays declarative — the dot colors give each row
    /// a tiny visual identity without needing to relabel the macros.
    private static let macroColors: [String: Color] = [
        "Calories":    .brand,
        "Carbs (g)":   .accentCool,
        "Sugar (g)":   .accentWarm,
        "Protein (g)": .success,
        "Fat (g)":     .catDrawbacksInk,
        "Fiber (g)":   .catBenefitsInk
    ]

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            recalculateButtons

            VStack(spacing: AppSpacing.sm) {
                goalRow(label: "Calories",
                        value: $viewModel.calorieGoalDraft,
                        range: 0...10_000, step: 50, unit: "")
                goalRow(label: "Carbs (g)",
                        value: $viewModel.carbGoalDraft,
                        range: 0...1_000, step: 5, unit: "g")
                goalRow(label: "Sugar (g)",
                        value: $viewModel.sugarGoalDraft,
                        range: 0...500, step: 5, unit: "g")
                goalRow(label: "Protein (g)",
                        value: $viewModel.proteinGoalDraft,
                        range: 0...1_000, step: 5, unit: "g")
                goalRow(label: "Fat (g)",
                        value: $viewModel.fatGoalDraft,
                        range: 0...1_000, step: 5, unit: "g")
                goalRow(label: "Fiber (g)",
                        value: $viewModel.fiberGoalDraft,
                        range: 0...500, step: 1, unit: "g")
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.inkLight)
                    .padding(.top, 1)
                Text("Defaults follow US Dietary Guidelines (50/25/25 carb/protein/fat with 14 g fiber per 1000 kcal). Adjust any value to match your needs.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Phase 20. Two convenience recalculation buttons.
    @ViewBuilder
    private var recalculateButtons: some View {
        let physiologyAvailable: Bool = {
            guard let p = profileStore.profile else { return false }
            return p.biologicalSex != nil
                && p.ageYears != nil
                && p.heightCm != nil
                && p.weightKg != nil
                && p.activityLevel != nil
                && p.weightGoalDirection != nil
        }()
        VStack(spacing: AppSpacing.xs) {
            if physiologyAvailable {
                Button {
                    Haptics.tap()
                    recalculateFromPhysiology()
                } label: {
                    recalcChrome(symbol: "figure.mind.and.body",
                                 title: "Recalculate from physiology",
                                 filled: true)
                }
                .buttonStyle(PressableRowStyle(scale: 0.96))
            }
            Button {
                Haptics.tap()
                recalculateMacrosFromCalories()
            } label: {
                recalcChrome(symbol: "arrow.triangle.2.circlepath",
                             title: "Recalculate macros from calories",
                             filled: false)
            }
            .buttonStyle(PressableRowStyle(scale: 0.96))
        }
    }

    private func recalcChrome(symbol: String,
                              title: String,
                              filled: Bool) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .heavy))
            Text(title)
                .appFont(.captionStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color.brandDeep)
        .padding(.horizontal, AppSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(
            Group {
                if filled {
                    Capsule().fill(Color.brandSoft)
                } else {
                    Capsule().strokeBorder(Color.borderHairline, lineWidth: 1.5)
                }
            }
        )
    }

    private func recalculateFromPhysiology() {
        guard let p = profileStore.profile,
              let sex = p.biologicalSex,
              let age = p.ageYears,
              let height = p.heightCm,
              let weight = p.weightKg,
              let activity = p.activityLevel,
              let goal = p.weightGoalDirection else { return }
        let goals = CalorieGoalCalculator.compute(.init(
            sex: sex, ageYears: age, heightCm: height, weightKg: weight,
            activity: activity, goal: goal
        ))
        withAnimation(.appBouncy) {
            viewModel.calorieGoalDraft = goals.calories
            viewModel.carbGoalDraft    = goals.carbsG
            viewModel.proteinGoalDraft = goals.proteinG
            viewModel.fatGoalDraft     = goals.fatG
            viewModel.fiberGoalDraft   = goals.fiberG
            viewModel.sugarGoalDraft   = goals.sugarG
        }
    }

    private func recalculateMacrosFromCalories() {
        let macros = CalorieGoalCalculator.macrosFromCalories(viewModel.calorieGoalDraft)
        withAnimation(.appBouncy) {
            viewModel.carbGoalDraft    = macros.carbsG
            viewModel.proteinGoalDraft = macros.proteinG
            viewModel.fatGoalDraft     = macros.fatG
            viewModel.fiberGoalDraft   = macros.fiberG
            viewModel.sugarGoalDraft   = macros.sugarG
        }
    }

    private func goalRow(label: String,
                         value: Binding<Int>,
                         range: ClosedRange<Int>,
                         step: Int,
                         unit: String) -> some View {
        // `step` retained in signature for call-site compatibility — unused
        // now that the input is a free-form numeric field (see Phase 12).
        _ = step
        let dot = Self.macroColors[label] ?? .brand
        let shortLabel = label.replacingOccurrences(of: " (g)", with: "")
        return HStack(spacing: AppSpacing.sm) {
            ZStack {
                Circle()
                    .fill(dot.opacity(0.18))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
            }
            // Label column has a soft cap so rows align visually, but it
            // shrinks (and scales the text down) on narrower screens
            // before fighting the number field for horizontal space.
            Text(shortLabel)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 86, alignment: .leading)
                .layoutPriority(0.5)

            Spacer(minLength: 0)

            GoalNumberField(value: value, range: range, unit: unit)
                .layoutPriority(1)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1.5)
        )
        .appShadow(.shadowCard)
    }

    // MARK: - Save / Error

    @ViewBuilder
    private var saveButton: some View {
        let active = viewModel.hasUnsavedChanges
        PillButton(
            title: viewModel.isSaving ? "Saving…" : "Save changes",
            variant: .primary,
            isLoading: viewModel.isSaving,
            isDisabled: !active
        ) {
            Task { await viewModel.save() }
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(active ? 1.0 : 0.985)
        // Brand-tinted glow only while the button is actionable, drawing
        // the eye without making the disabled state feel inert.
        .shadow(color: active ? Color.brand.opacity(0.35) : .clear,
                radius: active ? 18 : 0,
                x: 0, y: 8)
        .animation(.appBouncy, value: active)
    }

    private func errorBanner(_ error: Error) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.error)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't save")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.error)
                Text(error.localizedDescription)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            Spacer()
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.error.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.error.opacity(0.28), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var signOutSection: some View {
        VStack(spacing: AppSpacing.md) {
            PillButton(title: "Sign out", variant: .outline) {
                Task { await viewModel.signOut() }
            }
            .frame(maxWidth: .infinity)

            Text("You'll need to sign back in to access your meals.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(action: {
                Haptics.tap()
                showingAbout = true
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .heavy))
                    Text("About FoodieAI")
                        .appFont(.captionStrong)
                }
                .foregroundStyle(Color.brandDeep.opacity(0.85))
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.brandSoft.opacity(0.6)))
            }
            .buttonStyle(PressableRowStyle(scale: 0.94))
            .padding(.top, AppSpacing.xs)
        }
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Failed state

    private func failedView(error: Error) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 48, weight: .heavy))
                .foregroundStyle(Color.error.opacity(0.75))
            Text("Couldn't load your profile")
                .appFont(.title1)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            Text(error.localizedDescription)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
            PillButton(title: "Try again", variant: .outline) {
                Task { await viewModel.load() }
            }
        }
        .padding(AppSpacing.xl)
    }

    // MARK: - Helpers

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func memberSince(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }
}

// MARK: - Press-on-tap style for nav rows / chips

private struct PressableRowStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

// MARK: - Decorative dot grid for the hero card

private struct DotGridDecoration: View {
    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 18
            let radius: CGFloat = 1.4
            let cols = Int(size.width / spacing) + 1
            let rows = Int(size.height / spacing) + 1
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = CGFloat(c) * spacing + (r.isMultiple(of: 2) ? 0 : spacing / 2)
                    let y = CGFloat(r) * spacing
                    let rect = CGRect(x: x, y: y,
                                      width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .color(.greenCalorie.opacity(0.5)))
                }
            }
        }
    }
}

// MARK: - Staggered entrance modifier

private struct StaggeredAppearance: ViewModifier {
    let index: Int
    let appeared: Bool
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 28)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.85)
                    .delay(Double(index) * 0.06),
                value: appeared
            )
    }
}

extension View {
    fileprivate func staggered(_ index: Int, appeared: Bool) -> some View {
        modifier(StaggeredAppearance(index: index, appeared: appeared))
    }
}

// MARK: - Goal number field

/// Numeric text input for daily goals. Replaces the prior `Stepper`
/// affordance — users with goals like "2350" no longer have to tap +/-
/// 47 times.
///
/// Behavior:
///   - `.numberPad` keyboard, no decimal/sign keys.
///   - The buffer is filtered to ASCII digits 0–9 on every change, so
///     a paste of "2,400" or "300g" lands as "2400" / "300".
///   - Out-of-range values are clamped to the row's bounds; the buffer
///     is rewritten so the displayed text always matches the bound Int.
///   - Empty buffer is allowed *while editing* (so the user can clear
///     and retype) but normalizes to the row's lower bound on blur.
private struct GoalNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    @State private var buffer: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $buffer)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(AppFont.font(.kcal))
                .fontWeight(.heavy)
                .foregroundStyle(isFocused ? Color.brandDeep : Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(minWidth: 60, maxWidth: 130, alignment: .trailing)
                .focused($isFocused)
                .tint(Color.brand)
                .onAppear { buffer = String(value) }
                .onChange(of: value) { _, newValue in
                    if Int(buffer) != newValue {
                        buffer = String(newValue)
                    }
                }
                .onChange(of: buffer) { _, newText in
                    let filtered = newText.filter { ("0"..."9").contains($0) }
                    if filtered != newText {
                        buffer = filtered
                        return
                    }
                    guard !filtered.isEmpty, let parsed = Int(filtered) else {
                        return
                    }
                    let clamped = min(max(parsed, range.lowerBound),
                                      range.upperBound)
                    let normalized = String(clamped)
                    if normalized != filtered {
                        buffer = normalized
                        return
                    }
                    if clamped != value {
                        value = clamped
                        Haptics.selection()
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        if buffer.isEmpty {
                            value = range.lowerBound
                            buffer = String(value)
                        } else if Int(buffer) != value {
                            buffer = String(value)
                        }
                    }
                }
                .animation(.appPress, value: isFocused)

            if !unit.isEmpty {
                Text(unit)
                    .appFont(.kcal)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.textMeta)
                    .monospacedDigit()
            }
        }
    }
}

#if DEBUG
#Preview("ProfileView — loading") {
    ProfileView()
        .environmentObject(AuthService())
        .environmentObject(ProfileStore())
}
#endif
