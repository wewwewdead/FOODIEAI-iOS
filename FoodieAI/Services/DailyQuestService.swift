import Foundation

/// Phase 21.12 — one playful "Healthy Choice" prompt per day that the
/// user can complete by logging meals. The reward is a small
/// celebratory copy when next visiting Today, not a streak multiplier
/// or points — quests are retention engagement, not gamification
/// scoring. As of Phase 21.12 the pool is exclusively health-focused
/// (26 kinds): the older "log 3 meals", "try new food", "log before
/// 10 AM" etc. framings were dropped in favor of single, actionable
/// nutrition nudges.
///
/// Quest selection is filtered first by goal-appropriateness (Phase
/// 21.5) then ranked by a per-user behavioral gap score (Phase 21.6).
/// Same-day selection is deterministic — the kind never changes after
/// it's picked, but across days the user sees meaningfully different
/// prompts thanks to the larger pool and per-user rotation offset.
struct DailyQuest: Hashable, Codable {
    enum Kind: String, Codable, CaseIterable {
        // Phase 21 / 21.7 — kept after the Phase 21.12 reframing.
        case logSomethingGreen
        case logProtein
        case stayUnderGoal
        case logFruit
        case logFiber          // ≥5g fiber in one meal
        case logFermented      // kimchi, yogurt, kombucha, miso, sauerkraut, etc.
        case logWholeGrain     // oats, brown rice, quinoa, whole wheat, etc.
        case logLowSugar       // a meal with <5g sugar
        case logLightMeal      // a meal under 500 cal
        case hitProteinGoal    // total daily protein ≥ 80% of profile.dailyProteinGoalG

        // Phase 21.12 — health expansion.
        case logTwoVegServings
        case logCrucifer
        case logLeanProtein
        case logPlantProtein
        case logFattyFish
        case logHealthyFats
        case logNutsOrSeeds
        case logHomeCooked
        case logWholeIngredient
        case logEarlyDinnerHealth
        case logBalancedMeal
        case logLowProcessedMeal
        case logIronRich
        case logCalciumRich

        // Phase 21.13 — replace `logColorfulMeal` (which required
        // ingredient-level parsing the client doesn't have) with
        // three keyword-driven nudges that read cleanly off
        // `food_name`.
        case logBerry
        case logHydrationMeal
        case logAntioxidantRich

        /// The user-facing prompt copy on the Today card.
        var copy: String {
            switch self {
            case .logSomethingGreen: "Log something green today 🌿"
            case .logProtein:        "Find some protein — log a meal with 20g+"
            case .stayUnderGoal:     "Stay within your calorie goal today"
            case .logFruit:          "Log a fruit today 🍎"
            case .logFiber:          "Find some fiber — log a meal with 5g+ 🌾"
            case .logFermented:      "Log something fermented (kimchi, yogurt, miso) 🥬"
            case .logWholeGrain:     "Log a whole grain (oats, brown rice, quinoa) 🌾"
            case .logLowSugar:       "Log a meal under 5g of sugar 🍃"
            case .logLightMeal:      "Log a meal under 500 calories ☁️"
            case .hitProteinGoal:    "Hit your protein goal today 💪"

            case .logTwoVegServings:    "Eat two different veggies today 🥬"
            case .logCrucifer:          "Try a cruciferous veg today (broccoli, kale) 🥦"
            case .logLeanProtein:       "Choose a lean protein (chicken, fish, tofu) 🍗"
            case .logPlantProtein:      "Plant power — log beans, lentils, or tofu 🌱"
            case .logFattyFish:         "Omega-3 day — log salmon, mackerel, or sardines 🐟"
            case .logHealthyFats:       "Add a healthy fat — avocado, nuts, olive oil 🥑"
            case .logNutsOrSeeds:       "Snack on nuts or seeds today 🌰"
            case .logHomeCooked:        "Cook at home today 🍳"
            case .logWholeIngredient:   "Log a single-ingredient food today 🍎"
            case .logEarlyDinnerHealth: "Dinner before 7 PM tonight 🌙"
            case .logBalancedMeal:      "Log a balanced meal — carbs, protein, and fat ⚖️"
            case .logLowProcessedMeal:  "Choose less processed today 🌾"
            case .logIronRich:          "Iron up — spinach, lentils, or red meat 💪"
            case .logCalciumRich:       "Calcium check — dairy, leafy greens, or tofu 🦴"

            case .logBerry:             "Eat some berries today 🫐"
            case .logHydrationMeal:     "Log a hydrating meal (soup, salad, watermelon) 💧"
            case .logAntioxidantRich:   "Antioxidant boost — berries, dark chocolate, green tea 🌿"
            }
        }

        /// Reward copy when the quest just completed — surfaces in the
        /// success toast and on the Today card after completion.
        var rewardCopy: String {
            switch self {
            case .logSomethingGreen: "🌿 Quest complete — leafy points!"
            case .logProtein:        "💪 Protein found"
            case .stayUnderGoal:     "🎯 Hit your goal"
            case .logFruit:          "🍎 Fruit logged — small win"
            case .logFiber:          "🌾 Fiber found — gut happy"
            case .logFermented:      "🥬 Fermented power — quest done"
            case .logWholeGrain:     "🌾 Whole grain — slow energy"
            case .logLowSugar:       "🍃 Light on sugar — quest done"
            case .logLightMeal:      "☁️ Light meal — balanced"
            case .hitProteinGoal:    "💪 Protein goal — nailed it"

            case .logTwoVegServings:    "🥬 Two veggies — well rounded"
            case .logCrucifer:          "🥦 Cruciferous power"
            case .logLeanProtein:       "🍗 Lean choice — protein done right"
            case .logPlantProtein:      "🌱 Plant power found"
            case .logFattyFish:         "🐟 Omega-3 secured"
            case .logHealthyFats:       "🥑 Healthy fats — good for you"
            case .logNutsOrSeeds:       "🌰 Nuts and seeds — quest done"
            case .logHomeCooked:        "🍳 Home-cooked — quest complete"
            case .logWholeIngredient:   "🍎 Whole food — simple and good"
            case .logEarlyDinnerHealth: "🌙 Early dinner — sleep well"
            case .logBalancedMeal:      "⚖️ Balanced meal — perfectly done"
            case .logLowProcessedMeal:  "🌾 Less processed — quality choice"
            case .logIronRich:          "💪 Iron up — energy boost"
            case .logCalciumRich:       "🦴 Calcium — bones thank you"

            case .logBerry:             "🫐 Berries — antioxidant powerhouse"
            case .logHydrationMeal:     "💧 Hydration win — gentle on the body"
            case .logAntioxidantRich:   "🌿 Antioxidants — cells thank you"
            }
        }
    }

    let kind: Kind
    let dateLocal: Date
    let completed: Bool
}

// MARK: - Goal alignment (Phase 21.5 / 21.12)

extension DailyQuest.Kind {
    /// Whether this quest fits a user with the given archetype + goal.
    /// `nil` archetype → fall back to `.aware`; `nil` goal → fall back
    /// to `.maintain`. As of Phase 21.12 nearly every quest is
    /// universal (the whole pool is "healthy choices"); the only
    /// exclusions are framings that conflict with a deliberate goal.
    func isAppropriate(for archetype: Profile.Archetype?,
                       goal: CalorieGoalCalculator.GoalDirection?) -> Bool {
        let effectiveArchetype = archetype ?? .aware
        let effectiveGoal = goal ?? .maintain

        switch self {
        case .logSomethingGreen:
            return true
        case .logProtein:
            return effectiveArchetype == .buildMuscle
                || effectiveGoal == .gain
                || effectiveGoal == .lose
        case .stayUnderGoal:
            return effectiveGoal == .lose
                || (effectiveGoal == .maintain && effectiveArchetype == .aware)

        case .logFruit, .logFiber, .logFermented, .logWholeGrain:
            return true

        case .logLowSugar:
            // Skip for users in a surplus / muscle-building flow.
            return effectiveGoal == .lose
                || effectiveGoal == .maintain
                || effectiveArchetype == .aware
                || effectiveArchetype == .loseWeight

        case .logLightMeal:
            return effectiveGoal != .gain

        case .hitProteinGoal:
            return true

        // Phase 21.12 — health expansion. All universal except the
        // explicit "less processed" framing, which conflicts with
        // muscle-building users who lean on protein supplements.
        case .logTwoVegServings, .logCrucifer,
             .logLeanProtein, .logPlantProtein, .logFattyFish,
             .logHealthyFats, .logNutsOrSeeds, .logHomeCooked,
             .logWholeIngredient, .logEarlyDinnerHealth, .logBalancedMeal,
             .logIronRich, .logCalciumRich,
             .logBerry, .logHydrationMeal, .logAntioxidantRich:
            return true

        case .logLowProcessedMeal:
            return !(effectiveArchetype == .buildMuscle || effectiveGoal == .gain)
        }
    }
}

// MARK: - Gap scoring (Phase 21.6 / 21.12)

extension DailyQuest.Kind {
    /// Phase 21.6 — score 0.0–1.0 of how relevant this quest is to the
    /// user's recent behavior. Higher score = bigger gap = more
    /// relevant. The goal-alignment filter (Phase 21.5) runs first;
    /// this score then ranks what remains.
    func gapScore(recentLogs: [FoodLog]) -> Double {
        switch self {
        case .logSomethingGreen: return DailyQuestScoring.greenGap(in: recentLogs)
        case .logProtein:        return DailyQuestScoring.proteinGap(in: recentLogs)
        case .stayUnderGoal:     return DailyQuestScoring.underGoalGap(in: recentLogs)
        case .logFruit:          return DailyQuestScoring.fruitGap(in: recentLogs)
        case .logFiber:          return DailyQuestScoring.fiberGap(in: recentLogs)
        case .logFermented:      return DailyQuestScoring.fermentedGap(in: recentLogs)
        case .logWholeGrain:     return DailyQuestScoring.wholeGrainGap(in: recentLogs)
        case .logLowSugar:       return DailyQuestScoring.lowSugarGap(in: recentLogs)
        case .logLightMeal:      return DailyQuestScoring.lightMealGap(in: recentLogs)
        case .hitProteinGoal:    return DailyQuestScoring.proteinTotalGap(in: recentLogs)

        case .logTwoVegServings:    return DailyQuestScoring.scoreTwoVegGap(in: recentLogs)
        case .logCrucifer:          return DailyQuestScoring.scoreCruciferGap(in: recentLogs)
        case .logLeanProtein:       return DailyQuestScoring.scoreLeanProteinGap(in: recentLogs)
        case .logPlantProtein:      return DailyQuestScoring.scorePlantProteinGap(in: recentLogs)
        case .logFattyFish:         return DailyQuestScoring.scoreFattyFishGap(in: recentLogs)
        case .logHealthyFats:       return DailyQuestScoring.scoreHealthyFatGap(in: recentLogs)
        case .logNutsOrSeeds:       return DailyQuestScoring.scoreNutsAndSeedsGap(in: recentLogs)
        case .logHomeCooked:        return DailyQuestScoring.scoreHomeCookedGap(in: recentLogs)
        case .logWholeIngredient:   return DailyQuestScoring.scoreWholeIngredientGap(in: recentLogs)
        case .logEarlyDinnerHealth: return DailyQuestScoring.scoreEarlyDinnerHealthGap(in: recentLogs)
        case .logBalancedMeal:      return DailyQuestScoring.scoreBalancedMealGap(in: recentLogs)
        case .logLowProcessedMeal:  return DailyQuestScoring.scoreLowProcessedGap(in: recentLogs)
        case .logIronRich:          return DailyQuestScoring.scoreIronRichGap(in: recentLogs)
        case .logCalciumRich:       return DailyQuestScoring.scoreCalciumRichGap(in: recentLogs)

        case .logBerry:             return DailyQuestScoring.scoreBerryGap(in: recentLogs)
        case .logHydrationMeal:     return DailyQuestScoring.scoreHydrationGap(in: recentLogs)
        case .logAntioxidantRich:   return DailyQuestScoring.scoreAntioxidantGap(in: recentLogs)
        }
    }
}

/// Per-kind scoring helpers. Pulled into a free namespace so the tests
/// can reach them directly without juggling a synthetic Kind value.
enum DailyQuestScoring {
    static func greenGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let name = log.foodName.lowercased()
            return DailyQuestService.greenKeywords.contains { name.contains($0) }
        }.count
        return max(0.15, 0.9 - Double(count) * 0.25)
    }

    static func proteinGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { ($0.proteinG ?? 0) >= 20 }.count
        return max(0.15, 0.85 - Double(count) * 0.15)
    }

    /// stayUnderGoal doesn't have a clean past-behavior signal; stable
    /// 0.45 keeps it in the rotation tier for users it fits without
    /// dominating.
    static func underGoalGap(in logs: [FoodLog]) -> Double {
        return 0.45
    }

    static func fruitGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let n = log.foodName.lowercased()
            return DailyQuestService.fruitKeywords.contains { n.contains($0) }
        }.count
        return max(0.15, 0.85 - Double(count) * 0.18)
    }

    static func fiberGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { ($0.fiberG ?? 0) >= 5 }.count
        return max(0.15, 0.80 - Double(count) * 0.15)
    }

    static func fermentedGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let n = log.foodName.lowercased()
            return DailyQuestService.fermentedKeywords.contains { n.contains($0) }
        }.count
        return max(0.20, 0.75 - Double(count) * 0.20)
    }

    static func wholeGrainGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let n = log.foodName.lowercased()
            return DailyQuestService.wholeGrainKeywords.contains { n.contains($0) }
        }.count
        return max(0.20, 0.75 - Double(count) * 0.18)
    }

    static func lowSugarGap(in logs: [FoodLog]) -> Double {
        guard !logs.isEmpty else { return 0.40 }
        let avgSugar = logs.reduce(0.0) { $0 + $1.sugarG } / Double(logs.count)
        let normalized = min(1.0, avgSugar / 15.0)
        return max(0.20, min(0.80, 0.20 + normalized * 0.60))
    }

    static func lightMealGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { $0.calories < 500 }.count
        return max(0.20, 0.70 - Double(count) * 0.10)
    }

    static func proteinTotalGap(in logs: [FoodLog]) -> Double {
        guard !logs.isEmpty else { return 0.40 }
        let low = logs.filter { ($0.proteinG ?? 0) < 10 }.count
        let ratio = Double(low) / Double(logs.count)
        return max(0.20, min(0.75, 0.25 + ratio * 0.50))
    }

    // MARK: - Phase 21.12 scorers

    static func scoreTwoVegGap(in logs: [FoodLog]) -> Double {
        let daysWithTwoVeg = logs.reduce(into: [Date: Set<String>]()) { acc, log in
            let day = Calendar.current.startOfDay(for: log.eatenAt)
            let name = log.foodName.lowercased()
            let matches = DailyQuestService.greenKeywords.filter { name.contains($0) }
            acc[day, default: []].formUnion(matches)
        }.values.filter { $0.count >= 2 }.count
        return max(0.15, 0.85 - Double(daysWithTwoVeg) * 0.18)
    }

    // Phase 21.13 — three keyword scorers replacing the dropped
    // `scoreColorfulGap`. The colorful-meal predicate needed
    // ingredient-level parsing the client doesn't have; these
    // three read cleanly off `food_name` substrings instead.

    /// Berries are underconsumed by most people; baseline gap is
    /// generous (0.85) so this quest surfaces even after a few logs.
    static func scoreBerryGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.berryKeywords)
        return max(0.20, 0.85 - Double(count) * 0.20)
    }

    /// Most users hit a hydrating food once a week — moderate
    /// baseline so this doesn't dominate over scarcer nutrients.
    static func scoreHydrationGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.hydrationKeywords)
        return max(0.20, 0.75 - Double(count) * 0.12)
    }

    static func scoreAntioxidantGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.antioxidantKeywords)
        return max(0.20, 0.80 - Double(count) * 0.15)
    }

    static func scoreCruciferGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.cruciferKeywords)
        return max(0.20, 0.80 - Double(count) * 0.20)
    }

    static func scoreLeanProteinGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.leanProteinKeywords)
        return max(0.15, 0.80 - Double(count) * 0.12)
    }

    static func scorePlantProteinGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.plantProteinKeywords)
        return max(0.20, 0.80 - Double(count) * 0.15)
    }

    /// Fatty fish twice a week is the standard recommendation — a
    /// steeper drop per log reflects how few logs make this a non-gap.
    static func scoreFattyFishGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.fattyFishKeywords)
        return max(0.20, 0.85 - Double(count) * 0.30)
    }

    static func scoreHealthyFatGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.healthyFatKeywords)
        return max(0.15, 0.75 - Double(count) * 0.10)
    }

    static func scoreNutsAndSeedsGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.nutsAndSeedsKeywords)
        return max(0.15, 0.70 - Double(count) * 0.10)
    }

    static func scoreHomeCookedGap(in logs: [FoodLog]) -> Double {
        let chainMarkers = DailyQuestService.chainRestaurantMarkers
        let homeCookedLogs = logs.filter { log in
            let name = log.foodName.lowercased()
            return !chainMarkers.contains { name.contains($0) }
        }
        let ratio = logs.isEmpty ? 0.5 : Double(homeCookedLogs.count) / Double(logs.count)
        return max(0.20, min(0.80, 1.0 - ratio))
    }

    static func scoreWholeIngredientGap(in logs: [FoodLog]) -> Double {
        let wholeLogs = logs.filter { log in
            log.foodName.split(separator: " ").count <= 2
        }
        return max(0.20, 0.70 - Double(wholeLogs.count) * 0.10)
    }

    static func scoreEarlyDinnerHealthGap(in logs: [FoodLog]) -> Double {
        let lateDinners = logs.filter { log in
            let hour = Calendar.current.component(.hour, from: log.eatenAt)
            return hour >= 19
        }
        return max(0.20, min(0.80, 0.30 + Double(lateDinners.count) * 0.10))
    }

    static func scoreBalancedMealGap(in logs: [FoodLog]) -> Double {
        let balancedLogs = logs.filter { log in
            let carbs = log.carbsG
            let protein = log.proteinG ?? 0
            let fat = log.fatG ?? 0
            return carbs >= 10 && protein >= 10 && fat >= 10
        }
        return max(0.15, 0.75 - Double(balancedLogs.count) * 0.12)
    }

    static func scoreLowProcessedGap(in logs: [FoodLog]) -> Double {
        let chainMarkers = DailyQuestService.chainRestaurantMarkers
        let processedLogs = logs.filter { log in
            let name = log.foodName.lowercased()
            return chainMarkers.contains { name.contains($0) }
        }
        let ratio = logs.isEmpty ? 0.3 : Double(processedLogs.count) / Double(logs.count)
        return max(0.20, min(0.80, 0.25 + ratio * 0.55))
    }

    static func scoreIronRichGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.ironRichKeywords)
        return max(0.20, 0.75 - Double(count) * 0.12)
    }

    static func scoreCalciumRichGap(in logs: [FoodLog]) -> Double {
        let count = countKeywordLogs(logs, keywords: DailyQuestService.calciumRichKeywords)
        return max(0.20, 0.75 - Double(count) * 0.12)
    }

    private static func countKeywordLogs(_ logs: [FoodLog], keywords: [String]) -> Int {
        return logs.filter { log in
            let name = log.foodName.lowercased()
            return keywords.contains { name.contains($0) }
        }.count
    }
}

struct QuestEvaluation {
    let questCompleted: Bool
    let rewardCopy: String?
}

@MainActor
final class DailyQuestService {
    static let shared = DailyQuestService()

    private let profileService: ProfileService
    private let foodLogService: FoodLogService
    private let mealHistory: MealHistoryService

    init(profileService: ProfileService = ProfileService(),
         foodLogService: FoodLogService = FoodLogService(),
         mealHistory: MealHistoryService = MealHistoryService()) {
        self.profileService = profileService
        self.foodLogService = foodLogService
        self.mealHistory    = mealHistory
    }

    /// Today's quest for the signed-in user. If today already has a
    /// stored quest, returns it (preserving the completion flag); if
    /// not, picks a new kind by goal-filter + gap-score and writes it
    /// back so subsequent fetches stay stable across the day.
    ///
    /// Phase 21.12 — a stored `last_quest_kind` whose raw value no
    /// longer exists in `Kind` (e.g. one of the five kinds dropped in
    /// this phase) is treated as "no stored quest" and a fresh one is
    /// picked, self-healing existing rows.
    func todaysQuest(timeZone: TimeZone = .current) async throws -> DailyQuest {
        let profile = try await profileService.currentProfile()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: Date())

        if let storedDate = profile.lastQuestDate {
            let storedDay = cal.startOfDay(for: storedDate)
            if storedDay == today,
               let kindRaw = profile.lastQuestKind,
               let kind = DailyQuest.Kind.init(rawValue: kindRaw) {
                return DailyQuest(
                    kind: kind,
                    dateLocal: today,
                    completed: profile.lastQuestCompleted
                )
            }
        }

        let allKinds = DailyQuest.Kind.allCases
        let appropriate = allKinds.filter {
            $0.isAppropriate(
                for: profile.onboardingArchetype,
                goal: profile.weightGoalDirection
            )
        }
        let pool = appropriate.isEmpty ? allKinds : appropriate
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: today) ?? 1

        let uuidBytes = profile.id.uuid
        let userOffset = Int(uuidBytes.0)
            &+ Int(uuidBytes.1)
            &+ Int(uuidBytes.2)
            &+ Int(uuidBytes.3)

        let recentLogs: [FoodLog]
        do {
            recentLogs = try await mealHistory.logsInLast7Days(
                now: Date(), timeZone: timeZone
            )
        } catch {
            #if DEBUG
            NSLog("[Quest] recent-logs fetch FAILED, falling back to rotation: %@", "\(error)")
            #endif
            let fallback = pool[(dayOfYear + userOffset) % pool.count]
            _ = try await profileService.updateQuest(
                lastQuestDate:      today,
                lastQuestKind:      fallback.rawValue,
                lastQuestCompleted: false
            )
            return DailyQuest(kind: fallback, dateLocal: today, completed: false)
        }

        let scored: [(kind: DailyQuest.Kind, score: Double)] = pool.map {
            ($0, $0.gapScore(recentLogs: recentLogs))
        }

        let topScore = scored.map(\.score).max() ?? 0
        let topTier = scored.filter { topScore - $0.score < 0.15 }
        let pickedIndex = (dayOfYear + userOffset) % max(topTier.count, 1)
        let kind = topTier[pickedIndex].kind

        #if DEBUG
        NSLog("[Quest] new day pool=%d/%d top-tier=%d picked=%@ (archetype=%@ goal=%@ logs7d=%d userSeed=%d)",
              pool.count, allKinds.count, topTier.count, kind.rawValue,
              profile.onboardingArchetype?.rawValue ?? "<nil>",
              profile.weightGoalDirection?.rawValue ?? "<nil>",
              recentLogs.count, userOffset)
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            NSLog("[Quest]   %@: %.2f", entry.kind.rawValue, entry.score)
        }
        #endif

        _ = try await profileService.updateQuest(
            lastQuestDate:      today,
            lastQuestKind:      kind.rawValue,
            lastQuestCompleted: false
        )

        return DailyQuest(kind: kind, dateLocal: today, completed: false)
    }

    /// Evaluate whether the just-saved meal (combined with today's
    /// other logs) completes the active quest. Idempotent.
    func evaluateQuestProgress(after savedLog: FoodLog,
                               timeZone: TimeZone = .current) async throws -> QuestEvaluation {
        let quest = try await todaysQuest(timeZone: timeZone)
        if quest.completed {
            return QuestEvaluation(questCompleted: true, rewardCopy: nil)
        }

        let todaysLogs = try await foodLogService.todaysLogs(timeZone: timeZone)

        let satisfied = try await predicate(
            for: quest.kind,
            savedLog: savedLog,
            todaysLogs: todaysLogs,
            timeZone: timeZone
        )

        guard satisfied else {
            return QuestEvaluation(questCompleted: false, rewardCopy: nil)
        }

        _ = try await profileService.updateQuest(
            lastQuestDate:      quest.dateLocal,
            lastQuestKind:      quest.kind.rawValue,
            lastQuestCompleted: true
        )

        #if DEBUG
        NSLog("[Quest] completed kind=%@", quest.kind.rawValue)
        #endif

        return QuestEvaluation(
            questCompleted: true,
            rewardCopy: quest.kind.rewardCopy
        )
    }

    // MARK: - Predicates

    private func predicate(for kind: DailyQuest.Kind,
                           savedLog: FoodLog,
                           todaysLogs: [FoodLog],
                           timeZone: TimeZone) async throws -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        switch kind {
        case .logSomethingGreen:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.greenKeywords.contains { name.contains($0) }
            }

        case .logProtein:
            return todaysLogs.contains { ($0.proteinG ?? 0) >= 20 }

        case .stayUnderGoal:
            let hour = cal.component(.hour, from: Date())
            guard hour >= 18 else { return false }
            let profile = try await profileService.currentProfile()
            let goal = Double(profile.dailyCalorieGoal)
            guard goal > 0 else { return false }
            let consumed = todaysLogs.reduce(0.0) { $0 + $1.calories }
            return consumed <= goal

        case .logFruit:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.fruitKeywords.contains { name.contains($0) }
            }

        case .logFiber:
            return todaysLogs.contains { ($0.fiberG ?? 0) >= 5 }

        case .logFermented:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.fermentedKeywords.contains { name.contains($0) }
            }

        case .logWholeGrain:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.wholeGrainKeywords.contains { name.contains($0) }
            }

        case .logLowSugar:
            return todaysLogs.contains { $0.sugarG < 5 }

        case .logLightMeal:
            return todaysLogs.contains { $0.calories < 500 }

        case .hitProteinGoal:
            let total = todaysLogs.reduce(0.0) { $0 + ($1.proteinG ?? 0) }
            let profile = try await profileService.currentProfile()
            let proteinGoal = Double(profile.dailyProteinGoalG)
            guard proteinGoal > 0 else { return false }
            return total >= proteinGoal * 0.8

        // MARK: Phase 21.12

        case .logTwoVegServings:
            let vegMatches = Set(todaysLogs.flatMap { log -> [String] in
                let name = log.foodName.lowercased()
                return Self.greenKeywords.filter { name.contains($0) }
            })
            return vegMatches.count >= 2

        case .logCrucifer:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.cruciferKeywords.contains { name.contains($0) }
            }

        case .logLeanProtein:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.leanProteinKeywords.contains { name.contains($0) }
            }

        case .logPlantProtein:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.plantProteinKeywords.contains { name.contains($0) }
            }

        case .logFattyFish:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.fattyFishKeywords.contains { name.contains($0) }
            }

        case .logHealthyFats:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.healthyFatKeywords.contains { name.contains($0) }
            }

        case .logNutsOrSeeds:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.nutsAndSeedsKeywords.contains { name.contains($0) }
            }

        case .logHomeCooked:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return !Self.chainRestaurantMarkers.contains { name.contains($0) }
            }

        case .logWholeIngredient:
            // Single- or two-word names like "Apple", "Brown Rice",
            // "Greek Yogurt" — a coarse but workable proxy for
            // unprocessed whole foods.
            return todaysLogs.contains { log in
                log.foodName.split(separator: " ").count <= 2
            }

        case .logEarlyDinnerHealth:
            // 5–7 PM local dinner window. Anything 19:00+ doesn't count.
            return todaysLogs.contains { log in
                let hour = cal.component(.hour, from: log.eatenAt)
                return hour >= 17 && hour < 19
            }

        case .logBalancedMeal:
            return todaysLogs.contains { log in
                let carbs = log.carbsG
                let protein = log.proteinG ?? 0
                let fat = log.fatG ?? 0
                return carbs >= 10 && protein >= 10 && fat >= 10
            }

        case .logLowProcessedMeal:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                let words = name.split(separator: " ").count
                let isChain = Self.chainRestaurantMarkers.contains { name.contains($0) }
                return words <= 3 && !isChain
            }

        case .logIronRich:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.ironRichKeywords.contains { name.contains($0) }
            }

        case .logCalciumRich:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.calciumRichKeywords.contains { name.contains($0) }
            }

        // MARK: Phase 21.13

        case .logBerry:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.berryKeywords.contains { name.contains($0) }
            }

        case .logHydrationMeal:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.hydrationKeywords.contains { name.contains($0) }
            }

        case .logAntioxidantRich:
            return todaysLogs.contains { log in
                let name = log.foodName.lowercased()
                return Self.antioxidantKeywords.contains { name.contains($0) }
            }
        }
    }

    // MARK: - Keyword sets (Phase 21.7 / 21.8 / 21.12)
    //
    // Single source shared between completion predicates and the gap
    // scorers (`DailyQuestScoring`) so both surfaces agree on what
    // "counts." Lists are intentionally broad — false positives matter
    // less than false negatives. Unicode-script entries pass through
    // `lowercased()` unchanged (no-op for scripts without case).

    /// Greens / leafy / green-vegetable indicators.
    static let greenKeywords: [String] = [
        "salad", "spinach", "broccoli", "kale", "lettuce", "cucumber",
        "green", "avocado", "asparagus", "celery", "arugula", "zucchini",
        "swiss chard", "collard", "watercress", "endive", "romaine",
        "brussels",
        "bok choy", "pak choi", "napa cabbage", "gai lan", "ong choy",
        "morning glory", "kongnamul", "shigumchi", "miyeok",
        "kimchi", "namul", "minari", "perilla",
        "wakame", "hijiki", "nori", "edamame", "mizuna", "shiso",
        "komatsuna",
        "kangkong", "malunggay", "ampalaya", "pechay", "saluyot",
        "thai basil", "holy basil", "kaffir lime leaf",
        "saag", "palak", "methi", "bitter gourd", "okra", "bhindi",
        "drumstick leaves", "amaranth", "moringa",
        "tabouli", "tabbouleh", "fattoush", "parsley", "molokhia",
        "purslane", "dolma", "vine leaves",
        "nopales", "verdolaga", "huauzontle", "quelites",
        "callaloo", "cassava leaves", "ewedu",
        "김치", "시금치", "상추", "오이", "콩나물", "미역", "깻잎",
        "ほうれん草", "キャベツ", "わかめ", "海苔", "枝豆",
        "青菜", "白菜", "菠菜",
        "पालक", "साग", "भिंडी",
        "خس", "خيار", "ملوخية"
    ]

    /// Fruit indicators.
    static let fruitKeywords: [String] = [
        "apple", "banana", "berry", "berries", "mango", "orange",
        "grape", "pear", "peach", "plum", "watermelon", "kiwi",
        "pineapple", "strawberr", "blueberr", "raspberr", "cherry",
        "papaya", "melon", "cantaloupe", "honeydew", "apricot",
        "pomegranate", "fig", "date", "passion fruit",
        "durian", "rambutan", "longan", "lychee", "mangosteen",
        "jackfruit", "salak", "guava", "dragon fruit", "soursop",
        "starfruit", "carambola", "santol", "duhat", "lanzones",
        "atis", "guyabano",
        "chikoo", "sapota", "jamun", "amla", "ber", "custard apple",
        "wood apple", "bael",
        "persimmon", "nashi pear", "asian pear", "loquat", "kumquat",
        "yuzu", "ume",
        "guanabana", "lulo", "naranjilla", "cherimoya",
        "sapote", "tamarind", "ackee", "passionfruit",
        "사과", "바나나", "딸기", "포도", "수박", "복숭아", "감",
        "りんご", "バナナ", "いちご", "みかん", "桃",
        "苹果", "香蕉", "葡萄", "草莓",
        "सेब", "केला", "आम", "अमरूद",
        "تفاح", "موز", "عنب", "بطيخ"
    ]

    /// Fermented-food indicators.
    static let fermentedKeywords: [String] = [
        "kimchi", "miso", "natto", "tempeh", "doenjang", "gochujang",
        "soy sauce", "fish sauce", "shoyu", "shio koji",
        "yogurt", "kefir", "lassi", "ayran", "labneh", "cheese",
        "skyr", "quark",
        "sauerkraut", "pickle", "pickled", "kraut", "achaar",
        "atchara", "tsukemono", "dill pickle",
        "kombucha", "kvass", "kefir water",
        "sourdough", "injera", "dosa", "idli",
        "ogi", "garri", "tepache", "pulque", "chicha",
        "김치", "된장", "고추장", "장아찌",
        "味噌", "納豆", "醤油", "漬物",
        "酱油", "豆瓣酱", "豆腐乳",
        "दही", "अचार",
        "لبن", "زبادي"
    ]

    /// Whole-grain indicators.
    static let wholeGrainKeywords: [String] = [
        "oat", "oatmeal", "porridge", "muesli", "granola",
        "brown rice", "quinoa", "whole wheat", "whole grain",
        "barley", "buckwheat", "millet", "bulgur", "farro",
        "spelt", "rye", "kamut", "teff",
        "purple rice", "black rice", "japchaebap",
        "boribap", "ogokbap",
        "genmai",
        "ragi", "bajra", "jowar", "whole wheat roti", "atta",
        "dalia",
        "fonio", "sorghum",
        "masa harina", "blue corn",
        "현미", "보리밥", "잡곡밥", "오곡밥",
        "玄米", "雑穀",
        "糙米", "燕麦", "藜麦",
        "जौ", "बाजरा", "जोवार"
    ]

    // MARK: - Phase 21.12 keyword sets

    static let cruciferKeywords: [String] = [
        "broccoli", "cauliflower", "kale", "brussels sprout", "cabbage",
        "bok choy", "pak choi", "arugula", "watercress", "radish", "turnip"
    ]

    static let leanProteinKeywords: [String] = [
        "chicken breast", "chicken", "turkey", "fish", "salmon", "tuna",
        "cod", "halibut", "tofu", "egg white", "lean beef", "sirloin",
        "tilapia", "shrimp", "trout"
    ]

    static let plantProteinKeywords: [String] = [
        "lentil", "bean", "chickpea", "garbanzo", "tofu", "tempeh",
        "edamame", "soy", "seitan", "black bean", "kidney bean",
        "pinto bean", "navy bean", "hummus", "falafel"
    ]

    static let fattyFishKeywords: [String] = [
        "salmon", "mackerel", "sardine", "tuna", "trout", "herring",
        "anchovy", "fresh tuna"
    ]

    static let healthyFatKeywords: [String] = [
        "avocado", "olive oil", "almond", "walnut", "pecan", "cashew",
        "pistachio", "hazelnut", "macadamia", "peanut", "nut butter",
        "chia", "flax", "hemp seed", "pumpkin seed", "sunflower seed",
        "sesame", "tahini", "guacamole"
    ]

    static let nutsAndSeedsKeywords: [String] = [
        "almond", "walnut", "pecan", "cashew", "pistachio", "hazelnut",
        "macadamia", "peanut", "trail mix", "granola", "chia",
        "flax", "hemp seed", "pumpkin seed", "sunflower seed",
        "sesame", "nut butter", "almond butter", "peanut butter"
    ]

    static let ironRichKeywords: [String] = [
        "spinach", "lentil", "red meat", "beef", "liver", "kale",
        "swiss chard", "tofu", "chickpea", "pumpkin seed", "quinoa",
        "dark chocolate", "molasses", "fortified cereal", "oyster"
    ]

    static let calciumRichKeywords: [String] = [
        "milk", "yogurt", "cheese", "tofu", "sardine", "kale",
        "broccoli", "almond", "fortified", "collard", "bok choy",
        "edamame", "fig"
    ]

    // MARK: - Phase 21.13 keyword sets
    //
    // Replace `colorKeywords` (the dropped colorful-meal predicate
    // needed ingredient-level parsing the client doesn't have) with
    // three single-substring lists covering berries, hydrating
    // foods, and high-antioxidant foods. Overlap between
    // berries / antioxidants and between greens / antioxidants is
    // intentional — the scorers are designed for it.

    static let berryKeywords: [String] = [
        "strawberr", "blueberr", "raspberr", "blackberr",
        "cranberr", "boysenberr", "elderberr", "gooseberr",
        "mulberr", "lingonberr",
        "açaí", "acai", "goji",
        "berry", "berries",
        // Unicode variants
        "딸기",       // strawberry (Korean)
        "블루베리",   // blueberry (Korean)
        "苺",        // strawberry (Japanese)
        "ブルーベリー" // blueberry (Japanese katakana)
    ]

    static let hydrationKeywords: [String] = [
        // High water-content fruits & vegetables
        "watermelon", "cantaloupe", "honeydew", "melon",
        "cucumber", "celery", "lettuce", "tomato",
        "strawberr", "orange", "grapefruit",
        // Liquid-based dishes
        "soup", "broth", "stew", "stock", "consomme",
        "gazpacho", "minestrone", "miso soup",
        "수프", "국", "찌개",   // Korean: soup, broth-soup, stew
        "汁", "スープ",         // Japanese: soup
        // Salads
        "salad", "garden salad", "side salad",
        "샐러드",
        // Smoothies / hydrating drinks
        "smoothie", "juice", "fresh juice",
        "coconut water", "herbal tea", "iced tea",
        "infused water"
    ]

    static let antioxidantKeywords: [String] = [
        // Berries (intentional overlap with berryKeywords)
        "strawberr", "blueberr", "raspberr", "blackberr",
        "açaí", "acai", "goji", "elderberr",
        // Dark chocolate / cocoa
        "dark chocolate", "cocoa", "cacao",
        "70% chocolate", "80% chocolate", "85% chocolate",
        // Green / white tea
        "green tea", "matcha", "white tea", "sencha",
        "녹차", "緑茶", "抹茶",
        // Dark leafy greens (intentional overlap with greenKeywords)
        "spinach", "kale", "swiss chard", "collard",
        "arugula", "watercress",
        "시금치", "ほうれん草",
        // Other high-ORAC foods
        "pecan", "walnut", "artichoke", "red cabbage",
        "purple cabbage", "purple potato", "beet",
        "pomegranate", "concord grape",
        // Spices with strong antioxidant content
        "turmeric", "cinnamon", "clove", "oregano"
    ]

    /// Substring markers for major fast-food / chain restaurant brands,
    /// used by `logHomeCooked` and `logLowProcessedMeal`. The list is
    /// intentionally short — false positives ("starbucks coffee" at
    /// home is still a brand log) matter less than over-blocking
    /// legitimate home-cooked entries.
    static let chainRestaurantMarkers: [String] = [
        "mcdonald", "burger king", "kfc", "subway", "starbucks",
        "domino", "pizza hut", "taco bell", "wendy", "chipotle",
        "panera", "dunkin", "popeye", "five guy", "chick-fil-a",
        "carl jr", "in-n-out", "shake shack"
    ]
}
