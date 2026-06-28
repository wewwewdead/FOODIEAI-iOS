import Foundation

/// Ties the movement half of the daily loop (steps + active energy) to the
/// calorie half (energy in) — *without* double-counting the activity a
/// TDEE-based goal already assumes. Pure and local: no network, no egress.
///
/// Research basis (gathered 2026-06; see `step_goal_design` work-doc):
///   - Step targets track **goal direction + age**, not bodyweight. The
///     all-cause-mortality benefit rises steeply then plateaus ~7–8k steps
///     (Paluch 2021 CARDIA; 2022 Lancet meta-analysis), lower for adults 60+.
///     Tudor-Locke's "active" tier is ≥10k, and the Step-Up trial's ≥10%
///     weight-loss group averaged ~9.8k — so 10k is the evidence-aligned
///     *lose* target. "10,000 for everyone" was 1965 pedometer marketing.
///   - Active kcal from steps ≈ 0.0004 × kg × steps (NET — i.e. movement only,
///     matching HealthKit `activeEnergyBurned`, which excludes resting energy).
///     Corroborated by per-step, MET, and walking-economy methods.
///   - A goal of `BMR × m` already bakes in `BMR × (m − 1)` of active energy
///     (PAL = TEE/BMR by definition). HealthKit's active energy `A` is the
///     *measured* version of that same quantity, so the only honest "earn-back"
///     credit is the measured energy ABOVE that baseline:
///     `max(0, A − BMR×(m−1))`. A 0.5 haircut hedges documented tracker
///     overestimation. The user's own activity-level choice thus becomes the
///     gamification dial: "sedentary" assumes little → most movement earns
///     room back; "very active" already counts it → little is credited.
enum StepGoalCalculator {

    /// Evidence-aligned default daily step goal. Driven by goal direction and
    /// age — **not** bodyweight (weight changes calories-per-step, not the
    /// step target itself). Older adults plateau lower, so trim past ~60.
    static func dailyStepGoal(direction: CalorieGoalCalculator.GoalDirection?,
                              ageYears: Int?) -> Int {
        let base: Int
        switch direction {
        case .lose:     base = 10_000   // Tudor-Locke "active"; deficit assist
        case .gain:     base = 7_000    // cardio floor — steps oppose a surplus
        case .maintain: base = 8_000    // top of the mortality-benefit plateau
        case .none:     base = 8_000    // general default, no direction set
        }
        // Adults ~60+ hit the mortality plateau at a lower count (6–8k) and
        // 10k is often unsustainable — knock it down but never below 6k.
        if let age = ageYears, age >= 60 {
            return max(healthFloorSteps, base - 2_000)
        }
        return base
    }

    /// Lower bound for any goal — the mortality-benefit floor — so an
    /// under-eating day never eases the target down to "steps don't matter".
    static let healthFloorSteps = 6_000
    /// Upper bound so a big over-eating day never shows an absurd target.
    static let maxAdjustedSteps = 15_000

    /// Steps a brisk walk needs to burn `kcal`, kept consistent with the
    /// burn-off *minutes* shown elsewhere: `ActivityBurnEstimator` walk-minutes
    /// × the moderate cadence. So "burn 200 kcal" reads the same whether
    /// expressed as minutes or steps.
    static func stepsToWalkOff(_ kcal: Double, weightKg: Double?) -> Int {
        let minutes = ActivityBurnEstimator.walkMinutes(toBurn: kcal, weightKg: weightKg)
        return Int((Double(minutes) * MovementEnergy.stepsPerWalkMinute).rounded())
    }

    /// The day's step goal **flexed by calorie balance** (full offset). On a
    /// lose/maintain plan an over-goal day raises the target by the steps it
    /// takes to walk the excess off; an under-goal day eases it. Clamped to
    /// `[healthFloorSteps, maxAdjustedSteps]` and rounded to 500. Gain — and any
    /// missing weight/calorie data — returns the health base unchanged (a
    /// surplus is fuel, not something to walk off). Reference is the *base*
    /// calorie goal (what you ate vs your eating target), so the goal is a
    /// stable target for the day rather than one that recedes as you move.
    static func calorieAdjustedGoal(direction: CalorieGoalCalculator.GoalDirection?,
                                    ageYears: Int?,
                                    consumed: Double,
                                    calorieGoal: Double,
                                    weightKg: Double?) -> Int {
        let base = dailyStepGoal(direction: direction, ageYears: ageYears)
        guard direction != .gain, let kg = weightKg, kg > 0,
              calorieGoal > 0, consumed.isFinite, consumed >= 0 else { return base }
        let delta = consumed - calorieGoal
        guard abs(delta) > DayCalorieStanding.onGoalToleranceKcal else { return base }
        let shift = stepsToWalkOff(abs(delta), weightKg: kg)
        let raw = delta > 0 ? base + shift : base - shift
        let clamped = min(maxAdjustedSteps, max(healthFloorSteps, raw))
        return Int((Double(clamped) / 500).rounded()) * 500
    }
}

enum MovementEnergy {

    /// kcal · step⁻¹ · kg⁻¹ — NET (active-only). Multiply by bodyweight and
    /// step count for estimated active calories. Convergent across per-step,
    /// MET, and distance/economy derivations.
    static let netKcalPerStepPerKg: Double = 0.0004

    /// Fraction of above-baseline active energy credited back, hedging the
    /// documented tendency of wearables to overestimate. Conservative on
    /// purpose for a calorie app; tunable.
    static let creditHaircut: Double = 0.5

    /// Cadence for converting a walk's *duration* to a *step count* and back —
    /// a moderate everyday pace. Keeps "X-min walk" and "Y steps" consistent
    /// across the movement copy.
    static let stepsPerWalkMinute: Double = 110

    /// Estimated NET active calories for a step count at a given bodyweight.
    /// Used as a fallback when HealthKit active energy isn't available.
    static func activeKcalFromSteps(_ steps: Int, weightKg: Double?) -> Double {
        guard let kg = weightKg, kg.isFinite, kg > 0, steps > 0 else { return 0 }
        return netKcalPerStepPerKg * kg * Double(steps)
    }

    /// The active energy (kcal) a goal built at `multiplier` already assumes:
    /// `BMR × (multiplier − 1)`. This is the amount that must be subtracted
    /// from measured active energy to avoid double-counting.
    static func assumedActiveKcal(bmr: Double, multiplier: Double) -> Double {
        guard bmr.isFinite, bmr > 0, multiplier.isFinite, multiplier > 1 else { return 0 }
        return bmr * (multiplier - 1)
    }

    /// Calories to credit back to today's eating budget given measured active
    /// energy. `credit = max(0, active − assumed) × haircut`. Returns 0 when
    /// the measured energy doesn't exceed what the goal already assumed.
    static func budgetCredit(activeEnergyKcal: Double,
                             bmr: Double,
                             multiplier: Double,
                             haircut: Double = creditHaircut) -> Double {
        guard activeEnergyKcal.isFinite, activeEnergyKcal > 0 else { return 0 }
        let excess = activeEnergyKcal - assumedActiveKcal(bmr: bmr, multiplier: multiplier)
        guard excess > 0 else { return 0 }
        return excess * max(0, haircut)
    }

    /// Earn-back credit from the user's physiology + today's measured activity.
    /// Returns 0 unless we have the full physiology needed to know what
    /// activity the goal already assumes — so we never guess or double-count.
    /// Prefers measured HealthKit active energy; falls back to a step estimate.
    static func budgetCredit(activeEnergyKcal: Double,
                             steps: Int,
                             weightKg: Double?,
                             heightCm: Double?,
                             ageYears: Int?,
                             sex: CalorieGoalCalculator.BiologicalSex?,
                             activity: CalorieGoalCalculator.ActivityLevel?) -> Double {
        guard let sex, let ageYears, let heightCm, let weightKg, let activity,
              weightKg > 0, heightCm > 0 else { return 0 }
        let bmr = CalorieGoalCalculator.basalMetabolicRate(
            sex: sex, ageYears: ageYears, heightCm: heightCm, weightKg: weightKg)
        let active = activeEnergyKcal >= 1
            ? activeEnergyKcal
            : activeKcalFromSteps(steps, weightKg: weightKg)
        return budgetCredit(activeEnergyKcal: active, bmr: bmr,
                            multiplier: activity.multiplier)
    }

    /// Convenience over a `Profile`'s optional physiology fields.
    static func budgetCredit(profile: Profile,
                             activeEnergyKcal: Double,
                             steps: Int) -> Double {
        budgetCredit(activeEnergyKcal: activeEnergyKcal, steps: steps,
                     weightKg: profile.weightKg, heightCm: profile.heightCm,
                     ageYears: profile.ageYears, sex: profile.biologicalSex,
                     activity: profile.activityLevel)
    }
}

/// Builds the direction-aware "meaning line" that sits under the movement ring,
/// explaining what the step goal actually *does* for the user's weight goal —
/// translated into calories via bodyweight when we have it. Pure copy logic.
enum MovementGoalNarrator {

    /// One short sentence. `weightKg == nil` falls back to kcal-free phrasing.
    static func meaningLine(direction: CalorieGoalCalculator.GoalDirection?,
                            goalSteps: Int,
                            weightKg: Double?) -> String {
        let kcal = Int(MovementEnergy.activeKcalFromSteps(goalSteps, weightKg: weightKg).rounded())
        let steps = stepsLabel(goalSteps)
        let hasKcal = kcal > 0

        switch direction {
        case .lose:
            return hasKcal
                ? "\(steps) steps ≈ \(kcal) kcal — \(deficitFraction(kcal)) your daily deficit. Move it and you can eat that much more and still lose."
                : "\(steps) steps a day is a real assist to your deficit — move more, eat a little more, still lose."
        case .maintain:
            return hasKcal
                ? "\(steps) steps ≈ \(kcal) kcal — the daily movement your maintenance goal already assumes. Hit it and eating to goal truly holds steady."
                : "\(steps) steps is the movement your goal counts on — hit it and your budget stays a true maintenance number."
        case .gain:
            return hasKcal
                ? "\(steps) steps ≈ \(kcal) kcal — for your heart, not the scale. Steps burn calories, so eat that back to keep gaining."
                : "\(steps) steps is a heart-health floor — steps burn calories, so eat back what you move to keep gaining."
        case .none:
            return hasKcal
                ? "\(steps) steps ≈ \(kcal) kcal — most of the health benefit, and enough to keep your calorie goal honest."
                : "\(steps) steps covers most of the health benefit and keeps your calorie goal honest."
        }
    }

    /// The line under the movement ring, explaining the **calorie-adjusted**
    /// step goal. Over the calorie goal (lose/maintain) → states the extra
    /// steps the excess costs and the nudged goal; under → notes the eased
    /// goal; otherwise → the plain steps-to-goal nudge. `adjustedStepGoal` is
    /// the goal already produced by `StepGoalCalculator.calorieAdjustedGoal`;
    /// `calorieGoal` is the *base* eating goal. Pure copy logic.
    static func guidanceLine(direction: CalorieGoalCalculator.GoalDirection?,
                             currentSteps: Int,
                             baseStepGoal: Int,
                             adjustedStepGoal: Int,
                             consumed: Double,
                             calorieGoal: Double,
                             weightKg: Double?) -> String {
        let canCorrelate = direction != .gain && calorieGoal > 0
        let overBy = consumed - calorieGoal

        // OVER calories → the extra steps to walk it off + the nudged goal.
        if canCorrelate, overBy > DayCalorieStanding.onGoalToleranceKcal {
            let over = MealSuggestionEngine.roundKcal(overBy)
            let extra = max(0, adjustedStepGoal - baseStepGoal)
            // Hit the bumped goal already → the excess is worked off.
            if currentSteps >= adjustedStepGoal && extra > 0 {
                return "Movement's matched today's \(over) over — nicely balanced."
            }
            // Did the clamp shave the bump? Then it only chips at the excess.
            let needed = StepGoalCalculator.stepsToWalkOff(overBy, weightKg: weightKg)
            let verb = extra < needed ? "chips away at it" : "offsets it"
            return "\(over) over — about \(stepsLabel(extra)) extra steps (\(walkPhrase(forSteps: extra))) \(verb). Goal nudged to \(stepsLabel(adjustedStepGoal))."
        }

        // UNDER calories → the eased goal (never below the health floor).
        if canCorrelate, -overBy > DayCalorieStanding.onGoalToleranceKcal,
           adjustedStepGoal < baseStepGoal {
            let under = MealSuggestionEngine.roundKcal(-overBy)
            return "Ate \(under) under — step goal eased to \(stepsLabel(adjustedStepGoal)) for today."
        }

        // ON GOAL / gain / no data → the plain goal-oriented step nudge.
        return goalSuggestion(direction: direction, currentSteps: currentSteps,
                              goalSteps: adjustedStepGoal, weightKg: weightKg)
    }

    /// Progress-aware, goal-oriented nudge for *right now*: given today's steps
    /// so far, how much walking (if any) moves the user toward their
    /// physiological goal — phrased correctly per direction. Walking deepens a
    /// deficit but *fights* a surplus, so a gainer is never told to "walk more
    /// to hit your goal": their step target is a health floor, and whatever
    /// they walk should be eaten back to keep gaining. Pure copy logic.
    static func goalSuggestion(direction: CalorieGoalCalculator.GoalDirection?,
                               currentSteps: Int,
                               goalSteps: Int,
                               weightKg: Double?) -> String {
        let goal = stepsLabel(goalSteps)
        let remaining = max(0, goalSteps - currentSteps)

        // Already at/over today's step goal — affirm, don't push more cardio.
        if remaining == 0 {
            switch direction {
            case .lose:     return "\(goal) steps in — goal hit. Any extra walk now deepens today's deficit."
            case .maintain: return "\(goal) steps in — you're matched with your maintenance plan for today."
            case .gain:     return "\(goal) steps in — plenty for gaining. No need to add cardio; if you do, eat it back."
            case .none:     return "\(goal) steps in — you've reached the daily mark tied to better health."
            }
        }

        let remain = stepsLabel(remaining)
        let walk = walkPhrase(forSteps: remaining)
        let kcal = Int(MovementEnergy.activeKcalFromSteps(remaining, weightKg: weightKg).rounded())

        switch direction {
        case .lose:
            let burn = kcal >= 10 ? ", ~\(kcal) kcal toward your deficit" : ""
            return "\(remain) steps to your \(goal) goal — \(walk)\(burn)."
        case .maintain:
            return "\(remain) steps to your \(goal) goal — \(walk) keeps today balanced."
        case .gain:
            return "\(remain) steps to your \(goal) floor — a short walk covers circulation and appetite. Gaining needs no more; eat back what you walk."
        case .none:
            return "\(remain) steps to your \(goal) goal — \(walk) reaches the daily health mark."
        }
    }

    /// Minutes of walking to cover `steps`, at a moderate cadence, rounded to
    /// the nearest 5 (min 5).
    static func walkMinutes(forSteps steps: Int) -> Int {
        let raw = Double(max(0, steps)) / MovementEnergy.stepsPerWalkMinute
        return max(5, Int((raw / 5).rounded()) * 5)
    }

    /// Human phrase for the walking a step target needs: a single "~25-min
    /// walk" for shorter targets; "~75 min of walking today" once it's clearly
    /// more than one outing, so it never implies a single marathon walk.
    static func walkPhrase(forSteps steps: Int) -> String {
        let minutes = walkMinutes(forSteps: steps)
        return minutes >= 45 ? "~\(minutes) min of walking today" : "about a \(minutes)-min walk"
    }

    /// How much of a standard 500 kcal/day deficit the step burn covers.
    /// (500 = `CalorieGoalCalculator.GoalDirection.lose` delta.)
    private static func deficitFraction(_ kcal: Int) -> String {
        switch Double(kcal) / 500.0 {
        case 0.85...:    return "covers most of"
        case 0.6..<0.85: return "covers about two-thirds of"
        case 0.4..<0.6:  return "covers about half of"
        case 0.2..<0.4:  return "covers about a third of"
        default:         return "chips into"
        }
    }

    private static func stepsLabel(_ steps: Int) -> String {
        Self.formatter.string(from: NSNumber(value: steps)) ?? "\(steps)"
    }
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}

/// One source of truth for the movement ring: the calorie-adjusted step goal
/// *and* the caption that explains it, computed together so they always agree.
/// Pure — the view just renders `stepGoal` on the ring and `line` beneath it.
enum MovementGuidance {
    struct Result: Equatable {
        /// Calorie-adjusted goal for the ring (lose/maintain flex; gain = base).
        let stepGoal: Int
        /// Health-derived base before any calorie adjustment.
        let baseStepGoal: Int
        /// Explanatory line under the ring.
        let line: String
    }

    static func compute(direction: CalorieGoalCalculator.GoalDirection?,
                        ageYears: Int?,
                        currentSteps: Int,
                        consumed: Double,
                        calorieGoal: Double,
                        weightKg: Double?) -> Result {
        let base = StepGoalCalculator.dailyStepGoal(direction: direction, ageYears: ageYears)
        let goal = StepGoalCalculator.calorieAdjustedGoal(
            direction: direction, ageYears: ageYears,
            consumed: consumed, calorieGoal: calorieGoal, weightKg: weightKg)
        let line = MovementGoalNarrator.guidanceLine(
            direction: direction, currentSteps: currentSteps,
            baseStepGoal: base, adjustedStepGoal: goal,
            consumed: consumed, calorieGoal: calorieGoal, weightKg: weightKg)
        return Result(stepGoal: goal, baseStepGoal: base, line: line)
    }
}
