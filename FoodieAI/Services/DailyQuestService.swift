import Foundation

/// Phase 21 — one playful prompt per day that the user can complete by
/// logging meals. The reward is a small celebratory copy when next
/// visiting Today, not a streak multiplier or points — quests are
/// retention engagement, not gamification scoring.
///
/// Quest selection is deterministic from the user's local day-of-year:
/// within a day the quest never changes (no refresh-roulette), and
/// across days the kind rotates evenly through `Kind.allCases`. This
/// keeps the experience honest — the user can plan around today's
/// prompt without the app trying to surprise-bait them.
struct DailyQuest: Hashable, Codable {
    enum Kind: String, Codable, CaseIterable {
        // Phase 21 — core six.
        case logSomethingGreen
        case logBeforeTime
        case logThreeMeals
        case tryNewFood
        case logProtein
        case stayUnderGoal

        // Phase 21.7 — nutrition expansion.
        case logFruit
        case logFiber          // ≥5g fiber in one meal
        case logFermented      // kimchi, yogurt, kombucha, miso, sauerkraut, etc.
        case logWholeGrain     // oats, brown rice, quinoa, whole wheat, etc.
        case logLowSugar       // a meal with <5g sugar
        case logLightMeal      // a meal under 500 cal
        // Phase 21.7 — timing.
        case logDinnerEarly    // dinner before 8 PM
        // Phase 21.7 — variety.
        case logNewCuisine     // food in a cuisine the user hasn't logged recently
        // Phase 21.7 — goal-specific.
        case hitProteinGoal    // total daily protein ≥ 80% of profile.dailyProteinGoalG

        /// The user-facing prompt copy on the Today card.
        var copy: String {
            switch self {
            case .logSomethingGreen: "Log something green today 🌿"
            case .logBeforeTime:     "Log breakfast before 10 AM ☀️"
            case .logThreeMeals:     "Log 3 meals today"
            case .tryNewFood:        "Try something new — log a food you haven't yet"
            case .logProtein:        "Find some protein — log a meal with 20g+"
            case .stayUnderGoal:     "Stay within your calorie goal today"
            case .logFruit:          "Log a fruit today 🍎"
            case .logFiber:          "Find some fiber — log a meal with 5g+ 🌾"
            case .logFermented:      "Log something fermented (kimchi, yogurt, miso) 🥬"
            case .logWholeGrain:     "Log a whole grain (oats, brown rice, quinoa) 🌾"
            case .logLowSugar:       "Log a meal under 5g of sugar 🍃"
            case .logLightMeal:      "Log a meal under 500 calories ☁️"
            case .logDinnerEarly:    "Log dinner before 8 PM 🌅"
            case .logNewCuisine:     "Log something from a cuisine you don't usually try ✨"
            case .hitProteinGoal:    "Hit your protein goal today 💪"
            }
        }

        /// Reward copy when the quest just completed — surfaces in the
        /// success toast and on the Today card after completion.
        var rewardCopy: String {
            switch self {
            case .logSomethingGreen: "🌿 Quest complete — leafy points!"
            case .logBeforeTime:     "☀️ Early bird — quest complete"
            case .logThreeMeals:     "🍽 Triple-logged the day"
            case .tryNewFood:        "✨ Trying new things — nice"
            case .logProtein:        "💪 Protein found"
            case .stayUnderGoal:     "🎯 Hit your goal"
            case .logFruit:          "🍎 Fruit logged — small win"
            case .logFiber:          "🌾 Fiber found — gut happy"
            case .logFermented:      "🥬 Fermented power — quest done"
            case .logWholeGrain:     "🌾 Whole grain — slow energy"
            case .logLowSugar:       "🍃 Light on sugar — quest done"
            case .logLightMeal:      "☁️ Light meal — balanced"
            case .logDinnerEarly:    "🌅 Early dinner — quest complete"
            case .logNewCuisine:     "✨ New cuisine — variety found"
            case .hitProteinGoal:    "💪 Protein goal — nailed it"
            }
        }
    }

    let kind: Kind
    let dateLocal: Date
    let completed: Bool
}

// MARK: - Goal alignment (Phase 21.5)

extension DailyQuest.Kind {
    /// Whether this quest fits a user with the given archetype + goal.
    /// `nil` archetype → user skipped onboarding goal-framing → fall
    /// back to `.aware` (the everyone-appropriate bucket). `nil` goal
    /// direction → user hasn't set physiology → fall back to
    /// `.maintain`.
    ///
    /// The mapping isn't a perfect nutrition model — six categorical
    /// buckets can't express the full space — but it's directionally
    /// honest: a `loseWeight` user shouldn't be coached to eat three
    /// meals; a `buildMuscle` user shouldn't be coached to stay under
    /// their calorie goal.
    func isAppropriate(for archetype: Profile.Archetype?,
                       goal: CalorieGoalCalculator.GoalDirection?) -> Bool {
        let effectiveArchetype = archetype ?? .aware
        let effectiveGoal = goal ?? .maintain

        switch self {
        case .logSomethingGreen:
            return true
        case .logBeforeTime:
            return true
        case .logThreeMeals:
            // Lose-weight users may intentionally skip a meal (16:8
            // intermittent fasting is common); don't nag them to log
            // three.
            return effectiveGoal != .lose
        case .tryNewFood:
            return true
        case .logProtein:
            // Protein is goal-relevant for both directions: gain to
            // build, lose to preserve muscle in deficit. Maintain users
            // see it less often (still in pool, but the build/lose
            // bucket gets priority via the architype check).
            return effectiveArchetype == .buildMuscle
                || effectiveGoal == .gain
                || effectiveGoal == .lose
        case .stayUnderGoal:
            // Only fits users actively in a deficit, or maintain users
            // whose archetype is the awareness framing.
            return effectiveGoal == .lose
                || (effectiveGoal == .maintain && effectiveArchetype == .aware)

        // MARK: Phase 21.7

        case .logFruit, .logFiber, .logFermented,
             .logWholeGrain, .logNewCuisine, .logDinnerEarly:
            // Universal — nutrition basics and timing apply to every
            // goal direction.
            return true

        case .logLowSugar:
            // Skip for users in a surplus / muscle-building flow —
            // they may rely on intra-/post-workout carbs that push
            // sugar above 5g per meal.
            return effectiveGoal == .lose
                || effectiveGoal == .maintain
                || effectiveArchetype == .aware
                || effectiveArchetype == .loseWeight

        case .logLightMeal:
            // Skip for users explicitly trying to gain — they need
            // calorie-dense meals.
            return effectiveGoal != .gain

        case .hitProteinGoal:
            // Universal — every archetype has a protein goal and
            // hitting it is broadly useful. Goal-relevance is already
            // expressed via the user's `dailyProteinGoalG` value.
            return true
        }
    }
}

// MARK: - Gap scoring (Phase 21.6)

extension DailyQuest.Kind {
    /// Phase 21.6 — score 0.0–1.0 of how relevant this quest is to the
    /// user's recent behavior. Higher score = bigger gap = more
    /// relevant.
    ///
    /// The goal-alignment filter (Phase 21.5) runs first; this score
    /// then ranks what remains. The pair lets us pick a quest that's
    /// (a) appropriate for the user's goal and (b) targeting an actual
    /// gap rather than rotating mechanically.
    ///
    /// Scores are floored at 0.15 — no quest is ever fully extinct
    /// from the pool. They're capped at the head value (e.g. 0.85,
    /// 0.9) so a single gap can't dominate forever; the rotation
    /// tie-break in `todaysQuest` then alternates between same-tier
    /// quests across days.
    func gapScore(recentLogs: [FoodLog]) -> Double {
        switch self {
        case .logSomethingGreen: return DailyQuestScoring.greenGap(in: recentLogs)
        case .logBeforeTime:     return DailyQuestScoring.breakfastGap(in: recentLogs)
        case .logThreeMeals:     return DailyQuestScoring.threeMealsGap(in: recentLogs)
        case .tryNewFood:        return DailyQuestScoring.varietyGap(in: recentLogs)
        case .logProtein:        return DailyQuestScoring.proteinGap(in: recentLogs)
        case .stayUnderGoal:     return DailyQuestScoring.underGoalGap(in: recentLogs)
        // Phase 21.7
        case .logFruit:          return DailyQuestScoring.fruitGap(in: recentLogs)
        case .logFiber:          return DailyQuestScoring.fiberGap(in: recentLogs)
        case .logFermented:      return DailyQuestScoring.fermentedGap(in: recentLogs)
        case .logWholeGrain:     return DailyQuestScoring.wholeGrainGap(in: recentLogs)
        case .logLowSugar:       return DailyQuestScoring.lowSugarGap(in: recentLogs)
        case .logLightMeal:      return DailyQuestScoring.lightMealGap(in: recentLogs)
        case .logDinnerEarly:    return DailyQuestScoring.earlyDinnerGap(in: recentLogs)
        case .logNewCuisine:     return DailyQuestScoring.cuisineVarietyGap(in: recentLogs)
        case .hitProteinGoal:    return DailyQuestScoring.proteinTotalGap(in: recentLogs)
        }
    }
}

/// Per-kind scoring helpers. Pulled into a free namespace (rather
/// than methods on the extension above) so the tests can reach them
/// directly without juggling a synthetic Kind value, and so the
/// scoring logic is unit-testable in isolation from the persistence
/// path.
enum DailyQuestScoring {
    /// 0 green logs / 7 days → 0.9. 3+ → floors near 0.15.
    /// Score drops 0.25 per green log so the gradient is steep.
    /// Keyword set lives on `DailyQuestService` (Phase 21.8) so the
    /// completion predicate and the gap scorer share one source.
    static func greenGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let name = log.foodName.lowercased()
            return DailyQuestService.greenKeywords.contains { name.contains($0) }
        }.count
        return max(0.15, 0.9 - Double(count) * 0.25)
    }

    /// 0 logs in the 04:00–10:00 local window → 0.85.
    /// 5+ early logs → floors at 0.15. 0.15 per early log.
    /// Hour computed in `Calendar.current` (user's local zone).
    static func breakfastGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let h = Calendar.current.component(.hour, from: log.eatenAt)
            return h >= 4 && h < 10
        }.count
        return max(0.15, 0.85 - Double(count) * 0.15)
    }

    /// Days in last 7 where the user logged fewer than 3 meals
    /// (including zero-log days). 5+ such days → 0.85.
    /// 0 → 0.15. The denominator is hard-coded to 7 so the score
    /// reflects "% of last week missed," not "% of active days."
    static func threeMealsGap(in logs: [FoodLog]) -> Double {
        let cal = Calendar.current
        let logsByDay = Dictionary(grouping: logs) { log in
            cal.startOfDay(for: log.eatenAt)
        }
        let underThreeActiveDays = logsByDay.values.filter { $0.count < 3 }.count
        // Days the user didn't log at all aren't in `logsByDay`; treat
        // them as "under three" too.
        let activeDays = min(logsByDay.count, 7)
        let zeroDays = max(0, 7 - activeDays)
        let totalGapDays = min(7, underThreeActiveDays + zeroDays)
        return max(0.15, min(0.85, Double(totalGapDays) / 7.0 + 0.15))
    }

    /// Low unique/total ratio → high gap.
    /// `unique == total` (all distinct) → 0.15.
    /// `unique == 1` over 10 logs → near 0.85.
    /// Fewer than 4 logs returns the neutral mid 0.5 — "you only
    /// logged twice last week" isn't a variety problem.
    static func varietyGap(in logs: [FoodLog]) -> Double {
        guard logs.count >= 4 else { return 0.5 }
        let unique = Set(logs.map { $0.foodName.lowercased() }).count
        let ratio = Double(unique) / Double(logs.count)
        return max(0.15, min(0.85, 1.0 - ratio))
    }

    /// 0 high-protein meals (≥20g) → 0.85.
    /// 5+ → floors at 0.15. Logs with nil `proteinG` count as 0
    /// (legacy rows from analyzed flows that didn't capture protein).
    static func proteinGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { ($0.proteinG ?? 0) >= 20 }.count
        return max(0.15, 0.85 - Double(count) * 0.15)
    }

    /// stayUnderGoal doesn't have a clean past-behavior signal — we'd
    /// need historical daily calorie sums vs. the (mutable) goal at
    /// each point in time, which is per-day work outside this phase.
    /// Return a stable 0.45 so this quest still appears via the
    /// rotation tie-break for users it's appropriate for (lose +
    /// maintain/aware), without dominating the top tier.
    static func underGoalGap(in logs: [FoodLog]) -> Double {
        return 0.45
    }

    // MARK: - Phase 21.7 — expanded scorers

    /// 0 fruit logs / 7 days → 0.85. 4+ → near 0.15.
    /// Same keyword set as the completion predicate.
    static func fruitGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let n = log.foodName.lowercased()
            return DailyQuestService.fruitKeywords.contains { n.contains($0) }
        }.count
        return max(0.15, 0.85 - Double(count) * 0.18)
    }

    /// 0 high-fiber meals (≥5g) → 0.80. 5+ → floors at 0.15.
    static func fiberGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { ($0.fiberG ?? 0) >= 5 }.count
        return max(0.15, 0.80 - Double(count) * 0.15)
    }

    /// 0 fermented logs / 7 days → 0.75. 3+ → floors at 0.20.
    /// Fermented foods are less universally consumed, so the head
    /// value is a bit lower than fruit/green — we don't want this
    /// quest to dominate for users who just don't eat fermented.
    static func fermentedGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let n = log.foodName.lowercased()
            return DailyQuestService.fermentedKeywords.contains { n.contains($0) }
        }.count
        return max(0.20, 0.75 - Double(count) * 0.20)
    }

    /// 0 whole-grain logs / 7 days → 0.75. 4+ → floors at 0.20.
    static func wholeGrainGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let n = log.foodName.lowercased()
            return DailyQuestService.wholeGrainKeywords.contains { n.contains($0) }
        }.count
        return max(0.20, 0.75 - Double(count) * 0.18)
    }

    /// High score if the user's average sugar per meal has been
    /// trending high. 15g+ avg → 0.80. <5g avg → near 0.20. Returns
    /// 0.40 with no logs (neutral, no signal).
    static func lowSugarGap(in logs: [FoodLog]) -> Double {
        guard !logs.isEmpty else { return 0.40 }
        let avgSugar = logs.reduce(0.0) { $0 + $1.sugarG } / Double(logs.count)
        let normalized = min(1.0, avgSugar / 15.0)
        return max(0.20, min(0.80, 0.20 + normalized * 0.60))
    }

    /// 0 light meals (<500 cal) / 7 days → 0.70. 5+ → floors at 0.20.
    static func lightMealGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { $0.calories < 500 }.count
        return max(0.20, 0.70 - Double(count) * 0.10)
    }

    /// High score if the user has been eating dinner late (≥20:00).
    /// 0 late dinners → 0.30. 5+ → 0.80.
    static func earlyDinnerGap(in logs: [FoodLog]) -> Double {
        let count = logs.filter { log in
            let h = Calendar.current.component(.hour, from: log.eatenAt)
            return h >= 20
        }.count
        return max(0.20, min(0.80, 0.30 + Double(count) * 0.10))
    }

    /// Low cuisine variety → high gap. 1–2 distinct cuisines logged
    /// → 0.70. 3–4 → 0.35. 5+ → floors at 0.15. Uses the same
    /// cuisine-marker list as the completion predicate.
    static func cuisineVarietyGap(in logs: [FoodLog]) -> Double {
        let distinct = Set(DailyQuestService.cuisineKeywords.filter { marker in
            logs.contains { $0.foodName.lowercased().contains(marker) }
        }).count
        if distinct >= 5 { return 0.15 }
        if distinct >= 3 { return 0.35 }
        return 0.70
    }

    /// Proxy: ratio of low-protein meals (<10g) in the last 7 days.
    /// Higher ratio → higher gap. Without per-day historical totals
    /// vs. goal, this is the cleanest signal available.
    static func proteinTotalGap(in logs: [FoodLog]) -> Double {
        guard !logs.isEmpty else { return 0.40 }
        let low = logs.filter { ($0.proteinG ?? 0) < 10 }.count
        let ratio = Double(low) / Double(logs.count)
        return max(0.20, min(0.75, 0.25 + ratio * 0.50))
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
    /// not, picks a new kind deterministically from the local
    /// day-of-year and writes it back so subsequent fetches stay
    /// stable across the day.
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

        // Phase 21.5 — filter the pool to quests appropriate for the
        // user's archetype + goal direction before picking. Both are
        // optional; the predicate handles `nil` by falling back to
        // the everyone-appropriate `.aware` / `.maintain` bucket.
        let allKinds = DailyQuest.Kind.allCases
        let appropriate = allKinds.filter {
            $0.isAppropriate(
                for: profile.onboardingArchetype,
                goal: profile.weightGoalDirection
            )
        }
        // Defensive fallback: if a future change accidentally excludes
        // everything for some archetype/goal combination, surface a
        // quest anyway rather than rendering a blank Today card.
        let pool = appropriate.isEmpty ? allKinds : appropriate
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: today) ?? 1

        // Phase 21.6 fix — per-user rotation offset. Without this, two
        // accounts with the same archetype/goal and similar recent
        // behavior produced the same top-tier and the same
        // `dayOfYear % topTier.count` index, so they saw the same
        // quest every day. Sum the first four UUID bytes for a stable
        // per-user integer; `&+` is defensive wrap-around (UInt8 sums
        // fit Int easily, but wrap-add silences any future change to
        // the bit width).
        let uuidBytes = profile.id.uuid
        let userOffset = Int(uuidBytes.0)
            &+ Int(uuidBytes.1)
            &+ Int(uuidBytes.2)
            &+ Int(uuidBytes.3)

        // Phase 21.6 — fetch the user's last 7 days of logs to score
        // each appropriate quest against actual behavior. If the fetch
        // fails, degrade gracefully to the Phase 21.5 day-of-year
        // rotation rather than blocking quest selection on a
        // network round-trip.
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

        // Score every appropriate kind against the user's recent
        // behavior. Higher score = bigger gap.
        let scored: [(kind: DailyQuest.Kind, score: Double)] = pool.map {
            ($0, $0.gapScore(recentLogs: recentLogs))
        }

        // Tie-break: within 0.15 of the top score is "equally
        // relevant"; rotate among that tier by day-of-year so a user
        // with two strong gaps doesn't see the same quest forever.
        // Threshold rationale: tighter (0.05) and rotation almost
        // never kicks in (only true ties qualify); looser (0.30) and
        // rotation fires across not-really-comparable quests. 0.15
        // matches the floor delta in the scoring helpers — anything
        // closer than that is within "noise" of the gradient.
        let topScore = scored.map(\.score).max() ?? 0
        let topTier = scored.filter { topScore - $0.score < 0.15 }
        // `topTier` is guaranteed non-empty whenever `pool` is, since
        // the max always belongs to itself.
        //
        // Phase 21.6 fix — fold `userOffset` into the rotation index
        // so two users with the same top-tier on the same day land on
        // different quests. Both inputs are non-negative, so `%` is
        // non-negative and a safe array index.
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
    /// other logs) completes the active quest. Idempotent —
    /// completing an already-completed quest is a no-op. Returns the
    /// reward copy for the UI to surface in the success toast.
    func evaluateQuestProgress(after savedLog: FoodLog,
                               timeZone: TimeZone = .current) async throws -> QuestEvaluation {
        let quest = try await todaysQuest(timeZone: timeZone)
        if quest.completed {
            // Already complete — return the reward copy as `nil` so the
            // UI doesn't re-celebrate.
            return QuestEvaluation(questCompleted: true, rewardCopy: nil)
        }

        // Pull today's logs (which already includes `savedLog`) and run
        // the predicate. RLS scopes by user, so a single
        // `todaysLogs(timeZone:)` is enough.
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

        case .logBeforeTime:
            // Any of today's logs eaten before 10:00 local time.
            return todaysLogs.contains { log in
                let hour = cal.component(.hour, from: log.eatenAt)
                return hour < 10
            }

        case .logThreeMeals:
            return todaysLogs.count >= 3

        case .tryNewFood:
            // The just-saved log's food name must not appear in any
            // older log. Use `priorOccurrences` for case-insensitive
            // matching, then exclude the just-saved row.
            let prior = try await mealHistory.priorOccurrences(
                of: savedLog.foodName,
                excluding: savedLog.id
            )
            return prior.isEmpty

        case .logProtein:
            return todaysLogs.contains { ($0.proteinG ?? 0) >= 20 }

        case .stayUnderGoal:
            // Approximation: only mark complete if it's after 18:00 AND
            // the day's calorie sum is still under the user's goal.
            // True end-of-day evaluation is a future phase.
            let hour = cal.component(.hour, from: Date())
            guard hour >= 18 else { return false }
            let profile = try await profileService.currentProfile()
            let goal = Double(profile.dailyCalorieGoal)
            guard goal > 0 else { return false }
            let consumed = todaysLogs.reduce(0.0) { $0 + $1.calories }
            return consumed <= goal

        // MARK: Phase 21.7 — nutrition

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
            // sugar_g is non-optional in the schema; check raw value.
            return todaysLogs.contains { $0.sugarG < 5 }

        case .logLightMeal:
            return todaysLogs.contains { $0.calories < 500 }

        // MARK: Phase 21.7 — timing

        case .logDinnerEarly:
            // Dinner window 17:00–19:59 local. A 20:00 log is "late
            // dinner" by this quest's rule.
            return todaysLogs.contains { log in
                let h = cal.component(.hour, from: log.eatenAt)
                return h >= 17 && h < 20
            }

        // MARK: Phase 21.7 — variety

        case .logNewCuisine:
            // v1 heuristic: today's logs include a cuisine marker that
            // doesn't appear anywhere in the user's last-7-days history.
            // The wider "30-day cuisine bottom-3" framing is a future
            // refinement; the 7-day window is enough signal for a
            // single-day quest, and we already use it for gap scoring.
            let recent = (try? await mealHistory.logsInLast7Days(
                now: Date(), timeZone: timeZone
            )) ?? []
            let recentNames = recent.map { $0.foodName.lowercased() }
            let knownCuisines = Set(Self.cuisineKeywords.filter { marker in
                recentNames.contains { $0.contains(marker) }
            })
            let todaysCuisines = Set(Self.cuisineKeywords.filter { marker in
                todaysLogs.contains { $0.foodName.lowercased().contains(marker) }
            })
            return !todaysCuisines.subtracting(knownCuisines).isEmpty

        // MARK: Phase 21.7 — goal-specific

        case .hitProteinGoal:
            // ≥80% of the user's per-day protein goal. Goal is required
            // (no fallback) — without it the quest can't meaningfully
            // complete.
            let total = todaysLogs.reduce(0.0) { $0 + ($1.proteinG ?? 0) }
            let profile = try await profileService.currentProfile()
            let proteinGoal = Double(profile.dailyProteinGoalG)
            guard proteinGoal > 0 else { return false }
            return total >= proteinGoal * 0.8
        }
    }

    // MARK: - Keyword sets (Phase 21.7 / 21.8)
    //
    // Single source shared between completion predicates and the gap
    // scorers (`DailyQuestScoring`) so both surfaces agree on what
    // "counts." Each list is intentionally broad — false positives
    // (e.g. "rye whiskey" matches "rye") matter less than false
    // negatives (a user's "garlic fried brown rice" failing to match
    // as a whole grain).
    //
    // Phase 21.8 expansions:
    //   • Regional variants for major world cuisines.
    //   • Native-script terms (Hangul, JP kana/kanji, Simplified
    //     Chinese, Devanagari, Arabic). Swift's `String.contains`
    //     works on Unicode scalars; `lowercased()` is a no-op for
    //     scripts without case, so these pass through unchanged.

    /// Greens / leafy / green-vegetable indicators.
    static let greenKeywords: [String] = [
        // Western leafy / green
        "salad", "spinach", "broccoli", "kale", "lettuce", "cucumber",
        "green", "avocado", "asparagus", "celery", "arugula", "zucchini",
        "swiss chard", "collard", "watercress", "endive", "romaine",
        "brussels",
        // East Asian greens
        "bok choy", "pak choi", "napa cabbage", "gai lan", "ong choy",
        "morning glory", "kongnamul", "shigumchi", "miyeok",
        // Korean
        "kimchi", "namul", "minari", "perilla",
        // Japanese
        "wakame", "hijiki", "nori", "edamame", "mizuna", "shiso",
        "komatsuna",
        // Southeast Asian
        "kangkong", "malunggay", "ampalaya", "pechay", "saluyot",
        "thai basil", "holy basil", "kaffir lime leaf",
        // South Asian
        "saag", "palak", "methi", "bitter gourd", "okra", "bhindi",
        "drumstick leaves", "amaranth", "moringa",
        // Middle Eastern / Mediterranean
        "tabouli", "tabbouleh", "fattoush", "parsley", "molokhia",
        "purslane", "dolma", "vine leaves",
        // Latin American
        "nopales", "verdolaga", "huauzontle", "quelites",
        // African
        "callaloo", "cassava leaves", "ewedu",
        // Unicode (Hangul / JP / CN / Devanagari / Arabic)
        "김치", "시금치", "상추", "오이", "콩나물", "미역", "깻잎",
        "ほうれん草", "キャベツ", "わかめ", "海苔", "枝豆",
        "青菜", "白菜", "菠菜",
        "पालक", "साग", "भिंडी",
        "خس", "خيار", "ملوخية"
    ]

    /// Fruit indicators.
    static let fruitKeywords: [String] = [
        // Common Western
        "apple", "banana", "berry", "berries", "mango", "orange",
        "grape", "pear", "peach", "plum", "watermelon", "kiwi",
        "pineapple", "strawberr", "blueberr", "raspberr", "cherry",
        "papaya", "melon", "cantaloupe", "honeydew", "apricot",
        "pomegranate", "fig", "date", "passion fruit",
        // Tropical / Southeast Asian
        "durian", "rambutan", "longan", "lychee", "mangosteen",
        "jackfruit", "salak", "guava", "dragon fruit", "soursop",
        "starfruit", "carambola", "santol", "duhat", "lanzones",
        "atis", "guyabano",
        // South Asian
        "chikoo", "sapota", "jamun", "amla", "ber", "custard apple",
        "wood apple", "bael",
        // East Asian
        "persimmon", "nashi pear", "asian pear", "loquat", "kumquat",
        "yuzu", "ume",
        // Latin American / Caribbean
        "guanabana", "lulo", "naranjilla", "cherimoya",
        "sapote", "tamarind", "ackee", "passionfruit",
        // Unicode
        "사과", "바나나", "딸기", "포도", "수박", "복숭아", "감",
        "りんご", "バナナ", "いちご", "みかん", "桃",
        "苹果", "香蕉", "葡萄", "草莓",
        "सेब", "केला", "आम", "अमरूद",
        "تفاح", "موز", "عنب", "بطيخ"
    ]

    /// Fermented-food indicators.
    static let fermentedKeywords: [String] = [
        // East Asian
        "kimchi", "miso", "natto", "tempeh", "doenjang", "gochujang",
        "soy sauce", "fish sauce", "shoyu", "shio koji",
        // Dairy-based
        "yogurt", "kefir", "lassi", "ayran", "labneh", "cheese",
        "skyr", "quark",
        // Vegetable-based
        "sauerkraut", "pickle", "pickled", "kraut", "achaar",
        "atchara", "tsukemono", "dill pickle",
        // Drinks
        "kombucha", "kvass", "kefir water",
        // Bread / grain
        "sourdough", "injera", "dosa", "idli",
        // Latin American / African
        "ogi", "garri", "tepache", "pulque", "chicha",
        // Unicode
        "김치", "된장", "고추장", "장아찌",
        "味噌", "納豆", "醤油", "漬物",
        "酱油", "豆瓣酱", "豆腐乳",
        "दही", "अचार",
        "لبن", "زبادي"
    ]

    /// Whole-grain indicators.
    static let wholeGrainKeywords: [String] = [
        // Western whole grains
        "oat", "oatmeal", "porridge", "muesli", "granola",
        "brown rice", "quinoa", "whole wheat", "whole grain",
        "barley", "buckwheat", "millet", "bulgur", "farro",
        "spelt", "rye", "kamut", "teff",
        // East Asian whole grains
        "purple rice", "black rice", "japchaebap",
        "boribap", "ogokbap",
        "genmai",
        // South Asian whole grains
        "ragi", "bajra", "jowar", "whole wheat roti", "atta",
        "dalia",
        // African whole grains
        "fonio", "sorghum",
        // Latin American
        "masa harina", "blue corn",
        // Unicode
        "현미", "보리밥", "잡곡밥", "오곡밥",
        "玄米", "雑穀",
        "糙米", "燕麦", "藜麦",
        "जौ", "बाजरा", "जोवार"
    ]

    /// Cuisine markers used by the `logNewCuisine` quest and
    /// `cuisineVarietyGap` scoring. Each entry matches against
    /// `foodName.lowercased()` via substring. Specific markers
    /// over generic ones — e.g. "japanese" rather than "asian" — so
    /// a Japanese-curry log doesn't get scored as new-cuisine for a
    /// user who already eats Japanese food regularly.
    static let cuisineKeywords: [String] = [
        // East Asia
        "korean", "japanese", "chinese", "cantonese", "sichuan",
        "taiwanese", "mongolian",
        // Southeast Asia
        "thai", "vietnamese", "filipino", "indonesian", "malaysian",
        "singaporean", "cambodian", "lao", "burmese",
        // South Asia
        "indian", "pakistani", "bangladeshi", "sri lankan", "nepali",
        "punjabi", "bengali", "tamil", "kerala",
        // Middle East / West Asia
        "lebanese", "turkish", "persian", "iranian", "israeli",
        "syrian", "egyptian", "moroccan",
        // Africa
        "ethiopian", "nigerian", "ghanaian", "kenyan", "south african",
        "senegalese",
        // Europe
        "italian", "french", "spanish", "greek", "portuguese",
        "german", "polish", "russian", "ukrainian", "hungarian",
        "british", "irish", "scandinavian",
        // Americas
        "mexican", "tex-mex", "cuban", "puerto rican", "dominican",
        "brazilian", "argentinian", "peruvian", "colombian", "venezuelan",
        "caribbean", "jamaican", "cajun", "creole", "soul food",
        // Mediterranean / general regional
        "mediterranean", "middle eastern"
    ]
}
