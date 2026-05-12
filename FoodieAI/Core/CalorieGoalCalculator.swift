import Foundation

/// Phase 20. Pure calculator for a user's recommended daily calorie +
/// macro targets from physiology and goal direction.
///
/// Math sources:
///   - Mifflin & St Jeor (1990), J Am Diet Assoc 91(2):241-247.
///   - Frankenfield et al. (2005) systematic review — Mifflin-St Jeor
///     out-performs Harris-Benedict, Owen, and WHO/FAO/UNU within 10%
///     of measured BMR more consistently.
///   - US Dietary Guidelines for Americans 2020–2025 — 50/25/25
///     carb/protein/fat split is the standard recommended range.
///   - CDC and NIH clinical guidance — 500 kcal/day is the safe deficit
///     for ~0.5 kg/week weight change; larger deficits are reserved for
///     clinically supervised programs.
///   - Sex floor minimums (1200 kcal female / 1500 kcal male) align
///     with the daily intake below which most adults can't meet nutrient
///     needs without supplementation.
///
/// Decisions worth flagging in review:
///   - `unspecified` sex uses the average of the male (+5) and female
///     (-161) constants — effective -78 — and a 1350 kcal floor
///     (average of 1200 and 1500). Deliberate inclusive default; users
///     who want a sharper estimate select male/female.
///   - We intentionally do NOT surface BMI. Mifflin-St Jeor doesn't
///     consume it; BMI is widely critiqued (can't distinguish muscle
///     from fat, often stigmatizing) and would be cosmetic only.
enum CalorieGoalCalculator {

    // MARK: - Inputs

    enum BiologicalSex: String, Codable, CaseIterable, Hashable {
        case male
        case female
        case unspecified

        var displayLabel: String {
            switch self {
            case .male:        return "Male"
            case .female:      return "Female"
            case .unspecified: return "Prefer not to say"
            }
        }

        /// Mifflin-St Jeor sex constant. Averaged for `unspecified` so
        /// the inclusive option still lands between the two formulas.
        var bmrConstant: Double {
            switch self {
            case .male:        return  5
            case .female:      return -161
            case .unspecified: return -78
            }
        }

        /// Minimum recommended daily intake. Floored at this value when
        /// the computed deficit would otherwise push the user below
        /// safe nutrient-sufficiency thresholds.
        var calorieFloor: Double {
            switch self {
            case .male:        return 1500
            case .female:      return 1200
            case .unspecified: return 1350
            }
        }
    }

    enum ActivityLevel: String, Codable, CaseIterable, Hashable {
        case sedentary
        case light
        case moderate
        case very
        case extra

        var multiplier: Double {
            switch self {
            case .sedentary: return 1.2
            case .light:     return 1.375
            case .moderate:  return 1.55
            case .very:      return 1.725
            case .extra:     return 1.9
            }
        }

        var displayLabel: String {
            switch self {
            case .sedentary: return "Sedentary (little or no exercise)"
            case .light:     return "Lightly active (1–3 days/week)"
            case .moderate:  return "Moderately active (3–5 days/week)"
            case .very:      return "Very active (6–7 days/week)"
            case .extra:     return "Extra active (athlete or physical job)"
            }
        }

        var shortLabel: String {
            switch self {
            case .sedentary: return "Sedentary"
            case .light:     return "Lightly active"
            case .moderate:  return "Moderately active"
            case .very:      return "Very active"
            case .extra:     return "Extra active"
            }
        }
    }

    enum GoalDirection: String, Codable, CaseIterable, Hashable {
        case lose
        case maintain
        case gain

        /// kcal/day delta from TDEE. 500 is the CDC/NIH conservative
        /// number; deliberately not configurable in v1.
        var calorieDelta: Int {
            switch self {
            case .lose:     return -500
            case .maintain: return 0
            case .gain:     return 500
            }
        }

        var displayLabel: String {
            switch self {
            case .lose:     return "Lose weight"
            case .maintain: return "Maintain weight"
            case .gain:     return "Gain weight"
            }
        }
    }

    struct Physiology: Equatable {
        let sex: BiologicalSex
        let ageYears: Int
        let heightCm: Double
        let weightKg: Double
        let activity: ActivityLevel
        let goal: GoalDirection
    }

    // MARK: - Outputs

    struct Goals: Equatable {
        let bmr: Int
        let tdee: Int
        /// Daily calorie target, floored at the sex-specific minimum
        /// when the raw deficit math would have gone lower.
        let calories: Int
        let carbsG: Int
        let proteinG: Int
        let fatG: Int
        let fiberG: Int
        let sugarG: Int
        /// True when `calories` was clamped to `BiologicalSex.calorieFloor`.
        /// UI surfaces a small caption explaining the safe minimum.
        let wasFloored: Bool
    }

    // MARK: - Compute

    static func compute(_ phys: Physiology) -> Goals {
        // Step 1 — Mifflin-St Jeor BMR.
        let bmr = (10 * phys.weightKg)
                + (6.25 * phys.heightCm)
                - (5 * Double(phys.ageYears))
                + phys.sex.bmrConstant

        // Step 2 — TDEE via activity multiplier.
        let tdee = bmr * phys.activity.multiplier

        // Step 3 — Apply goal-direction delta.
        let raw = tdee + Double(phys.goal.calorieDelta)

        // Step 4 — Floor at the safe minimum.
        let floor = phys.sex.calorieFloor
        let floored = raw < floor
        let calories = Int((floored ? floor : raw).rounded())

        // Step 5 — Derive macros from calorie target. Same numbers as
        // MacroGoalCalculator (50/25/25 + 14g/1000kcal fiber + 10% sugar
        // ceiling); duplicated here so this computation stays self-
        // contained and the unit tests can pin every number.
        let carbs   = Int(round(Double(calories) * 0.50 / 4.0))
        let protein = Int(round(Double(calories) * 0.25 / 4.0))
        let fat     = Int(round(Double(calories) * 0.25 / 9.0))
        let fiber   = Int(round(Double(calories) / 1000.0 * 14.0))
        let sugar   = Int(round(Double(calories) * 0.10 / 4.0))

        return Goals(
            bmr:        Int(bmr.rounded()),
            tdee:       Int(tdee.rounded()),
            calories:   calories,
            carbsG:     carbs,
            proteinG:   protein,
            fatG:       fat,
            fiberG:     fiber,
            sugarG:     sugar,
            wasFloored: floored
        )
    }

    /// Convenience for the "Recalculate macros from calories" button on
    /// the manual editor — preserves a user-customized calorie target
    /// but regenerates the five macro fields from it.
    static func macrosFromCalories(_ calories: Int) -> (carbsG: Int,
                                                        proteinG: Int,
                                                        fatG: Int,
                                                        fiberG: Int,
                                                        sugarG: Int) {
        let c = Double(calories)
        return (
            carbsG:   Int(round(c * 0.50 / 4.0)),
            proteinG: Int(round(c * 0.25 / 4.0)),
            fatG:     Int(round(c * 0.25 / 9.0)),
            fiberG:   Int(round(c / 1000.0 * 14.0)),
            sugarG:   Int(round(c * 0.10 / 4.0))
        )
    }
}
