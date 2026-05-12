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

    private enum Phase: Equatable {
        case intro
        case form
        case preview(CalorieGoalCalculator.Goals)
    }

    @State private var phase: Phase = .intro

    @State private var sex: CalorieGoalCalculator.BiologicalSex? = nil
    @State private var ageText: String = ""
    @State private var heightText: String = ""
    @State private var heightUnit: HeightUnit = .cm
    @State private var weightText: String = ""
    @State private var weightUnit: WeightUnit = .kg
    @State private var activity: CalorieGoalCalculator.ActivityLevel? = nil
    @State private var goal: CalorieGoalCalculator.GoalDirection? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            switch phase {
            case .intro:
                introContent
            case .form:
                formContent
            case .preview(let goals):
                previewContent(goals: goals)
            }

            BackChevron(action: backTapped)
        }
        .animation(.appEntrance, value: phaseKey)
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
                Text("A few quick questions (age, height, weight, how active you are) and we'll compute a daily calorie target tuned to you. Skip if you'd rather use the defaults — you can always set this up later in Profile.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AppSpacing.lg)
                VStack(spacing: AppSpacing.sm) {
                    PrimaryButton(title: "Personalize my targets",
                                  leadingSystemImage: "slider.horizontal.3") {
                        phase = .form
                    }
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

    // MARK: - Form

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                Text("About you")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .padding(.top, AppSpacing.xl2)
                sexSection
                ageSection
                heightSection
                weightSection
                activitySection
                goalSection
                continueButton
                Color.clear.frame(height: AppSpacing.xl2)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var sexSection: some View {
        section(title: "Biological sex",
                caption: "Used only to estimate daily calorie needs — the BMR formula differs by ~166 kcal between male and female.") {
            VStack(spacing: AppSpacing.xs) {
                ForEach(CalorieGoalCalculator.BiologicalSex.allCases, id: \.self) { option in
                    selectRow(label: option.displayLabel,
                              isSelected: sex == option) {
                        Haptics.selection()
                        sex = option
                    }
                }
            }
        }
    }

    private var ageSection: some View {
        section(title: "Age", caption: nil) {
            HStack {
                TextField("30", text: $ageText)
                    .keyboardType(.numberPad)
                    .font(AppFont.font(.kcal))
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .frame(maxWidth: 140)
                    .padding(AppSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(Color.bgSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(Color.panelBorder, lineWidth: 2)
                    )
                    .onChange(of: ageText) { _, newValue in
                        let filtered = newValue.filter { ("0"..."9").contains($0) }
                        if filtered != newValue { ageText = filtered }
                    }
                Text("years")
                    .appFont(.body)
                    .foregroundStyle(Color.textMeta)
            }
        }
    }

    private var heightSection: some View {
        section(title: "Height", caption: nil) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                unitToggle(selected: $heightUnit, options: HeightUnit.allCases)
                HStack {
                    TextField(heightUnit == .cm ? "175" : "5'9\"",
                              text: $heightText)
                        .keyboardType(heightUnit == .cm ? .decimalPad : .asciiCapable)
                        .font(AppFont.font(.kcal))
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                        .frame(maxWidth: 180)
                        .padding(AppSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .fill(Color.bgSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(Color.panelBorder, lineWidth: 2)
                        )
                    Text(heightUnit.suffix)
                        .appFont(.body)
                        .foregroundStyle(Color.textMeta)
                }
            }
        }
    }

    private var weightSection: some View {
        section(title: "Weight", caption: nil) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                unitToggle(selected: $weightUnit, options: WeightUnit.allCases)
                HStack {
                    TextField(weightUnit == .kg ? "75" : "165",
                              text: $weightText)
                        .keyboardType(.decimalPad)
                        .font(AppFont.font(.kcal))
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                        .frame(maxWidth: 140)
                        .padding(AppSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .fill(Color.bgSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(Color.panelBorder, lineWidth: 2)
                        )
                    Text(weightUnit.suffix)
                        .appFont(.body)
                        .foregroundStyle(Color.textMeta)
                }
            }
        }
    }

    private var activitySection: some View {
        section(title: "Activity level", caption: nil) {
            VStack(spacing: AppSpacing.xs) {
                ForEach(CalorieGoalCalculator.ActivityLevel.allCases, id: \.self) { level in
                    selectRow(label: level.displayLabel,
                              isSelected: activity == level) {
                        Haptics.selection()
                        activity = level
                    }
                }
            }
        }
    }

    private var goalSection: some View {
        section(title: "Goal", caption: nil) {
            VStack(spacing: AppSpacing.xs) {
                ForEach(CalorieGoalCalculator.GoalDirection.allCases, id: \.self) { direction in
                    selectRow(label: direction.displayLabel,
                              isSelected: goal == direction) {
                        Haptics.selection()
                        goal = direction
                    }
                }
            }
        }
    }

    private var continueButton: some View {
        PrimaryButton(title: "Calculate my targets",
                      isDisabled: !isFormValid) {
            calculateAndShowPreview()
        }
    }

    // MARK: - Preview

    private func previewContent(goals: CalorieGoalCalculator.Goals) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Your recommended targets")
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
                        Text("We've set the minimum to a safe floor — adjust your goal direction if you want more aggressive change.")
                            .appFont(.caption)
                            .foregroundStyle(Color.redError)
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
                        .strokeBorder(Color.panelBorder, lineWidth: 2)
                )

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

                Text("Defaults follow US Dietary Guidelines (50/25/25 carb/protein/fat). You can tweak any number in Profile.")
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
                .strokeBorder(Color.panelBorder, lineWidth: 2)
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
                        .frame(maxWidth: .infinity, minHeight: 36)
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
        guard let sex,
              let age = Int(ageText.trimmingCharacters(in: .whitespaces)),
              age >= 13, age <= 120,
              let activity,
              let goal else { return nil }

        let trimmedHeight = heightText.trimmingCharacters(in: .whitespaces)
        guard let heightCm = heightUnit.parseToCm(trimmedHeight),
              heightCm >= 100, heightCm <= 250 else { return nil }

        let trimmedWeight = weightText.trimmingCharacters(in: .whitespaces)
        guard let weightKg = weightUnit.parseToKg(trimmedWeight),
              weightKg >= 30, weightKg <= 300 else { return nil }

        return CalorieGoalCalculator.Physiology(
            sex: sex, ageYears: age, heightCm: heightCm, weightKg: weightKg,
            activity: activity, goal: goal
        )
    }

    private func calculateAndShowPreview() {
        guard let phys = parsedPhysiology() else { return }
        Haptics.success()
        phase = .preview(CalorieGoalCalculator.compute(phys))
    }

    private func persistAndAdvance() {
        guard let phys = parsedPhysiology() else { return }
        Haptics.tap()
        vm.physiology = phys
        vm.advance()
    }

    /// On re-entry from `.preview` → `.form`, the form fields already
    /// hold the user's last input. On initial appearance, if the VM
    /// has a stashed physiology (e.g. user came back from coaches
    /// step), hydrate so we don't lose their answers.
    private func hydrateFromVM() {
        guard sex == nil, ageText.isEmpty,
              let phys = vm.physiology else { return }
        sex = phys.sex
        ageText = "\(phys.ageYears)"
        heightText = heightUnit.format(cm: phys.heightCm)
        weightText = weightUnit.format(kg: phys.weightKg)
        activity = phys.activity
        goal = phys.goal
    }

    private func backTapped() {
        Haptics.tap()
        switch phase {
        case .intro:
            vm.back()
        case .form:
            phase = .intro
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
        case .preview:  return 2
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

#if DEBUG
#Preview("Physiology") {
    OnboardingPhysiologyStepView(vm: OnboardingViewModel(initialStep: .physiology))
}
#endif
