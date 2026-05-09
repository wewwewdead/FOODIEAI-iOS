import SwiftUI

/// Renders the result section below the drop zone for the `.ready` state.
/// Layout per DESIGN_SYSTEM.md §HomePage results section, mobile-stacked.
///
/// Sequencing:
///   - The calorie / food / macro lines animate in over the first ~1.5s.
///   - The three analysis panels appear one at a time and run their
///     typewriter sequentially: nutrients → benefits → drawbacks.
///   - Save / Cancel row sits between the speech bubble and the panels,
///     above a verbatim "Save this in to your daily tracker?" heading.
struct AnalysisResultView: View {
    let response: AnalyzeResponse
    var isSaving: Bool = false
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var caloriesVisible = false
    @State private var foodNameVisible = false
    @State private var sugarVisible = false
    @State private var carbsVisible = false
    @State private var proteinVisible = false
    @State private var fatVisible = false
    @State private var fiberVisible = false

    @State private var stage: PanelStage = .none

    enum PanelStage: Int, Comparable {
        case none = 0, nutrients = 1, benefits = 2, drawbacks = 3, done = 4
        static func < (lhs: PanelStage, rhs: PanelStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private var analysis: GeminiAnalysis { response.analysis }
    private var nutrientItems: [String] { analysis.nutrients ?? [] }
    private var benefitItems: [String] { analysis.benefits ?? [] }
    private var drawbackItems: [String] { analysis.drawbacks ?? [] }

    var body: some View {
        VStack(spacing: AppSpacing.xl2) {
            calorieBlock
            speechBubble
            saveCancelBlock
            panelsBlock
        }
        .frame(maxWidth: .infinity)
        .task {
            await runEntranceSequence()
        }
    }

    // MARK: - Top block: calories / food / macros

    private var calorieBlock: some View {
        VStack(spacing: AppSpacing.sm) {
            Text("\(Int(analysis.calories ?? 0)) calories")
                .appFont(.kcal)
                .fontWeight(.black)
                .foregroundStyle(Color.greenCalorie)
                .opacity(caloriesVisible ? 1 : 0)
                .scaleEffect(caloriesVisible ? 1 : 0.8)
                .animation(.easeOut(duration: 0.5), value: caloriesVisible)

            Text(analysis.food ?? "")
                .appFont(.foodName)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(foodNameVisible ? 1 : 0)
                .scaleEffect(foodNameVisible ? 1 : 0.8)
                .animation(.easeOut(duration: 0.5), value: foodNameVisible)

            VStack(spacing: AppSpacing.xs) {
                Text("Sugar: \(format(analysis.sugar))g")
                    .appFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.greenCalorie)
                    .opacity(sugarVisible ? 1 : 0)
                    .scaleEffect(sugarVisible ? 1 : 0.8)
                    .animation(.easeOut(duration: 0.5), value: sugarVisible)

                Text("Carbs: \(format(analysis.carbs))g")
                    .appFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.greenCalorie)
                    .opacity(carbsVisible ? 1 : 0)
                    .scaleEffect(carbsVisible ? 1 : 0.8)
                    .animation(.easeOut(duration: 0.5), value: carbsVisible)

                // Phase 11 macros: optional. Skip the line entirely if Gemini
                // didn't return a value (showing "0g" would misrepresent missing
                // data as a measured zero).
                if let protein = analysis.protein {
                    Text("Protein: \(format(protein))g")
                        .appFont(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.greenCalorie)
                        .opacity(proteinVisible ? 1 : 0)
                        .scaleEffect(proteinVisible ? 1 : 0.8)
                        .animation(.easeOut(duration: 0.5), value: proteinVisible)
                }
                if let fat = analysis.fat {
                    Text("Fat: \(format(fat))g")
                        .appFont(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.greenCalorie)
                        .opacity(fatVisible ? 1 : 0)
                        .scaleEffect(fatVisible ? 1 : 0.8)
                        .animation(.easeOut(duration: 0.5), value: fatVisible)
                }
                if let fiber = analysis.fiber {
                    Text("Fiber: \(format(fiber))g")
                        .appFont(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.greenCalorie)
                        .opacity(fiberVisible ? 1 : 0)
                        .scaleEffect(fiberVisible ? 1 : 0.8)
                        .animation(.easeOut(duration: 0.5), value: fiberVisible)
                }
            }
        }
    }

    // MARK: - Coach speech bubble

    @ViewBuilder
    private var speechBubble: some View {
        if let advice = analysis.coachAdvice, !advice.isEmpty {
            SpeechBubble(text: advice, coachName: response.coach)
        }
    }

    // MARK: - Save / Cancel

    private var saveCancelBlock: some View {
        VStack(spacing: AppSpacing.md) {
            Text("Save this in to your daily tracker?")
                .appFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            // Web spec: 4rem gap between the two action buttons.
            HStack(spacing: 64) {
                CircleActionButton(kind: .cancel, action: onCancel)
                CircleActionButton(kind: .save, isLoading: isSaving, action: onSave)
            }
        }
    }

    // MARK: - Three analysis panels

    @ViewBuilder
    private var panelsBlock: some View {
        VStack(spacing: AppSpacing.lg) {
            if stage >= .nutrients {
                AnalysisPanel(
                    kind: .nutrients,
                    title: "Nutrients",
                    items: nutrientItems,
                    startTyping: stage >= .nutrients
                )
                .transition(
                    .move(edge: .leading).combined(with: .opacity)
                )
            }
            if stage >= .benefits {
                AnalysisPanel(
                    kind: .benefits,
                    title: "Benefits",
                    items: benefitItems,
                    startTyping: stage >= .benefits
                )
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
            if stage >= .drawbacks {
                AnalysisPanel(
                    kind: .drawbacks,
                    title: "Drawbacks",
                    items: drawbackItems,
                    startTyping: stage >= .drawbacks
                )
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(.easeOut(duration: 0.5), value: stage)
    }

    // MARK: - Entrance sequencing

    /// Runs once on appear. Spec timings (web): calorie 0.5s, food 0.8s,
    /// sugar 1.2s, carbs 1.5s. Then panels begin advancing as their
    /// preceding panel's typewriter finishes.
    private func runEntranceSequence() async {
        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 100)
        caloriesVisible = true

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
        foodNameVisible = true

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 400)
        sugarVisible = true

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
        carbsVisible = true

        // Phase 11: protein @ 1.8s, fat @ 2.1s, fiber @ 2.4s relative to start.
        // Step from carbs (1.5s) by 300ms each, matching the existing rhythm.
        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
        proteinVisible = true

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
        fatVisible = true

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
        fiberVisible = true

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 500)
        stage = .nutrients

        try? await Task.sleep(nanoseconds: typewriterNanos(for: nutrientItems))
        stage = .benefits

        try? await Task.sleep(nanoseconds: typewriterNanos(for: benefitItems))
        stage = .drawbacks

        try? await Task.sleep(nanoseconds: typewriterNanos(for: drawbackItems))
        stage = .done
    }

    /// Estimates how long TypewriterController will spend rendering an
    /// item array at 20ms/char, plus a small slack so consecutive panels
    /// don't visibly overlap their first character with the previous
    /// panel's last.
    private func typewriterNanos(for items: [String]) -> UInt64 {
        let chars = items.reduce(0) { $0 + $1.count }
        let seconds = Double(chars) * 0.02 + 0.4
        return UInt64(seconds * 1_000_000_000)
    }

    // MARK: - Number formatting

    private func format(_ value: Double?) -> String {
        guard let value else { return "0" }
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}

#if DEBUG
#Preview("AnalysisResultView") {
    let sample = AnalyzeResponse(
        analysis: GeminiAnalysis(
            fallback: nil,
            food: "Margherita Pizza",
            calories: 275,
            carbs: 35,
            sugar: 4,
            protein: 12,
            fat: 14,
            fiber: 3,
            benefits: [
                "Provides calcium for bone health",
                "Contains lycopene from tomato sauce",
                "Source of protein from cheese"
            ],
            drawbacks: [
                "High in refined carbs",
                "Sodium content can be elevated",
                "Consider whole-grain crust"
            ],
            nutrients: [
                "Calcium: bone health",
                "Lycopene: antioxidant",
                "Protein: muscle synthesis"
            ],
            coachAdvice: "E = mc²… and a slice of pizza ≈ 285 kcal. Pace thyself."
        ),
        coach: "Albert Einstein"
    )
    return ScrollView {
        AnalysisResultView(
            response: sample,
            onSave: { print("save tapped") },
            onCancel: { print("cancel tapped") }
        )
        .padding(AppSpacing.lg)
    }
    .background(Color.brandCream)
}
#endif
