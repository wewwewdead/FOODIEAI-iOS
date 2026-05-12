import SwiftUI

/// Phase 20. "Personalize my targets" sub-screen.
///
/// Standalone editor for the physiology inputs that feed
/// `CalorieGoalCalculator`. Reachable from ProfileView for users who
/// either skipped the onboarding step or want to revise their answers
/// (e.g., updated weight after a few months).
///
/// Flow within this screen:
///   - `.form`    — pre-filled from the current profile. Continue is
///                  gated on every required field being valid.
///   - `.preview` — computed targets, with "Save these targets"
///                  (persists physiology + recomputed goals via
///                  `ProfileService.setPhysiologyAndGoals`) and "Let me
///                  adjust" (returns to the form).
///
/// On success, the updated profile is pushed into `ProfileStore` so
/// ProfileView, Tracker, and any other observer pick up the new
/// numbers, then the view pops back to Profile.
struct PhysiologyEditorView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case form
        case preview(CalorieGoalCalculator.Goals)
    }

    @State private var phase: Phase = .form

    @State private var sex: CalorieGoalCalculator.BiologicalSex? = nil
    @State private var ageText: String = ""
    @State private var heightText: String = ""
    @State private var heightUnit: HeightUnit = .cm
    @State private var weightText: String = ""
    @State private var weightUnit: WeightUnit = .kg
    @State private var activity: CalorieGoalCalculator.ActivityLevel? = nil
    @State private var goal: CalorieGoalCalculator.GoalDirection? = nil

    @State private var isSaving = false
    @State private var saveError: String? = nil

    private let service = ProfileService()

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
            switch phase {
            case .form:
                formContent
            case .preview(let goals):
                previewContent(goals: goals)
            }
        }
        .navigationTitle("Personalize")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: hydrateFromProfile)
    }

    // MARK: - Form

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                intro
                sexSection
                ageSection
                heightSection
                weightSection
                activitySection
                goalSection
                PrimaryButton(title: "Preview my targets",
                              isDisabled: !isFormValid) {
                    Haptics.tap()
                    if let phys = parsedPhysiology() {
                        phase = .preview(CalorieGoalCalculator.compute(phys))
                    }
                }
                Color.clear.frame(height: AppSpacing.xl2)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Personalize my targets")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
            Text("Tell us a bit about you and we'll compute a calorie target plus matching macros. You can override any value on the previous screen.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sexSection: some View {
        section(title: "Biological sex",
                caption: "Used only to estimate daily calorie needs.") {
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

    // MARK: - Preview

    private func previewContent(goals: CalorieGoalCalculator.Goals) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Your recommended targets")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .padding(.top, AppSpacing.lg)

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
                    PrimaryButton(title: isSaving ? "Saving…" : "Save these targets",
                                  isLoading: isSaving,
                                  isDisabled: isSaving) {
                        Task { await save(goals: goals) }
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
                    .disabled(isSaving)
                }

                if let saveError {
                    Text(saveError)
                        .appFont(.caption)
                        .foregroundStyle(Color.redError)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        switch goal ?? .maintain {
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
                Circle()
                    .strokeBorder(isSelected ? Color.brand : Color.borderHairline,
                                  lineWidth: isSelected ? 6 : 1.5)
                    .frame(width: 22, height: 22)
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

    private var isFormValid: Bool { parsedPhysiology() != nil }

    private func parsedPhysiology() -> CalorieGoalCalculator.Physiology? {
        guard let sex,
              let age = Int(ageText.trimmingCharacters(in: .whitespaces)),
              age >= 13, age <= 120,
              let activity,
              let goal else { return nil }

        guard let heightCm = heightUnit.parseToCm(heightText.trimmingCharacters(in: .whitespaces)),
              heightCm >= 100, heightCm <= 250 else { return nil }

        guard let weightKg = weightUnit.parseToKg(weightText.trimmingCharacters(in: .whitespaces)),
              weightKg >= 30, weightKg <= 300 else { return nil }

        return CalorieGoalCalculator.Physiology(
            sex: sex, ageYears: age, heightCm: heightCm, weightKg: weightKg,
            activity: activity, goal: goal
        )
    }

    /// Hydrate the form from the currently stored profile so the user
    /// sees their last answers when they come back to revise them.
    /// Skipped when the form is already dirty (e.g., the user re-enters
    /// from .preview via "Let me adjust").
    private func hydrateFromProfile() {
        guard sex == nil, ageText.isEmpty else { return }
        guard let profile = profileStore.profile else { return }
        sex = profile.biologicalSex
        if let age = profile.ageYears { ageText = "\(age)" }
        if let cm = profile.heightCm { heightText = heightUnit.format(cm: cm) }
        if let kg = profile.weightKg { weightText = weightUnit.format(kg: kg) }
        activity = profile.activityLevel
        goal = profile.weightGoalDirection
    }

    private func save(goals: CalorieGoalCalculator.Goals) async {
        guard let phys = parsedPhysiology(), !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let updated = try await service.setPhysiologyAndGoals(
                sex:        phys.sex,
                ageYears:   phys.ageYears,
                heightCm:   phys.heightCm,
                weightKg:   phys.weightKg,
                activity:   phys.activity,
                goal:       phys.goal,
                goals:      goals
            )
            profileStore.apply(updated)
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            saveError = error.localizedDescription
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

// MARK: - Unit toggles
//
// Duplicated from OnboardingPhysiologyStepView so each entry point can
// evolve independently — the onboarding form may change its
// interaction model later (e.g., page-based) without dragging the
// Profile editor along. The conversion math is small enough that the
// duplication is cheaper than coupling.

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
        guard let v = Double(text.replacingOccurrences(of: ",", with: "."))
        else { return nil }
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
