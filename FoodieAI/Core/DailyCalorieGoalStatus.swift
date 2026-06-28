import Foundation

/// Snapshot of where the user sits against their daily calorie goal.
///
/// Centralizes the math + guards already used (ad-hoc) by `GoalWarningState.resolve`
/// so the scan-warning flow on Home and the end-of-day reminder on Tracker
/// don't drift from the progress ring / macro bars.
///
/// Invariants:
///   - `consumed` is clamped to `>= 0`
///   - `progress` is finite (NaN/Inf collapse to 0)
///   - `remaining` is `max(0, goal - consumed)`
///   - `exceededBy` is `max(0, consumed - goal)`
///   - `hasValidGoal == false` iff `goal <= 0` or non-finite; consumers MUST
///     check this before surfacing any warning.
///
/// Visual progress can cap at 1.0 (callers do that), but this struct keeps
/// true values so callers can render "200 cal over" without re-deriving it.
struct DailyCalorieGoalStatus: Equatable {
    let consumed: Double
    let goal: Double
    let progress: Double
    let warningState: GoalWarningState
    let remaining: Double
    let exceededBy: Double
    let hasValidGoal: Bool

    /// Safe zero-state for callers that can't yet compute (no totals loaded,
    /// goal not yet hydrated). Renders as "no warning" everywhere.
    static let invalid = DailyCalorieGoalStatus(
        consumed: 0,
        goal: 0,
        progress: 0,
        warningState: .safe,
        remaining: 0,
        exceededBy: 0,
        hasValidGoal: false
    )

    static func compute(consumed: Double, goal: Double) -> DailyCalorieGoalStatus {
        let safeConsumed: Double = {
            guard consumed.isFinite else { return 0 }
            return max(0, consumed)
        }()
        guard goal.isFinite, goal > 0 else { return .invalid }

        let rawProgress = safeConsumed / goal
        let progress = rawProgress.isFinite ? rawProgress : 0
        return DailyCalorieGoalStatus(
            consumed: safeConsumed,
            goal: goal,
            progress: progress,
            warningState: GoalWarningState.resolve(consumed: safeConsumed, goal: goal),
            remaining: max(0, goal - safeConsumed),
            exceededBy: max(0, safeConsumed - goal),
            hasValidGoal: true
        )
    }
}

/// Turns an over-budget calorie amount into a rough, *personalized*
/// "earn it back" estimate using MET math: kcal/min ≈ MET × bodyWeightKg / 60.
/// Body weight comes from the user's profile when available, falling back to
/// a neutral adult default. Deliberately approximate — it's a motivating
/// nudge, not a medical figure (and it's only ever surfaced for users whose
/// goal is to lose or maintain, never to shame).
enum ActivityBurnEstimator {
    /// MET values from the Compendium of Physical Activities: a brisk walk
    /// (~5 km/h) and a light jog (~8 km/h).
    static let briskWalkMET: Double = 3.8
    static let jogMET: Double = 7.0
    /// Used when the profile has no weight yet — a neutral adult average so
    /// the estimate is still in the right ballpark.
    static let fallbackWeightKg: Double = 70

    /// Whole minutes of `met`-intensity effort to burn `kcal` for a person
    /// of `weightKg`. Returns 0 for non-positive input.
    static func minutes(toBurn kcal: Double, met: Double, weightKg: Double?) -> Int {
        let kg: Double = {
            guard let w = weightKg, w.isFinite, w > 0 else { return fallbackWeightKg }
            return w
        }()
        guard kcal.isFinite, kcal > 0, met > 0 else { return 0 }
        let kcalPerMinute = met * kg / 60.0
        guard kcalPerMinute > 0 else { return 0 }
        return max(1, Int((kcal / kcalPerMinute).rounded()))
    }

    static func walkMinutes(toBurn kcal: Double, weightKg: Double?) -> Int {
        minutes(toBurn: kcal, met: briskWalkMET, weightKg: weightKg)
    }

    static func jogMinutes(toBurn kcal: Double, weightKg: Double?) -> Int {
        minutes(toBurn: kcal, met: jogMET, weightKg: weightKg)
    }
}

/// The mirror image of `ActivityBurnEstimator`: when the user is *under*
/// their calorie goal, this turns "calories left" into a concrete, smart
/// "what to eat" nudge instead of a "burn it off" one.
///
/// It is intentionally **pure and local** — no network, no AI round-trip,
/// no Supabase read. The caller hands in today's already-loaded logs, the
/// remaining calorie/protein budget, and the clock; the engine decides:
///
///   1. **Time-aware** — which meal window are we in right now?
///      (breakfast 04–09, lunch 10–14, dinner 15–23 local).
///   2. **Meal-aware** — has the user already logged that meal today?
///      Inferred from each log's `eatenAt` hour (FoodLog has no meal-type
///      column), the same windowing `EatingTimeInference` uses.
///      - The current meal isn't logged yet  → suggest *that meal*,
///        sized to the calories left ("Dinner is still open").
///      - It's evening and every meal is logged but they're still under
///        → suggest an *add-on snack* to close the gap ("Round out your day").
///      - An earlier meal is logged and more meals are still ahead → stay
///        quiet; there's no gap to nudge about yet.
///   3. **Budget-aware** — food ideas are filtered to fit the remaining
///      calories (a 650-kcal dinner idea won't show when 200 are left).
///   4. **Protein-aware** — when the user is also short on protein, the
///      ideas lean protein-forward and a short note says so.
///
/// Calorie bands follow standard guidance (breakfast ~300–400, lunch/dinner
/// ~500–700, snack ~150–250 kcal; ~20–40 g protein/meal for satiety).
enum MealSuggestionEngine {

    /// The eating moment a suggestion is about.
    enum MealSlot: Equatable {
        case breakfast, lunch, dinner, snack

        var noun: String {
            switch self {
            case .breakfast: return "breakfast"
            case .lunch:     return "lunch"
            case .dinner:    return "dinner"
            case .snack:     return "snack"
            }
        }

        /// SF Symbol for the card's leading icon.
        var iconName: String {
            switch self {
            case .breakfast: return "sunrise.fill"
            case .lunch:     return "sun.max.fill"
            case .dinner:    return "moon.stars.fill"
            case .snack:     return "leaf.fill"
            }
        }

        /// Which slot an hour-of-day falls into. Dinner intentionally
        /// stretches to 23:00 so a late meal still counts as "dinner"
        /// rather than slipping into an unbucketed gap. Returns nil for
        /// the overnight hours (00–03) where we never nudge.
        static func forHour(_ h: Int) -> MealSlot? {
            switch h {
            case 4...9:   return .breakfast
            case 10...14: return .lunch
            case 15...23: return .dinner
            default:      return nil
            }
        }
    }

    /// A single concrete food idea plus the metadata we filter/sort on.
    struct Idea: Equatable {
        let text: String
        let approxKcal: Int
        let proteinRich: Bool
    }

    /// The rendered result handed to the card. `nil` from `suggestion(...)`
    /// means "show nothing".
    struct Suggestion: Equatable {
        let slot: MealSlot
        let headline: String
        let detail: String
        /// 1–3 concrete ideas, already sized to the remaining budget.
        let ideas: [String]
        /// Short protein nudge, or nil when protein isn't the gap.
        let proteinNote: String?
        let targetKcal: Int
        let systemImage: String
    }

    // MARK: - Tunables

    /// Below this we treat the user as effectively on goal — the ring's
    /// own "approaching / reached" copy covers it, and a food nudge for
    /// ~100 kcal would feel naggy.
    static let minRemainingKcal: Double = 120
    /// A real meal needs at least this much room; under it we downgrade an
    /// open-meal suggestion to a light snack.
    static let lightMealFloorKcal: Int = 250
    /// Protein gap (g) at or above which ideas go protein-forward.
    static let proteinFocusThresholdG: Double = 15

    // MARK: - Entry point

    /// Build a suggestion, or `nil` when nothing should be shown.
    ///
    /// - Parameters:
    ///   - todaysLogs: every food log for *today* (already in memory on the
    ///     Tracker tab — pass it straight through, no fetch).
    ///   - remaining: calories left to goal (`DailyCalorieGoalStatus.remaining`).
    ///   - proteinRemaining: grams of protein left to the protein goal (clamp ≥ 0).
    ///   - goalDirection: changes the framing (gain → "target", else "goal").
    ///   - now / timeZone: the clock, injectable for tests.
    static func suggestion(
        todaysLogs: [FoodLog],
        remaining: Double,
        proteinRemaining: Double,
        goalDirection: CalorieGoalCalculator.GoalDirection?,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Suggestion? {
        guard remaining.isFinite, remaining >= minRemainingKcal else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: now)
        guard let current = MealSlot.forHour(hour) else { return nil } // overnight

        // Which main meals are already on the board today, by eaten-at hour.
        var logged: Set<MealSlot> = []
        for log in todaysLogs {
            let h = cal.component(.hour, from: log.eatenAt)
            if let s = MealSlot.forHour(h) { logged.insert(s) }
        }

        let budget = roundKcal(remaining)
        let isGain = goalDirection == .gain
        let proteinFocus = proteinRemaining.isFinite
            && proteinRemaining >= proteinFocusThresholdG
        let dayIndex = cal.ordinality(of: .day, in: .year, for: now) ?? 0

        // Decide the trigger:
        //   - current meal not logged  → suggest it (or a light bite if the
        //     budget is too small for a real meal).
        //   - current meal logged AND it's dinner-time → all meals are in but
        //     they're still short → add-on snack.
        //   - current meal logged but more meals are still ahead → stay quiet.
        let didLogCurrent = logged.contains(current)

        if !didLogCurrent {
            if budget >= lightMealFloorKcal {
                return openMeal(current, budget: budget, isGain: isGain,
                                proteinFocus: proteinFocus,
                                proteinRemaining: proteinRemaining,
                                dayIndex: dayIndex)
            } else {
                return almostThere(missing: current, budget: budget,
                                   proteinFocus: proteinFocus,
                                   proteinRemaining: proteinRemaining,
                                   dayIndex: dayIndex)
            }
        } else if current == .dinner {
            return topUp(budget: budget, isGain: isGain,
                         proteinFocus: proteinFocus,
                         proteinRemaining: proteinRemaining,
                         dayIndex: dayIndex)
        } else {
            return nil
        }
    }

    // MARK: - Trigger builders

    /// The current meal hasn't been logged and there's room for it.
    private static func openMeal(_ meal: MealSlot, budget: Int, isGain: Bool,
                                 proteinFocus: Bool, proteinRemaining: Double,
                                 dayIndex: Int) -> Suggestion {
        let ideas = pickIdeas(from: pool(for: meal), budget: budget,
                              proteinFocus: proteinFocus, dayIndex: dayIndex)
        let goalWord = isGain ? "target" : "goal"
        return Suggestion(
            slot: meal,
            headline: "\(meal.noun.capitalized) is still open",
            detail: "You've got about \(budget) kcal left toward your \(goalWord) — "
                + "room for \(sizeWord(budget)) \(meal.noun).",
            ideas: ideas,
            proteinNote: proteinNote(proteinFocus: proteinFocus,
                                     proteinRemaining: proteinRemaining),
            targetKcal: budget,
            systemImage: meal.iconName
        )
    }

    /// The current meal isn't logged, but they're nearly on goal — a real
    /// meal would overshoot, so suggest a light bite.
    private static func almostThere(missing meal: MealSlot, budget: Int,
                                    proteinFocus: Bool, proteinRemaining: Double,
                                    dayIndex: Int) -> Suggestion {
        let ideas = pickIdeas(from: snackIdeas, budget: budget,
                              proteinFocus: proteinFocus, dayIndex: dayIndex)
        return Suggestion(
            slot: .snack,
            headline: "You're almost at your goal",
            detail: "About \(budget) kcal to go and you haven't logged "
                + "\(meal.noun) yet — a light bite covers it.",
            ideas: ideas,
            proteinNote: proteinNote(proteinFocus: proteinFocus,
                                     proteinRemaining: proteinRemaining),
            targetKcal: budget,
            systemImage: MealSlot.snack.iconName
        )
    }

    /// Every main meal is logged but they're still under — close the gap.
    /// A large gap warrants another small meal; a small one, a snack.
    private static func topUp(budget: Int, isGain: Bool,
                              proteinFocus: Bool, proteinRemaining: Double,
                              dayIndex: Int) -> Suggestion {
        let bigGap = budget >= 400
        let ideaPool = bigGap ? pool(for: .dinner) : snackIdeas
        let ideas = pickIdeas(from: ideaPool, budget: budget,
                              proteinFocus: proteinFocus, dayIndex: dayIndex)
        let goalWord = isGain ? "target" : "goal"
        let closer: String
        if bigGap {
            closer = isGain
                ? "Another small meal gets you to target."
                : "Another light meal would close the gap."
        } else {
            closer = isGain
                ? "A protein-rich snack helps you hit it."
                : "A small snack rounds out the day."
        }
        return Suggestion(
            slot: .snack,
            headline: isGain ? "Just short of your target" : "Round out your day",
            detail: "You've logged your meals but you're about \(budget) kcal "
                + "under your \(goalWord). \(closer)",
            ideas: ideas,
            proteinNote: proteinNote(proteinFocus: proteinFocus,
                                     proteinRemaining: proteinRemaining),
            targetKcal: budget,
            systemImage: bigGap ? MealSlot.dinner.iconName : MealSlot.snack.iconName
        )
    }

    // MARK: - Idea selection

    /// Filter a pool to ideas that fit the budget (with a little slack so a
    /// 650-kcal idea still shows for a 600 budget), bias protein-rich first
    /// when protein is the gap, then rotate by day so the same three don't
    /// repeat forever. Falls back to the smallest ideas if nothing fits.
    static func pickIdeas(from pool: [Idea], budget: Int,
                          proteinFocus: Bool, dayIndex: Int,
                          count: Int = 3) -> [String] {
        let fitting = pool.filter { $0.approxKcal <= budget + 100 }
        let usable = fitting.isEmpty
            ? pool.sorted { $0.approxKcal < $1.approxKcal }
            : fitting

        let groups: [[Idea]]
        if proteinFocus {
            groups = [usable.filter { $0.proteinRich },
                      usable.filter { !$0.proteinRich }]
        } else {
            groups = [usable]
        }

        var chosen: [Idea] = []
        for group in groups where chosen.count < count {
            let rotated = rotate(group, by: dayIndex)
            for idea in rotated where chosen.count < count {
                if !chosen.contains(idea) { chosen.append(idea) }
            }
        }
        return chosen.map(\.text)
    }

    private static func rotate(_ arr: [Idea], by offset: Int) -> [Idea] {
        guard arr.count > 1 else { return arr }
        let k = ((offset % arr.count) + arr.count) % arr.count
        return Array(arr[k...] + arr[..<k])
    }

    // MARK: - Copy helpers

    /// "a full" / "a balanced" / "a light" by remaining budget.
    private static func sizeWord(_ budget: Int) -> String {
        if budget >= 550 { return "a full" }
        if budget >= 350 { return "a balanced" }
        return "a light"
    }

    private static func proteinNote(proteinFocus: Bool,
                                    proteinRemaining: Double) -> String? {
        guard proteinFocus, proteinRemaining.isFinite else { return nil }
        let g = Int(proteinRemaining.rounded())
        return "You're about \(g)g under on protein too — these lean protein-forward."
    }

    /// A one-line, budget-only nudge for *glanceable* surfaces (the Home
    /// goal card, the post-scan result) that don't have today's logs in
    /// memory — so it does no meal inference and lists no ideas, just the
    /// size of meal the remaining budget allows. Returns just the
    /// actionable half ("Room for a balanced meal.") because those surfaces
    /// already show the remaining number in their headline. `nil` when the
    /// user is basically on goal (below the floor), so nothing renders.
    static func compactLine(remaining: Double) -> String? {
        guard remaining.isFinite, remaining >= minRemainingKcal else { return nil }
        let budget = roundKcal(remaining)
        let noun: String
        if budget < lightMealFloorKcal { noun = "a light snack" }
        else if budget < 350          { noun = "a light meal" }
        else if budget < 550          { noun = "a balanced meal" }
        else                          { noun = "a full meal" }
        return "Room for \(noun)."
    }

    /// Round to the nearest 10 (≥100) or 5 so the number reads like a
    /// human estimate, not a raw float. Matches the tracker's other labels.
    static func roundKcal(_ v: Double) -> Int {
        let value = max(0, v)
        if value >= 100 { return Int((value / 10).rounded()) * 10 }
        return Int((value / 5).rounded()) * 5
    }

    // MARK: - Idea pools
    //
    // Curated, broadly-acceptable, health-leaning options grouped by slot
    // and tagged with an approximate kcal and whether they carry a
    // meaningful protein hit (~15g+). Kept local so suggestions are instant
    // and offline; personalizing from the user's own history is a natural
    // later step.

    static func pool(for slot: MealSlot) -> [Idea] {
        switch slot {
        case .breakfast: return breakfastIdeas
        case .lunch:     return lunchIdeas
        case .dinner:    return dinnerIdeas
        case .snack:     return snackIdeas
        }
    }

    static let breakfastIdeas: [Idea] = [
        Idea(text: "Greek yogurt parfait with granola and berries", approxKcal: 350, proteinRich: true),
        Idea(text: "two scrambled eggs with whole-grain toast", approxKcal: 350, proteinRich: true),
        Idea(text: "a veggie omelette with a side of fruit", approxKcal: 400, proteinRich: true),
        Idea(text: "overnight oats with chia, milk, and banana", approxKcal: 380, proteinRich: true),
        Idea(text: "oatmeal with banana and peanut butter", approxKcal: 400, proteinRich: false),
        Idea(text: "avocado toast with a poached egg", approxKcal: 350, proteinRich: true),
    ]

    static let lunchIdeas: [Idea] = [
        Idea(text: "a grilled chicken and quinoa bowl", approxKcal: 550, proteinRich: true),
        Idea(text: "a turkey and avocado wrap", approxKcal: 500, proteinRich: true),
        Idea(text: "a big salad with grilled chicken and chickpeas", approxKcal: 500, proteinRich: true),
        Idea(text: "a salmon rice bowl with veggies", approxKcal: 600, proteinRich: true),
        Idea(text: "lentil soup with whole-grain bread", approxKcal: 450, proteinRich: true),
        Idea(text: "a tuna sandwich with a side salad", approxKcal: 480, proteinRich: true),
    ]

    static let dinnerIdeas: [Idea] = [
        Idea(text: "grilled salmon with rice and roasted vegetables", approxKcal: 650, proteinRich: true),
        Idea(text: "grilled chicken with sweet potato and greens", approxKcal: 600, proteinRich: true),
        Idea(text: "a tofu and veggie stir-fry over brown rice", approxKcal: 550, proteinRich: true),
        Idea(text: "lean beef with quinoa and roasted veggies", approxKcal: 650, proteinRich: true),
        Idea(text: "baked chicken with pasta and a side salad", approxKcal: 700, proteinRich: true),
        Idea(text: "a bean and veggie burrito bowl", approxKcal: 600, proteinRich: false),
    ]

    static let snackIdeas: [Idea] = [
        Idea(text: "Greek yogurt with berries", approxKcal: 150, proteinRich: true),
        Idea(text: "cottage cheese with pineapple", approxKcal: 180, proteinRich: true),
        Idea(text: "a hard-boiled egg and a piece of fruit", approxKcal: 160, proteinRich: true),
        Idea(text: "a protein shake or smoothie", approxKcal: 200, proteinRich: true),
        Idea(text: "edamame with a little sea salt", approxKcal: 150, proteinRich: true),
        Idea(text: "an apple with a tablespoon of peanut butter", approxKcal: 200, proteinRich: false),
        Idea(text: "a handful of almonds", approxKcal: 170, proteinRich: false),
        Idea(text: "hummus with carrot and cucumber sticks", approxKcal: 150, proteinRich: false),
    ]
}

/// A retrospective per-day verdict: how a *completed* day landed against the
/// calorie goal, with a direction-aware recommendation. Powers the standing
/// block on the day-detail card (records dots, Week, Month). Pure + local —
/// reuses `DailyCalorieGoalStatus`, `ActivityBurnEstimator` (burn-off), and
/// `MealSuggestionEngine.compactLine` (food rec), so it costs no egress.
///
/// Direction matters:
///   - lose / maintain (default): over goal → walk/jog to burn it off;
///     under goal → "you had room" food rec.
///   - gain: over *target* is good (fuel, no burn-off); under target → eat-up
///     food rec (the meaningful gap for a bulk).
enum DayCalorieStanding {
    enum Kind: Equatable { case under, over, onGoal }

    struct Result: Equatable {
        let kind: Kind
        /// Rounded kcal over/under (0 when on goal).
        let amount: Int
        let headline: String
        let headlineImage: String
        let recommendation: String?
        let recommendationImage: String?
        /// True only for an over-goal day on a lose/maintain plan — the one
        /// case we tint as a gentle warning. Everything else reads neutral
        /// or positive (the brand is non-shaming).
        let isWarning: Bool
    }

    /// Within this many kcal either side of goal counts as "on goal" — a day
    /// doesn't need to hit the number to the calorie to be a win.
    static let onGoalToleranceKcal: Double = 75

    static func compute(dayCalories: Double,
                        goal: Double,
                        direction: CalorieGoalCalculator.GoalDirection?,
                        bodyWeightKg: Double?) -> Result? {
        guard goal > 0, dayCalories.isFinite, dayCalories >= 0 else { return nil }
        let status = DailyCalorieGoalStatus.compute(consumed: dayCalories, goal: goal)
        let isGain = direction == .gain

        // OVER
        if status.exceededBy > onGoalToleranceKcal {
            let over = MealSuggestionEngine.roundKcal(status.exceededBy)
            if isGain {
                return Result(
                    kind: .over, amount: over,
                    headline: "\(over) cal over your target",
                    headlineImage: "checkmark.seal.fill",
                    recommendation: "Plenty of fuel for building.",
                    recommendationImage: "sparkles",
                    isWarning: false
                )
            }
            let walk = ActivityBurnEstimator.walkMinutes(toBurn: status.exceededBy, weightKg: bodyWeightKg)
            let jog  = ActivityBurnEstimator.jogMinutes(toBurn: status.exceededBy, weightKg: bodyWeightKg)
            return Result(
                kind: .over, amount: over,
                headline: "\(over) cal over your goal",
                headlineImage: "exclamationmark.circle.fill",
                recommendation: "About a \(walk)-min walk or \(jog)-min jog evens it out.",
                recommendationImage: "figure.walk",
                isWarning: true
            )
        }

        // UNDER
        if status.remaining > onGoalToleranceKcal {
            let under = MealSuggestionEngine.roundKcal(status.remaining)
            let goalWord = isGain ? "target" : "goal"
            return Result(
                kind: .under, amount: under,
                headline: "\(under) cal under your \(goalWord)",
                headlineImage: "target",
                recommendation: MealSuggestionEngine.compactLine(remaining: status.remaining),
                recommendationImage: "fork.knife",
                isWarning: false
            )
        }

        // ON GOAL (within tolerance either side)
        return Result(
            kind: .onGoal, amount: 0,
            headline: isGain ? "Right on your target" : "Right on your goal",
            headlineImage: "checkmark.seal.fill",
            recommendation: "Nicely balanced day.",
            recommendationImage: "sparkles",
            isWarning: false
        )
    }
}
