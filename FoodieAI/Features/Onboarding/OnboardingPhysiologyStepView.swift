import SwiftUI

/// Phase 20. Optional onboarding step — collects physiology inputs that
/// feed `CalorieGoalCalculator` so the user lands on personalized
/// calorie + macro targets rather than archetype defaults.
///
/// Three internal phases:
///   - `.intro`   — short pitch with "Personalize my targets" and
///                  "Skip for now" affordances. Skip leaves
///                  `vm.physiology` nil; the archetype defaults stay.
///   - `.form`    — the six-question form (sex/age/height/weight/
///                  activity/goal). Continue is gated on every field
///                  being valid; the math runs entirely on the client.
///   - `.preview` — read-only summary of the computed BMR/TDEE +
///                  calorie/macro targets. "Use these targets" stamps
///                  `vm.physiology` and advances; "Let me adjust"
///                  returns to the form with values preserved.
///
/// Deliberately a single tall scrollable form rather than a sub-flow:
/// the question count is small enough (6) that paging would feel slow
/// on a phone, and the user can scroll back if they need to revise an
/// earlier answer without losing context.
struct OnboardingPhysiologyStepView: View {
    @ObservedObject var vm: OnboardingViewModel
    /// Shared CTA namespace from `OnboardingFlow`. Same id chains the
    /// morph through every onboarding step — and through this view's
    /// own intro → form → preview phase transitions.
    var ctaNamespace: Namespace.ID? = nil

    private enum Phase: Equatable {
        case intro
        case form
        /// Phase 23. A brief "building your plan" loader between the form and
        /// the reveal — frames the (instant, local) computation as real work,
        /// which the category leaders use to make the plan feel earned.
        case building
        case preview(CalorieGoalCalculator.Goals)
    }

    @State private var phase: Phase = .intro

    @State private var sex: CalorieGoalCalculator.BiologicalSex? = nil
    // Phase 24. Numeric dial state in CANONICAL units (kg/cm/years), driven by
    // the scrolling ruler pickers. Defaults are sensible centers to dial from.
    @State private var age: Int = 25
    @State private var heightCm: Double = 170
    @State private var heightUnit: HeightUnit = .cm
    @State private var weightKg: Double = 70
    @State private var weightUnit: WeightUnit = .kg
    /// Optional goal weight (kg). Only shown for lose/gain; feeds the reveal's
    /// projection. Defaults to current weight, so no chart appears until the
    /// user actually dials a target (the projection guards ignore an equal /
    /// wrong-direction target).
    @State private var targetKg: Double = 70
    @State private var activity: CalorieGoalCalculator.ActivityLevel? = nil
    @State private var goal: CalorieGoalCalculator.GoalDirection? = nil

    /// Physiology captured when leaving the form, held across the `.building`
    /// loader so the reveal renders from a stable value.
    @State private var pendingPhysiology: CalorieGoalCalculator.Physiology? = nil
    /// 0…2 caption index for the building loader.
    @State private var buildStage: Int = 0
    @State private var spin = false

    private static let lbPerKg: Double = 2.2046226218

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            switch phase {
            case .intro:
                introContent
            case .form:
                formContent
            case .building:
                buildingContent
            case .preview(let goals):
                previewContent(goals: goals)
            }

            // The building loader owns the screen — a back chevron there would
            // let the user interrupt the "we're computing your plan" beat.
            if phase != .building {
                BackChevron(action: backTapped)
            }
        }
        // Same `.appMorph` curve as the cross-screen flow so the
        // intro → form → preview pill morph reads as one continuous
        // animation language with the parent step transitions.
        .animation(.appMorph, value: phaseKey)
        .onAppear(perform: hydrateFromVM)
    }

    // MARK: - Intro

    private var introContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroIcon
                Text("Want personalized targets?")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A few quick questions (age, height, weight, how active you are) and we'll compute a daily calorie target tuned to you. Skip if you'd rather use the defaults, you can always set this up later in Profile.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AppSpacing.lg)
                VStack(spacing: AppSpacing.sm) {
                    PrimaryButton(title: "Personalize my targets",
                                  leadingSystemImage: "slider.horizontal.3") {
                        phase = .form
                    }
                    .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
                    Button {
                        Haptics.tap()
                        // Leave vm.physiology nil; archetype defaults remain.
                        vm.physiology = nil
                        vm.advance()
                    } label: {
                        Text("Skip for now")
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.inkMute)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                Capsule().strokeBorder(Color.borderHairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Text("Uses the Mifflin-St Jeor equation and US Dietary Guidelines macro ratios.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.xl3)
            .padding(.bottom, AppSpacing.lg)
        }
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(Color.brandSoft)
                .frame(width: 88, height: 88)
            Image(systemName: "figure.mind.and.body")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.lg)
    }

    // MARK: - Form (paginated "About you" — one question per page)

    private enum FormStep: Int, CaseIterable {
        case sex, age, height, weight, activity, goal, target
    }
    @State private var formStep: FormStep = .sex

    private var formContent: some View {
        ZStack {
            switch formStep {
            case .sex:      sexPage
            case .age:      agePage
            case .height:   heightPage
            case .weight:   weightPage
            case .activity: activityPage
            case .goal:     goalPage
            case .target:   targetPage
            }
        }
        .transition(.opacity)
        .animation(.appMorph, value: formStep)
    }

    /// The active step sequence — the goal-weight page only appears for a
    /// lose/gain direction — used for the progress bar and next/back nav.
    private var formSteps: [FormStep] {
        (goal == .lose || goal == .gain)
            ? FormStep.allCases
            : FormStep.allCases.filter { $0 != .target }
    }
    private var isLastFormStep: Bool { formStep == formSteps.last }
    private var continueTitle: String { isLastFormStep ? "Build my plan" : "Continue" }

    private func advanceForm() {
        Haptics.tap()
        guard let idx = formSteps.firstIndex(of: formStep) else { return }
        if idx + 1 < formSteps.count {
            withAnimation(.appMorph) { formStep = formSteps[idx + 1] }
        } else {
            startBuilding()
        }
    }
    private func backForm() {
        guard let idx = formSteps.firstIndex(of: formStep), idx > 0 else {
            phase = .intro
            return
        }
        withAnimation(.appMorph) { formStep = formSteps[idx - 1] }
    }

    /// Full-page scaffold: progress bar, big title, vertically-centered content,
    /// and the Continue CTA. One question per screen.
    private func pageScaffold<Content: View>(
        title: String, subtitle: String? = nil,
        canContinue: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            formProgress
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(title)
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AppSpacing.md)
            content()
                .frame(maxWidth: .infinity)
            Spacer(minLength: AppSpacing.md)
            PrimaryButton(title: continueTitle, isDisabled: !canContinue) { advanceForm() }
                .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl3)
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var formProgress: some View {
        let idx = formSteps.firstIndex(of: formStep) ?? 0
        let frac = Double(idx + 1) / Double(max(1, formSteps.count))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.borderHairline)
                Capsule().fill(Color.brand)
                    .frame(width: max(6, geo.size.width * frac))
            }
        }
        .frame(height: 5)
    }

    private var sexPage: some View {
        pageScaffold(title: "What's your\nbiological sex?",
                     subtitle: "Used only to estimate your daily calorie needs.",
                     canContinue: sex != nil) {
            VStack(spacing: AppSpacing.sm) {
                ForEach(CalorieGoalCalculator.BiologicalSex.allCases, id: \.self) { option in
                    selectRow(label: option.displayLabel, isSelected: sex == option) {
                        Haptics.selection()
                        sex = option
                    }
                }
            }
        }
    }

    private var agePage: some View {
        pageScaffold(title: "How old are you?") {
            VStack(spacing: AppSpacing.xl) {
                Image(systemName: "birthday.cake")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Color.brand.opacity(0.55))
                dialReadout("\(age)", unit: "years")
                RulerPicker(value: ageBinding, range: 13...90, step: 1,
                            labelStep: 10, tint: .brand)
                    .frame(height: 84)
            }
        }
    }

    private var weightPage: some View {
        pageScaffold(title: "What's your weight?") {
            VStack(spacing: AppSpacing.lg) {
                unitToggle(selected: $weightUnit, options: WeightUnit.allCases)
                    .frame(maxWidth: 220)
                weightScaleIllustration
                RulerPicker(value: weightDisplay,
                            range: weightUnit == .kg ? 30...250 : 66...550,
                            step: weightUnit == .kg ? 0.5 : 1,
                            labelStep: weightUnit == .kg ? 10 : 20,
                            tint: .brand)
                    .frame(height: 84)
                    .id(weightUnit)   // re-center the dial when the unit flips
            }
        }
    }

    /// A stylized bathroom scale — footprints on the platform with the live
    /// weight in the "meter" window at the center.
    private var weightScaleIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.bgSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.borderHairline, lineWidth: 1)
                )
                .frame(width: 210, height: 158)
                .appShadow(.shadowCard)
            VStack(spacing: 12) {
                Image(systemName: "shoeprints.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.brand.opacity(0.45))
                Text("\(weightUnit.format(kg: weightKg)) \(weightUnit.suffix)")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.brandSoft))
            }
        }
        .animation(.appReduced, value: weightKg)
    }

    private var heightPage: some View {
        pageScaffold(title: "How tall are you?") {
            VStack(spacing: AppSpacing.md) {
                unitToggle(selected: $heightUnit, options: HeightUnit.allCases)
                    .frame(maxWidth: 220)
                dialReadout(heightUnit.format(cm: heightCm), unit: heightUnit.suffix)
                // A vertical "height scale" you dial, beside a figure that grows
                // and shrinks with the value.
                HStack(alignment: .bottom, spacing: AppSpacing.lg) {
                    heightFigure
                    RulerPicker(value: heightDisplay,
                                range: heightUnit == .cm ? 120...220 : 47...87,
                                step: 1,
                                labelStep: heightUnit == .cm ? 10 : 12,
                                axis: .vertical,
                                tint: .accentCool,
                                majorLabel: heightUnit == .cm
                                    ? { "\(Int($0))" }
                                    : { "\(Int($0) / 12)'" })
                        .frame(width: 130, height: 240)
                        .id(heightUnit)
                }
                .frame(height: 250)
            }
        }
    }

    private var heightFigure: some View {
        let frac = min(max((heightCm - 120) / 100, 0), 1)
        return Image(systemName: "figure.stand")
            .resizable()
            .scaledToFit()
            .frame(height: 130 + frac * 100)
            .foregroundStyle(Color.accentCool.opacity(0.8))
            .frame(maxHeight: 240, alignment: .bottom)
            .animation(.appReduced, value: heightCm)
    }

    // MARK: - Dial helpers

    /// Big live value above each dial.
    private func dialReadout(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .appFont(.display1)
                .foregroundStyle(Color.ink)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
        }
        .animation(.appReduced, value: value)
    }

    private var ageBinding: Binding<Double> {
        Binding(get: { Double(age) }, set: { age = Int($0.rounded()) })
    }
    private var weightDisplay: Binding<Double> {
        Binding(
            get: { weightUnit == .kg ? weightKg : weightKg * Self.lbPerKg },
            set: { weightKg = weightUnit == .kg ? $0 : $0 / Self.lbPerKg }
        )
    }
    private var targetDisplay: Binding<Double> {
        Binding(
            get: { weightUnit == .kg ? targetKg : targetKg * Self.lbPerKg },
            set: { targetKg = weightUnit == .kg ? $0 : $0 / Self.lbPerKg }
        )
    }
    private var heightDisplay: Binding<Double> {
        Binding(
            get: { heightUnit == .cm ? heightCm : heightCm / 2.54 },
            set: { heightCm = heightUnit == .cm ? $0 : $0 * 2.54 }
        )
    }

    private var activityPage: some View {
        pageScaffold(title: "How active are you?",
                     subtitle: "Everyday movement outside of workouts.",
                     canContinue: activity != nil) {
            VStack(spacing: AppSpacing.xs) {
                ForEach(CalorieGoalCalculator.ActivityLevel.allCases, id: \.self) { level in
                    selectRow(label: level.displayLabel, isSelected: activity == level) {
                        Haptics.selection()
                        activity = level
                    }
                }
            }
        }
    }

    private var goalPage: some View {
        pageScaffold(title: "What's your goal?",
                     canContinue: goal != nil) {
            VStack(spacing: AppSpacing.xs) {
                ForEach(CalorieGoalCalculator.GoalDirection.allCases, id: \.self) { direction in
                    selectRow(label: direction.displayLabel, isSelected: goal == direction) {
                        Haptics.selection()
                        goal = direction
                    }
                }
            }
        }
    }

    private var targetPage: some View {
        pageScaffold(title: "What's your\ngoal weight?",
                     subtitle: "Optional, we'll map a realistic timeline to reach it.") {
            VStack(spacing: AppSpacing.xl) {
                Image(systemName: goal == .gain ? "arrow.up.right.circle" : "arrow.down.right.circle")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Color.accentWarm.opacity(0.7))
                dialReadout(weightUnit.format(kg: targetKg), unit: weightUnit.suffix)
                RulerPicker(value: targetDisplay,
                            range: weightUnit == .kg ? 30...250 : 66...550,
                            step: weightUnit == .kg ? 0.5 : 1,
                            labelStep: weightUnit == .kg ? 10 : 20,
                            tint: .accentWarm)
                    .frame(height: 84)
                    .id(weightUnit)
            }
        }
    }

    // MARK: - Building loader

    private var buildingContent: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 108, height: 108)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.brand,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Color.brandDeep)
            }
            VStack(spacing: AppSpacing.xs) {
                Text("Building your plan")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                Text(buildCaption)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                    .id(buildStage)
            }
            .frame(maxWidth: .infinity)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
        .task { await stepBuild() }
    }

    private var buildCaption: String {
        switch buildStage {
        case 0:  return "Reading your body metrics…"
        case 1:  return "Balancing your macros…"
        default: return "Mapping your goal timeline…"
        }
    }

    /// Deliberately paces the (instant, local) computation so the plan feels
    /// earned, then reveals it. Bails without side effects if cancelled (user
    /// left the loader) or if the pending physiology somehow vanished.
    @MainActor
    private func stepBuild() async {
        for stage in 1...2 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.3)) { buildStage = stage }
        }
        try? await Task.sleep(nanoseconds: 650_000_000)
        if Task.isCancelled { return }
        guard let phys = pendingPhysiology else { phase = .form; return }
        // Sign-in comes after this reveal, so we can't write an analytics row
        // yet (no auth.uid() → RLS rejects it). Stash the flag; the VM reports
        // it in the post-auth `onboarding_signed_in` event.
        vm.didRevealPlan = true
        Haptics.success()
        phase = .preview(CalorieGoalCalculator.compute(phys))
    }

    // MARK: - Projection

    private func projectionCard(_ p: CalorieGoalCalculator.WeightProjection) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: p.losing ? "arrow.down.right.circle.fill"
                                           : "arrow.up.right.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.brandDeep)
                Text("Your goal timeline")
                    .appFont(.labelEyebrow)
                    .foregroundStyle(Color.inkMute)
            }
            (
                Text("Reach ")
                    .appFont(.bodyV2).foregroundStyle(Color.inkMute)
                + Text(weightUnit.format(kg: p.targetKg) + " " + weightUnit.suffix)
                    .appFont(.title2).foregroundStyle(Color.ink)
                + Text(" by ")
                    .appFont(.bodyV2).foregroundStyle(Color.inkMute)
                + Text(Self.goalDateLabel(p.goalDate))
                    .appFont(.title2).foregroundStyle(Color.greenCalorie)
            )
            .fixedSize(horizontal: false, vertical: true)

            ProjectionLineChart(startKg: p.startKg, targetKg: p.targetKg, losing: p.losing)
                .frame(height: 96)
                .padding(.top, AppSpacing.xs)

            Text("About \(weightUnit.format(kg: p.weeklyRateKg)) \(weightUnit.suffix) a week, a steady, sustainable pace you can hold.")
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.35), lineWidth: 2)
        )
    }

    private static let goalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static func goalDateLabel(_ date: Date) -> String {
        goalDateFormatter.string(from: date)
    }

    // MARK: - Preview

    private func previewContent(goals: CalorieGoalCalculator.Goals) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Your plan is ready")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .padding(.top, AppSpacing.xl2)

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Text("\(goals.calories)")
                            .appFont(.display1)
                            .foregroundStyle(Color.greenCalorie)
                            .monospacedDigit()
                        Text("calories / day")
                            .appFont(.bodyV2)
                            .foregroundStyle(Color.inkMute)
                    }
                    Text(rationaleLine(goals: goals))
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)
                        .fixedSize(horizontal: false, vertical: true)
                    if goals.wasFloored {
                        Text("We've set the minimum to a safe floor, adjust your goal direction if you want more aggressive change.")
                            .appFont(.caption)
                            .foregroundStyle(Color.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(Color.bgSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(Color.borderHairline, lineWidth: 2)
                )

                // The motivational payoff: a projected line to the user's goal
                // weight with a concrete date. Only present when a goal weight
                // was entered for a lose/gain direction.
                if let projection = currentProjection() {
                    projectionCard(projection)
                }

                VStack(spacing: AppSpacing.xs) {
                    macroRow(label: "Carbs",   value: goals.carbsG)
                    macroRow(label: "Protein", value: goals.proteinG)
                    macroRow(label: "Fat",     value: goals.fatG)
                    macroRow(label: "Fiber",   value: goals.fiberG)
                    macroRow(label: "Sugar",   value: goals.sugarG)
                }

                VStack(spacing: AppSpacing.sm) {
                    PrimaryButton(title: "Use these targets") {
                        persistAndAdvance()
                    }
                    .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
                    Button {
                        Haptics.tap()
                        phase = .form
                    } label: {
                        Text("Let me adjust")
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.inkMute)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                Capsule().strokeBorder(Color.borderHairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Text("We'll use this as your daily target. You can adjust it anytime in Profile.")
                    .appFont(.caption)
                    .foregroundStyle(Color.brandDeep)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Defaults follow US Dietary Guidelines (50/25/25 carb/protein/fat).")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
    }

    private func macroRow(label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .appFont(.body)
                .fontWeight(.bold)
                .foregroundStyle(Color.greenCalorie)
            Spacer()
            Text("\(value)g")
                .appFont(.kcal)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 2)
        )
    }

    private func rationaleLine(goals: CalorieGoalCalculator.Goals) -> String {
        let g = goal ?? .maintain
        switch g {
        case .lose:
            return "A 500 kcal/day deficit from your maintenance level of \(goals.tdee)."
        case .maintain:
            return "Matches your estimated maintenance level of \(goals.tdee) kcal."
        case .gain:
            return "A 500 kcal/day surplus over your maintenance level of \(goals.tdee)."
        }
    }

    // MARK: - Section helpers

    private func section<Body: View>(title: String,
                                     caption: String?,
                                     @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .appFont(.displayMD)
                .foregroundStyle(Color.textPrimary)
            content()
            if let caption {
                Text(caption)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func selectRow(label: String,
                           isSelected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.brand : Color.borderHairline,
                                      lineWidth: isSelected ? 6 : 1.5)
                        .frame(width: 22, height: 22)
                }
                Text(label)
                    .appFont(.body)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(isSelected ? Color.brandSoft : Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(isSelected ? Color.brand : Color.borderHairline,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func unitToggle<T: Hashable & CustomStringConvertible>(
        selected: Binding<T>,
        options: [T]
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    Haptics.tap()
                    selected.wrappedValue = option
                } label: {
                    Text(option.description)
                        .appFont(.captionStrong)
                        .foregroundStyle(selected.wrappedValue == option
                                         ? Color.ink : Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            selected.wrappedValue == option
                            ? Color.brandSoft : Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Logic

    private var isFormValid: Bool {
        parsedPhysiology() != nil
    }

    /// Parse all six form fields into a `Physiology` value, returning
    /// nil if any field is missing or out-of-range. Range checks mirror
    /// the SQL CHECK constraints so the local UPDATE can never fail
    /// for a reason the user can fix after the network round-trip.
    private func parsedPhysiology() -> CalorieGoalCalculator.Physiology? {
        // The dials clamp to their ranges, so these bounds always hold; kept as
        // a safety net that mirrors the SQL CHECK constraints.
        guard let sex, let activity, let goal,
              age >= 13, age <= 120,
              heightCm >= 100, heightCm <= 250,
              weightKg >= 30, weightKg <= 300 else { return nil }

        return CalorieGoalCalculator.Physiology(
            sex: sex, ageYears: age, heightCm: heightCm, weightKg: weightKg,
            activity: activity, goal: goal
        )
    }

    /// Goal weight from the dial. The projection guards (direction + a ≥0.5 kg
    /// delta) turn "target == current" into no-chart, so we can just return it.
    private func parsedTargetKg() -> Double? {
        guard targetKg >= 30, targetKg <= 300 else { return nil }
        return targetKg
    }

    /// The reveal's timeline projection, or nil when there's nothing to
    /// show (maintain goal, no/invalid target, or a target on the wrong
    /// side of current weight for the direction).
    private func currentProjection() -> CalorieGoalCalculator.WeightProjection? {
        guard let phys = parsedPhysiology(), let target = parsedTargetKg() else { return nil }
        return CalorieGoalCalculator.projectWeight(
            currentKg: phys.weightKg, targetKg: target, goal: phys.goal)
    }

    private func startBuilding() {
        guard let phys = parsedPhysiology() else { return }
        Haptics.success()
        pendingPhysiology = phys
        buildStage = 0
        spin = false   // reset so the loader's rotation restarts on appear
        phase = .building
    }

    private func persistAndAdvance() {
        guard let phys = parsedPhysiology() else { return }
        Haptics.tap()
        vm.physiology = phys
        vm.targetWeightKg = parsedTargetKg()
        vm.advance()
    }

    /// On re-entry from `.preview` → `.form`, the form fields already
    /// hold the user's last input. On initial appearance, if the VM
    /// has a stashed physiology (e.g. user came back from coaches
    /// step), hydrate so we don't lose their answers.
    private func hydrateFromVM() {
        // Pre-select the goal from the up-front goal question so the user isn't
        // asked their direction twice. They can still change it here.
        if goal == nil {
            switch vm.archetype {
            case .loseWeight?:  goal = .lose
            case .buildMuscle?: goal = .gain
            case .aware?:       goal = .maintain
            default:            break   // .curious / nil → no pre-selection
            }
        }
        guard sex == nil, let phys = vm.physiology else { return }
        sex = phys.sex
        age = phys.ageYears
        heightCm = phys.heightCm
        weightKg = phys.weightKg
        activity = phys.activity
        goal = phys.goal
        targetKg = vm.targetWeightKg ?? phys.weightKg
    }

    private func backTapped() {
        Haptics.tap()
        switch phase {
        case .intro:
            vm.back()
        case .form:
            backForm()   // steps back through the paginated pages, then → intro
        case .building:
            phase = .form
        case .preview:
            phase = .form
        }
    }

    /// Equatable key for the phase animation. A direct
    /// `value: phase` would require `Phase: Equatable` which the
    /// `.preview(Goals)` case satisfies, but the projected key here
    /// keeps the animation predicate independent of the embedded data.
    private var phaseKey: Int {
        switch phase {
        case .intro:    return 0
        case .form:     return 1
        case .building: return 2
        case .preview:  return 3
        }
    }

}

// MARK: - Unit toggles

private enum HeightUnit: String, CaseIterable, Hashable, CustomStringConvertible {
    case cm
    case ftIn
    var description: String {
        switch self {
        case .cm:   return "cm"
        case .ftIn: return "ft / in"
        }
    }
    var suffix: String {
        switch self {
        case .cm:   return "cm"
        case .ftIn: return ""
        }
    }
    /// Parses the user's text into centimeters. For `.ftIn` accepts
    /// either `5'9"`, `5'9`, `5 9`, or just a single number treated as
    /// total inches.
    func parseToCm(_ text: String) -> Double? {
        switch self {
        case .cm:
            return Double(text.replacingOccurrences(of: ",", with: "."))
        case .ftIn:
            let cleaned = text
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: " ")
            let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true)
            switch parts.count {
            case 2:
                guard let ft = Double(parts[0]), let inch = Double(parts[1])
                else { return nil }
                return (ft * 12 + inch) * 2.54
            case 1:
                guard let inches = Double(parts[0]) else { return nil }
                return inches * 2.54
            default:
                return nil
            }
        }
    }
    func format(cm: Double) -> String {
        switch self {
        case .cm:
            return String(format: "%.0f", cm)
        case .ftIn:
            let totalInches = cm / 2.54
            let feet = Int(totalInches / 12)
            let inches = Int(totalInches.rounded() - Double(feet * 12))
            return "\(feet)'\(inches)"
        }
    }
}

private enum WeightUnit: String, CaseIterable, Hashable, CustomStringConvertible {
    case kg
    case lb
    var description: String { rawValue }
    var suffix: String { rawValue }
    private static let lbPerKg: Double = 2.2046226218
    func parseToKg(_ text: String) -> Double? {
        let value = Double(text.replacingOccurrences(of: ",", with: "."))
        guard let v = value else { return nil }
        switch self {
        case .kg: return v
        case .lb: return v / Self.lbPerKg
        }
    }
    func format(kg: Double) -> String {
        switch self {
        case .kg: return String(format: "%.1f", kg)
        case .lb: return String(format: "%.1f", kg * Self.lbPerKg)
        }
    }
}

// MARK: - Projection chart

/// A lightweight, hand-drawn projection line for the onboarding plan reveal:
/// current weight on the left sloping to the goal weight on the right, with a
/// soft area fill and an animated end dot. Hand-drawn (Path) rather than Swift
/// Charts to match the app's bespoke look and avoid pulling chart chrome we'd
/// only fight to restyle.
private struct ProjectionLineChart: View {
    let startKg: Double
    let targetKg: Double
    let losing: Bool

    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let inset: CGFloat = 12
            let x0 = inset, x1 = w - inset
            let hi = max(startKg, targetKg)
            let lo = min(startKg, targetKg)
            let range = max(hi - lo, 0.0001)
            let top = inset
            let bottom = h - inset
            // Higher weight sits nearer the top; padded vertically so dots
            // never clip. Losing → line descends; gaining → it rises.
            let yStart = bottom - CGFloat((startKg - lo) / range) * (bottom - top)
            let yTarget = bottom - CGFloat((targetKg - lo) / range) * (bottom - top)
            let p0 = CGPoint(x: x0, y: yStart)
            let curX = x0 + (x1 - x0) * progress
            let curY = yStart + (yTarget - yStart) * progress

            ZStack {
                // Baseline
                Path { p in
                    p.move(to: CGPoint(x: x0, y: h - inset))
                    p.addLine(to: CGPoint(x: x1, y: h - inset))
                }
                .stroke(Color.borderHairline,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                // Area under the animated line
                Path { p in
                    p.move(to: CGPoint(x: x0, y: h - inset))
                    p.addLine(to: p0)
                    p.addLine(to: CGPoint(x: curX, y: curY))
                    p.addLine(to: CGPoint(x: curX, y: h - inset))
                    p.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color.brand.opacity(0.22), Color.brand.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                // The projection line
                Path { p in
                    p.move(to: p0)
                    p.addLine(to: CGPoint(x: curX, y: curY))
                }
                .stroke(Color.brand,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // Start marker
                Circle().fill(Color.inkLight)
                    .frame(width: 7, height: 7)
                    .position(p0)
                // Goal marker (rides the animated line, lands on target)
                Circle().fill(Color.greenCalorie)
                    .frame(width: 11, height: 11)
                    .shadow(color: Color.greenCalorie.opacity(0.5), radius: 4)
                    .position(x: curX, y: curY)
                    .accessibilityHidden(true)
            }
            .onAppear {
                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.9)) {
                    progress = 1
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Projected weight from \(Int(startKg.rounded())) to \(Int(targetKg.rounded())) kilograms")
    }
}

// MARK: - Ruler dial picker

/// A scrolling tick-ruler "dial" — horizontal or vertical. Binds a `Double` in
/// DISPLAY units, snaps to `step`, ticks a haptic on each value change, and marks
/// the selection with a fixed center indicator. Built on iOS 17 scroll APIs
/// (`scrollPosition(id:anchor:)` + `contentMargins`). Contiguous fixed-pitch
/// cells (no gaps) so the centered cell is always well-defined.
private struct RulerPicker: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Value interval between labelled "major" ticks.
    let labelStep: Double
    var axis: Axis = .horizontal
    var tint: Color = .brand
    var majorLabel: (Double) -> String = { String(Int($0.rounded())) }

    @State private var position: Int?

    private let pitch: CGFloat = 14   // points per tick

    private var count: Int {
        max(1, Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1)
    }
    private func valueAt(_ i: Int) -> Double { range.lowerBound + Double(i) * step }
    private func indexOf(_ v: Double) -> Int {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        return min(max(Int(((clamped - range.lowerBound) / step).rounded()), 0), count - 1)
    }
    private func isMajor(_ i: Int) -> Bool {
        let v = valueAt(i)
        let n = (v / labelStep).rounded()
        return abs(v - n * labelStep) < step / 2
    }

    var body: some View {
        GeometryReader { geo in
            let inset = (axis == .horizontal ? geo.size.width : geo.size.height) / 2
            ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                track
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .contentMargins(axis == .horizontal ? .horizontal : .vertical,
                            inset, for: .scrollContent)
            .overlay(alignment: .center) { indicator }
            .onAppear { position = indexOf(value) }
            .onChange(of: position) { _, new in
                guard let new else { return }
                let v = valueAt(new)
                if abs(v - value) > step / 2 {
                    value = v
                    Haptics.selection()
                }
            }
            .onChange(of: value) { _, v in
                let idx = indexOf(v)
                if idx != position { position = idx }
            }
        }
        .accessibilityElement()
        .accessibilityValue(majorLabel(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            default: break
            }
        }
    }

    @ViewBuilder private var track: some View {
        if axis == .horizontal {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in cell(i).id(i) }
            }
            .scrollTargetLayout()
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in cell(i).id(i) }
            }
            .scrollTargetLayout()
        }
    }

    @ViewBuilder private func cell(_ i: Int) -> some View {
        let major = isMajor(i)
        let lineColor = major ? Color.inkMute : Color.borderHairline
        if axis == .horizontal {
            VStack(spacing: 4) {
                Rectangle().fill(lineColor)
                    .frame(width: major ? 2 : 1, height: major ? 28 : 16)
                Text(major ? majorLabel(valueAt(i)) : "")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize()
            }
            .frame(width: pitch)
        } else {
            HStack(spacing: 6) {
                Rectangle().fill(lineColor)
                    .frame(width: major ? 28 : 16, height: major ? 2 : 1)
                Text(major ? majorLabel(valueAt(i)) : "")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .frame(height: pitch)
        }
    }

    private var indicator: some View {
        Capsule()
            .fill(tint)
            .frame(width: axis == .horizontal ? 3 : 40,
                   height: axis == .horizontal ? 40 : 3)
            .shadow(color: tint.opacity(0.4), radius: 3)
    }
}

#if DEBUG
#Preview("Physiology") {
    OnboardingPhysiologyStepView(vm: OnboardingViewModel(initialStep: .physiology))
}
#endif
