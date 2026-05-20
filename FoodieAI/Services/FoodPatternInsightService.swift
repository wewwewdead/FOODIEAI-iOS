import Foundation

/// Reads on-device beliefs to produce a *pattern insight* about the
/// freshly analyzed meal — never to override Gemini. Gemini remains
/// the single source of truth for displayed calories and macros; this
/// service strictly describes how the current meal sits inside the
/// user's own history.
///
/// Pure / synchronous so it stays trivially testable: the @MainActor
/// `insight(for:)` overload reaches into the shared store and threads
/// the snapshot into the static `compute(...)` form, which is what
/// tests exercise directly.
struct FoodPatternInsightService {

    /// Convenience entry point used by `CaptureViewModel`. Reads the
    /// snapshot off the MainActor-bound store and delegates to the
    /// pure form.
    @MainActor
    func insight(
        for response: AnalyzeResponse,
        store: LocalNutritionBeliefStore = .shared
    ) -> FoodPatternInsight {
        let foodName = response.analysis.food ?? ""
        guard !foodName.isEmpty else {
            return FoodPatternInsight.empty(for: foodName)
        }
        let belief    = store.belief(for: foodName)
        let typical   = store.typicalMealCalories()
        return Self.compute(
            response:              response,
            belief:                belief,
            typicalMealCalories:   typical
        )
    }

    /// Pure form. Deterministic given (response, belief, typical).
    /// Tests use this directly so they never touch the singleton.
    static func compute(response: AnalyzeResponse,
                        belief: FoodBelief?,
                        typicalMealCalories: Double?) -> FoodPatternInsight {
        let foodName = response.analysis.food ?? ""

        // First-time meal — return an empty (not-personalized) insight.
        // The UI gates the card on `hasAnyContent` so a brand-new food
        // either shows nothing or a single gentle empty-state line,
        // depending on the parent's preference.
        guard let belief, belief.observations > 0 else {
            return FoodPatternInsight.empty(for: foodName)
        }

        let geminiCals = response.analysis.calories

        let comparisonToUserAverage = makeUserAverageComparison(
            foodName: foodName,
            geminiCals: geminiCals,
            belief: belief
        )

        let comparisonToTypicalMeal = makeTypicalMealComparison(
            geminiCals: geminiCals,
            typicalMealCalories: typicalMealCalories
        )

        let repeatedFoodNote = makeRepeatedFoodNote(
            foodName: foodName,
            belief: belief
        )

        let moodNote = makeMoodNote(
            foodName: foodName,
            belief: belief
        )

        return FoodPatternInsight(
            foodName:                  foodName,
            isEmpty:                   false,
            confidence:                belief.confidence,
            similarMealCount:          belief.observations,
            comparisonToUserAverage:   comparisonToUserAverage,
            comparisonToTypicalMeal:   comparisonToTypicalMeal,
            repeatedFoodNote:          repeatedFoodNote,
            moodNote:                  moodNote
        )
    }

    // MARK: - Note builders

    /// "Around your usual ~520 kcal" / "Lighter than your usual ~520 kcal"
    /// / "Heavier than your usual ~520 kcal". Nil when we don't have a
    /// strong enough calorie prior or Gemini didn't return calories.
    private static func makeUserAverageComparison(
        foodName: String,
        geminiCals: Double?,
        belief: FoodBelief
    ) -> ComparisonNote? {
        guard let cals = geminiCals,
              cals.isFinite,
              belief.calories.count >= 2,
              belief.calories.mean > 0 else { return nil }

        let mean = belief.calories.mean
        let direction = ComparisonNote.Direction(
            observed: cals, reference: mean, similarBand: 0.15
        )
        let roundedMean = Int(mean.rounded())
        let copy: String = {
            switch direction {
            case .similar:
                return "Around your usual \(foodName) (~\(roundedMean) kcal)."
            case .lower:
                return "Lighter than your usual \(foodName) (~\(roundedMean) kcal average)."
            case .higher:
                return "Heavier than your usual \(foodName) (~\(roundedMean) kcal average)."
            }
        }()
        return ComparisonNote(
            kind:          .userAverageForFood,
            direction:     direction,
            referenceValue: mean,
            observedValue:  cals,
            copy:           copy
        )
    }

    /// "Lighter than your typical meal" / "Around your typical meal" /
    /// "Heavier than your typical meal". Nil when we don't yet have a
    /// global typical (< 3 distinct foods seen) or Gemini's calories
    /// are absent.
    private static func makeTypicalMealComparison(
        geminiCals: Double?,
        typicalMealCalories: Double?
    ) -> ComparisonNote? {
        guard let cals = geminiCals,
              cals.isFinite,
              let typical = typicalMealCalories,
              typical > 0 else { return nil }

        let direction = ComparisonNote.Direction(
            observed: cals, reference: typical, similarBand: 0.20
        )
        let rounded = Int(typical.rounded())
        let copy: String = {
            switch direction {
            case .similar:
                return "Around your typical meal (~\(rounded) kcal across your logs)."
            case .lower:
                return "Lighter than your typical meal (~\(rounded) kcal across your logs)."
            case .higher:
                return "Heavier than your typical meal (~\(rounded) kcal across your logs)."
            }
        }()
        return ComparisonNote(
            kind:           .typicalMeal,
            direction:      direction,
            referenceValue: typical,
            observedValue:  cals,
            copy:           copy
        )
    }

    /// Frequency-aware copy. Mirrors the tone tiers from the existing
    /// `repeatChip` but speaks in the second-person pattern voice
    /// ("you've logged this N times") rather than the "familiar one"
    /// register. Nil until the user has logged this food at least
    /// twice — a single prior is already covered by the title-block
    /// repeat chip.
    private static func makeRepeatedFoodNote(foodName: String,
                                             belief: FoodBelief) -> String? {
        switch belief.observations {
        case ..<2:
            return nil
        case 2...3:
            return "You've logged \(foodName) \(belief.observations) times so far."
        case 4...6:
            return "\(foodName) is becoming one of your regulars — \(belief.observations) logs."
        default:
            return "\(foodName) is a staple of your week — \(belief.observations) logs."
        }
    }

    /// "You usually feel loved after this." Nil unless the mood
    /// histogram has at least 2 samples AND one mood dominates ≥ 60%.
    private static func makeMoodNote(foodName: String,
                                     belief: FoodBelief) -> String? {
        guard let dominant = belief.moodCounts.dominant() else { return nil }
        switch dominant {
        case .loved:
            return "You usually feel great after \(foodName)."
        case .fine:
            return "You usually feel fine after \(foodName)."
        case .tough:
            return "This one's been a tough one for you in the past."
        }
    }
}

// MARK: - Public insight model

/// Read-only bundle of pattern-derived insights. Carries NO override
/// of Gemini's calories/macros — those live exclusively on
/// `response.analysis`. The view layer renders the comparison /
/// repeat / mood copy verbatim.
struct FoodPatternInsight: Equatable {
    let foodName: String
    /// True when no prior observations were available — the UI uses
    /// this to either hide the card or render a gentle empty-state
    /// line. All other fields are nil/0 in this case.
    let isEmpty: Bool
    let confidence: BeliefConfidence
    /// Total prior saves of this food. Distinct from per-macro counts.
    let similarMealCount: Int
    /// How this meal's calories sit against the user's history for
    /// the same food. Nil when calorie data is missing or thin.
    let comparisonToUserAverage: ComparisonNote?
    /// How this meal's calories sit against the user's overall
    /// typical meal. Nil until the user has logged ≥ 3 distinct
    /// foods with calorie data.
    let comparisonToTypicalMeal: ComparisonNote?
    /// Tiered "you've logged this N times" copy. Nil for first-time
    /// or single-prior foods (the title-block chip covers those).
    let repeatedFoodNote: String?
    /// Dominant post-meal mood for this food, in human-readable form.
    /// Nil when the histogram is too thin to claim a pattern.
    let moodNote: String?

    /// True when at least one piece of pattern content is present.
    /// The card's parent uses this to decide whether to render at all.
    var hasAnyContent: Bool {
        !isEmpty && (
            comparisonToUserAverage != nil ||
            comparisonToTypicalMeal != nil ||
            repeatedFoodNote        != nil ||
            moodNote                != nil
        )
    }

    static func empty(for foodName: String) -> FoodPatternInsight {
        FoodPatternInsight(
            foodName:                foodName,
            isEmpty:                 true,
            confidence:              .low,
            similarMealCount:        0,
            comparisonToUserAverage: nil,
            comparisonToTypicalMeal: nil,
            repeatedFoodNote:        nil,
            moodNote:                nil
        )
    }
}

/// One comparison line. The reference (user-average or typical-meal)
/// and the observed value are preserved so the view can render either
/// the copy or a numeric chip without re-deriving them.
struct ComparisonNote: Equatable {
    enum Kind: Equatable {
        case userAverageForFood
        case typicalMeal
    }

    enum Direction: Equatable {
        case lower
        case similar
        case higher

        /// Bands are expressed as a percentage of the reference so the
        /// "similar" zone scales with portion size — a 50 kcal swing
        /// matters more on a 200 kcal snack than on a 1000 kcal meal.
        init(observed: Double, reference: Double, similarBand: Double) {
            guard reference > 0 else {
                self = .similar
                return
            }
            let delta = (observed - reference) / reference
            if abs(delta) <= similarBand { self = .similar; return }
            self = delta < 0 ? .lower : .higher
        }
    }

    let kind: Kind
    let direction: Direction
    let referenceValue: Double
    let observedValue: Double
    let copy: String
}
