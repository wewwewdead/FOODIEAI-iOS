import Foundation

// NOVEL_DIRECTIONS Idea 2 — "The Meal Twin".
//
// Every tracker REACTS to a meal after it's logged. The Meal Twin instead
// forward-simulates the REST of the day from the user's own patterns and
// surfaces the single highest-leverage move BEFORE the meal happens — and it
// optimizes for something no calorie app does: the meal that lands the day
// near goal AND on the user's best-MOOD pattern (using the post-meal mood
// signal FoodieAI already collects).
//
// Pure + local + testable: this is a pure function of its context (typical
// meals, what's logged today, the clock, the budget). No network, no Vision,
// no I/O. It composes the existing primitives — `MealSuggestionEngine.MealSlot`
// windows, `GoalDirection` sign interpretation, and the per-meal mood posterior
// — rather than reinventing them.

/// One dish in the user's repertoire for a given meal slot, with how often it
/// leaves them feeling good afterwards (from the Beta-Binomial mood posterior).
struct TwinMeal: Equatable {
    let name: String
    let calories: Double
    let slot: MealSuggestionEngine.MealSlot
    /// P(felt good after) in (0, 1); 0.5 = no signal / neutral.
    let moodPositiveRate: Double
}

/// Everything the twin needs to simulate the rest of today.
struct MealTwinContext {
    let hour: Int
    let consumedSoFar: Double
    let goal: Double
    let direction: CalorieGoalCalculator.GoalDirection?
    /// Slots already logged today (inferred from each log's `eatenAt`).
    let loggedSlots: Set<MealSuggestionEngine.MealSlot>
    /// The user's usual dishes (built from meal history + mood beliefs).
    let typicalMeals: [TwinMeal]
}

/// The recommended next move — which slot, which dish, and why.
struct MealTwinMove: Equatable {
    let slot: MealSuggestionEngine.MealSlot
    let meal: TwinMeal
    /// Projected end-of-day calories if the user takes this move (then eats
    /// their usual for any slots after it).
    let projectedLandingKcal: Double
    let landsOnGoal: Bool
    let reason: String
}

/// The forward simulation: where the day is heading, and the best next move.
struct MealTwinProjection: Equatable {
    /// End-of-day calories if the user eats their typical remaining meals
    /// unchanged (the "do nothing" baseline).
    let baselineLandingKcal: Double
    let baselineVsGoal: Double
    let move: MealTwinMove?
}

enum MealTwinEngine {

    /// ±this band around goal counts as "on goal" (matches the app's live-ring
    /// tolerance so the twin never contradicts the ring).
    static let onGoalToleranceKcal: Double = DayCalorieStanding.onGoalToleranceKcal

    /// Weights for the joint objective. Goal fit leads (it's the loop's spine);
    /// mood breaks ties and tilts otherwise-equivalent choices toward how the
    /// food actually makes the user feel.
    static let goalWeight: Double = 1.0
    static let moodWeight: Double = 0.6

    /// Chronological order used to decide which slots are still "ahead". Snack
    /// is anytime, so it sorts last (an add-on, never a gate).
    private static func order(_ slot: MealSuggestionEngine.MealSlot) -> Int {
        switch slot {
        case .breakfast: return 0
        case .lunch:     return 1
        case .dinner:    return 2
        case .snack:     return 3
        }
    }

    /// Forward-simulate the rest of today and return the highest-leverage move.
    static func project(_ ctx: MealTwinContext) -> MealTwinProjection {
        let currentSlot = MealSuggestionEngine.MealSlot.forHour(ctx.hour)
        let currentOrder = currentSlot.map(order) ?? -1

        // Slots still ahead today: not yet logged, and at/after the current time.
        let mealSlots: [MealSuggestionEngine.MealSlot] = [.breakfast, .lunch, .dinner]
        let remainingSlots = mealSlots.filter {
            !ctx.loggedSlots.contains($0) && order($0) >= currentOrder
        }

        // Typical calories per slot = mean of the user's dishes for that slot.
        func typicalCalories(for slot: MealSuggestionEngine.MealSlot) -> Double {
            let meals = ctx.typicalMeals.filter { $0.slot == slot }
            guard !meals.isEmpty else { return 0 }
            return meals.map(\.calories).reduce(0, +) / Double(meals.count)
        }

        // Baseline: eat the usual for every remaining slot, unchanged.
        let baselineRemaining = remainingSlots.map(typicalCalories).reduce(0, +)
        let baselineLanding = ctx.consumedSoFar + baselineRemaining
        let baselineVsGoal = baselineLanding - ctx.goal

        // The immediate decision is the earliest remaining slot.
        guard let nextSlot = remainingSlots.min(by: { order($0) < order($1) }),
              ctx.goal > 0 else {
            return MealTwinProjection(baselineLandingKcal: baselineLanding,
                                      baselineVsGoal: baselineVsGoal, move: nil)
        }

        // Calories the OTHER remaining slots (after next) will typically add.
        let afterNext = remainingSlots
            .filter { order($0) > order(nextSlot) }
            .map(typicalCalories).reduce(0, +)

        // Candidate dishes for the next slot.
        let candidates = ctx.typicalMeals.filter { $0.slot == nextSlot }
        guard !candidates.isEmpty else {
            return MealTwinProjection(baselineLandingKcal: baselineLanding,
                                      baselineVsGoal: baselineVsGoal, move: nil)
        }

        // Score each candidate on the JOINT objective, forward-projected.
        func projectedLanding(_ meal: TwinMeal) -> Double {
            ctx.consumedSoFar + meal.calories + afterNext
        }
        func goalFit(_ landing: Double) -> Double {
            // Normalized closeness to goal, direction-aware: a deficit is fine
            // for `lose`, a surplus fine for `gain`, so those miss-directions
            // aren't penalized. 1 = perfect, →0 = far.
            let delta = landing - ctx.goal
            let forgiven: Double
            switch ctx.direction {
            case .lose:     forgiven = max(0, delta)          // only overage hurts
            case .gain:     forgiven = max(0, -delta)         // only shortfall hurts
            default:        forgiven = abs(delta)             // maintain: both hurt
            }
            return 1.0 / (1.0 + forgiven / max(ctx.goal, 1) * 4.0)
        }
        func score(_ meal: TwinMeal) -> Double {
            goalWeight * goalFit(projectedLanding(meal))
                + moodWeight * meal.moodPositiveRate
        }

        let best = candidates.max { score($0) < score($1) }!
        let landing = projectedLanding(best)
        let onGoal = abs(landing - ctx.goal) <= onGoalToleranceKcal
            || (ctx.direction == .lose && landing <= ctx.goal)
            || (ctx.direction == .gain && landing >= ctx.goal)

        // Was there a materially better-mood option we passed over, or is `best`
        // both on-goal and high-mood? Shape the reason around that.
        let bestMoodOption = candidates.max { $0.moodPositiveRate < $1.moodPositiveRate }!
        let reason: String
        if onGoal && best.name == bestMoodOption.name && best.moodPositiveRate >= 0.6 {
            reason = "lands you on goal, and it's one of your best-mood meals"
        } else if onGoal {
            reason = "keeps your day on goal"
        } else if best.moodPositiveRate >= 0.6 {
            reason = "your best-mood option for what's left in the day"
        } else {
            reason = "the closest fit for the room you have left"
        }

        let move = MealTwinMove(slot: nextSlot, meal: best,
                                projectedLandingKcal: landing,
                                landsOnGoal: onGoal, reason: reason)
        return MealTwinProjection(baselineLandingKcal: baselineLanding,
                                  baselineVsGoal: baselineVsGoal, move: move)
    }
}
