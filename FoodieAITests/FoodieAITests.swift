import XCTest
@testable import FoodieAI

final class FoodieAITests: XCTestCase {
    func testLocalDayBoundsSpansExactly24h() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let (start, end) = FoodLogService.localDayBounds(
            now: Date(timeIntervalSince1970: 1_730_000_000),
            timeZone: tz
        )
        XCTAssertEqual(end.timeIntervalSince(start), 24 * 60 * 60, accuracy: 1)
    }
}

// MARK: - Phase 17 — EatingTimeInference

final class EatingTimeInferenceTests: XCTestCase {
    /// 20 logs all eaten at 12:30 in Los Angeles → lunch == 12:30,
    /// breakfast and dinner fall back to the static defaults (no logs
    /// in those windows). Confidence ≥ 15 logs, so .good.
    func testTwentyLogsAtHalfPastTwelve_lunchInferredOthersDefault() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let logs = Self.makeLogs(count: 20, hour: 12, minute: 30, timeZone: tz)

        let result = EatingTimeInference.infer(from: logs, timeZone: tz)

        XCTAssertEqual(result.confidence, .good)
        XCTAssertEqual(result.breakfast, EatingTimeInference.defaultBreakfast)
        XCTAssertEqual(result.lunch,     DateComponents(hour: 12, minute: 30))
        XCTAssertEqual(result.dinner,    EatingTimeInference.defaultDinner)
    }

    /// Regression: 6 logs all at 02:30 (outside every meal-window
    /// hour range) used to make pickTime return nil for all three
    /// windows on a .low-confidence user — scheduler then silently
    /// skipped every reminder. Now each window falls back to its
    /// default, confidence stays .low.
    func testLowConfidenceLogsOutsideAllWindows_fallsBackToDefaults() throws {
        let tz = TimeZone(identifier: "Asia/Seoul")!
        let logs = Self.makeLogs(count: 6, hour: 2, minute: 30, timeZone: tz)

        let result = EatingTimeInference.infer(from: logs, timeZone: tz)

        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.breakfast, DateComponents(hour: 8,  minute: 0))
        XCTAssertEqual(result.lunch,     DateComponents(hour: 12, minute: 30))
        XCTAssertEqual(result.dinner,    DateComponents(hour: 19, minute: 0))
    }

    /// 30 logs spread across 8am, 12:30pm, 7pm → all three populated.
    func testThirtyLogsSpread_allThreePopulated() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var logs = Self.makeLogs(count: 10, hour: 8,  minute: 0,  timeZone: tz)
        logs += Self.makeLogs(count: 10, hour: 12, minute: 30, timeZone: tz)
        logs += Self.makeLogs(count: 10, hour: 19, minute: 0,  timeZone: tz)

        let result = EatingTimeInference.infer(from: logs, timeZone: tz)

        XCTAssertEqual(result.confidence, .good)
        XCTAssertEqual(result.breakfast, DateComponents(hour: 8,  minute: 0))
        XCTAssertEqual(result.lunch,     DateComponents(hour: 12, minute: 30))
        XCTAssertEqual(result.dinner,    DateComponents(hour: 19, minute: 0))
    }

    /// 3 logs (< 5) → insufficient confidence with the static defaults.
    /// The defaults are explicit values rather than nil so the settings
    /// UI can still show suggestions ("Lunch — usually 12:30 PM").
    func testThreeLogs_insufficientWithDefaults() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let logs = Self.makeLogs(count: 3, hour: 12, minute: 30, timeZone: tz)

        let result = EatingTimeInference.infer(from: logs, timeZone: tz)

        XCTAssertEqual(result.confidence, .insufficient)
        XCTAssertEqual(result.breakfast, EatingTimeInference.defaultBreakfast)
        XCTAssertEqual(result.lunch,     EatingTimeInference.defaultLunch)
        XCTAssertEqual(result.dinner,    EatingTimeInference.defaultDinner)
    }

    /// Sanity: most-frequent minute within the densest hour wins.
    /// 8 logs at 12:15 + 1 at 12:00 in the same hour bucket → 12:15.
    func testMinuteResolution_picksMostFrequentMinute() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var logs = Self.makeLogs(count: 8, hour: 12, minute: 15, timeZone: tz)
        logs += Self.makeLogs(count: 1, hour: 12, minute: 0, timeZone: tz)
        // pad up to .good confidence (≥ 15)
        logs += Self.makeLogs(count: 6, hour: 19, minute: 0, timeZone: tz)

        let result = EatingTimeInference.infer(from: logs, timeZone: tz)

        XCTAssertEqual(result.confidence, .good)
        XCTAssertEqual(result.lunch, DateComponents(hour: 12, minute: 15))
    }

    // MARK: - Helpers

    /// Build N synthetic FoodLogs all timestamped at a fixed
    /// (hour, minute) on different days in the given timezone, so the
    /// date diversity doesn't pollute the hour/minute distribution.
    private static func makeLogs(count: Int,
                                 hour: Int,
                                 minute: Int,
                                 timeZone: TimeZone) -> [FoodLog] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let baseDate = Date(timeIntervalSince1970: 1_730_000_000)
        var logs: [FoodLog] = []
        for i in 0..<count {
            guard let day = cal.date(byAdding: .day, value: -i, to: baseDate) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            comps.timeZone = timeZone
            guard let dt = cal.date(from: comps) else { continue }

            logs.append(FoodLog(
                id: UUID(),
                userId: UUID(),
                foodName: "Test meal",
                imagePath: nil,
                imageThumbPath: nil,
                calories: 0,
                carbsG: 0,
                sugarG: 0,
                proteinG: nil,
                fatG: nil,
                fiberG: nil,
                benefits: [],
                drawbacks: [],
                nutrients: [],
                coachName: nil,
                coachAdvice: nil,
                eatenAt: dt,
                createdAt: Date(),
                origin: .analyzed,
                sourceLogId: nil,
                mood: nil
            ))
        }
        return logs
    }
}

// MARK: - Phase 20 — CalorieGoalCalculator

final class CalorieGoalCalculatorTests: XCTestCase {
    /// Worked example #1 from the Phase 20 spec: 30yo male, 175 cm,
    /// 75 kg, moderately active, lose weight → 2133 kcal target.
    func test_male_30_175cm_75kg_moderate_lose() {
        let goals = CalorieGoalCalculator.compute(.init(
            sex: .male, ageYears: 30, heightCm: 175, weightKg: 75,
            activity: .moderate, goal: .lose
        ))
        XCTAssertEqual(goals.bmr, 1699)
        XCTAssertEqual(goals.tdee, 2633)
        XCTAssertEqual(goals.calories, 2133)
        XCTAssertEqual(goals.carbsG, 267)
        XCTAssertEqual(goals.proteinG, 133)
        XCTAssertEqual(goals.fatG, 59)
        XCTAssertEqual(goals.fiberG, 30)
        XCTAssertEqual(goals.sugarG, 53)
        XCTAssertFalse(goals.wasFloored)
    }

    /// Worked example #2 from the Phase 20 spec: 28yo female, 162 cm,
    /// 60 kg, lightly active, maintain → 1803 kcal target.
    func test_female_28_162cm_60kg_light_maintain() {
        let goals = CalorieGoalCalculator.compute(.init(
            sex: .female, ageYears: 28, heightCm: 162, weightKg: 60,
            activity: .light, goal: .maintain
        ))
        XCTAssertEqual(goals.bmr, 1312)
        XCTAssertEqual(goals.tdee, 1803)
        XCTAssertEqual(goals.calories, 1803)
        XCTAssertEqual(goals.carbsG, 225)
        XCTAssertEqual(goals.proteinG, 113)
        XCTAssertEqual(goals.fatG, 50)
        XCTAssertEqual(goals.fiberG, 25)
        XCTAssertEqual(goals.sugarG, 45)
        XCTAssertFalse(goals.wasFloored)
    }

    /// Floor check: a tiny, very sedentary user with a 500 kcal deficit
    /// would compute well below the 1200 kcal female minimum. We clamp
    /// and surface `wasFloored` so the UI can explain the safe minimum.
    func test_floors_at_safe_minimum_for_female() {
        let goals = CalorieGoalCalculator.compute(.init(
            sex: .female, ageYears: 60, heightCm: 150, weightKg: 45,
            activity: .sedentary, goal: .lose
        ))
        XCTAssertEqual(goals.calories, 1200)
        XCTAssertTrue(goals.wasFloored)
    }

    /// `unspecified` must land strictly between male and female for an
    /// otherwise-identical input — confirms the averaged BMR constant
    /// is applied correctly rather than silently defaulting to one sex.
    func test_unspecified_uses_averaged_constant() {
        let male = CalorieGoalCalculator.compute(.init(
            sex: .male, ageYears: 30, heightCm: 170, weightKg: 70,
            activity: .moderate, goal: .maintain
        ))
        let female = CalorieGoalCalculator.compute(.init(
            sex: .female, ageYears: 30, heightCm: 170, weightKg: 70,
            activity: .moderate, goal: .maintain
        ))
        let unspec = CalorieGoalCalculator.compute(.init(
            sex: .unspecified, ageYears: 30, heightCm: 170, weightKg: 70,
            activity: .moderate, goal: .maintain
        ))
        XCTAssertGreaterThan(unspec.calories, female.calories)
        XCTAssertLessThan(unspec.calories, male.calories)
    }
}

// MARK: - Phase 21.5 — DailyQuest.Kind goal alignment

final class DailyQuestGoalAlignmentTests: XCTestCase {
    /// A loseWeight user should see stayUnderGoal + protein
    /// (preservation in deficit) and the universal health choices.
    /// Phase 21.12 — `logThreeMeals` was hard-removed in the reframing.
    func test_loseWeightUser_includesStayUnderGoal_andLogProtein() {
        let loseWeightKinds = DailyQuest.Kind.allCases.filter {
            $0.isAppropriate(for: .loseWeight, goal: .lose)
        }
        XCTAssertTrue(loseWeightKinds.contains(.stayUnderGoal))
        XCTAssertTrue(loseWeightKinds.contains(.logProtein))
        XCTAssertTrue(loseWeightKinds.contains(.logSomethingGreen))
    }

    /// A buildMuscle/gain user must NOT see stayUnderGoal (they're
    /// intentionally in surplus) but SHOULD see protein.
    func test_buildMuscleUser_excludesStayUnderGoal_andIncludesLogProtein() {
        let buildKinds = DailyQuest.Kind.allCases.filter {
            $0.isAppropriate(for: .buildMuscle, goal: .gain)
        }
        XCTAssertFalse(buildKinds.contains(.stayUnderGoal))
        XCTAssertTrue(buildKinds.contains(.logProtein))
    }

    /// User who skipped onboarding archetype + physiology shouldn't
    /// land in a weird empty pool — fall back to the everyone-
    /// appropriate quests.
    func test_nilArchetype_treatedAsAware() {
        let kinds = DailyQuest.Kind.allCases.filter {
            $0.isAppropriate(for: nil, goal: nil)
        }
        XCTAssertGreaterThanOrEqual(kinds.count, 3)
        // The universal Healthy Choice quests must all be present.
        XCTAssertTrue(kinds.contains(.logSomethingGreen))
        XCTAssertTrue(kinds.contains(.logFruit))
        XCTAssertTrue(kinds.contains(.logFiber))
    }

    // MARK: - Phase 21.12 — pool size after Healthy Choice expansion

    /// Phase 21.13 — pool grew to 28 kinds (dropped logColorfulMeal,
    /// added logBerry / logHydrationMeal / logAntioxidantRich).
    /// Aware + maintain is the most permissive archetype.
    func test_poolSize_aware_maintain_expanded() {
        let appropriate = DailyQuest.Kind.allCases.filter {
            $0.isAppropriate(for: .aware, goal: .maintain)
        }
        XCTAssertGreaterThanOrEqual(appropriate.count, 24)
    }

    /// Build-muscle / gain users skip the "eat less" framings
    /// (stayUnderGoal, logLightMeal, logLowSugar, logLowProcessedMeal).
    /// They should still have 22+ quests to draw from.
    func test_poolSize_buildMuscle_gain() {
        let pool = DailyQuest.Kind.allCases.filter {
            $0.isAppropriate(for: .buildMuscle, goal: .gain)
        }
        XCTAssertGreaterThanOrEqual(pool.count, 22)
    }

    /// Lose-weight users get the full universal set + lose-specific
    /// quests.
    func test_poolSize_loseWeight_lose() {
        let pool = DailyQuest.Kind.allCases.filter {
            $0.isAppropriate(for: .loseWeight, goal: .lose)
        }
        XCTAssertGreaterThanOrEqual(pool.count, 24)
    }
}

// MARK: - Phase 21.6 — Gap scoring

final class DailyQuestGapScoringTests: XCTestCase {

    // MARK: greenGap

    func test_greenGap_zeroGreenLogs_scoresHigh() {
        let logs = [
            Self.makeLog(name: "Pizza",  daysAgo: 1),
            Self.makeLog(name: "Burger", daysAgo: 2),
            Self.makeLog(name: "Ramen",  daysAgo: 3)
        ]
        let score = DailyQuest.Kind.logSomethingGreen.gapScore(recentLogs: logs)
        XCTAssertGreaterThan(score, 0.7)
    }

    func test_greenGap_threeGreenLogs_scoresLow() {
        let logs = [
            Self.makeLog(name: "Kimchi",         daysAgo: 1),
            Self.makeLog(name: "Spinach salad",  daysAgo: 2),
            Self.makeLog(name: "Broccoli",       daysAgo: 3)
        ]
        let score = DailyQuest.Kind.logSomethingGreen.gapScore(recentLogs: logs)
        XCTAssertLessThan(score, 0.3)
    }

    // MARK: proteinGap

    func test_proteinGap_zeroHighProteinLogs_scoresHigh() {
        let logs = [
            Self.makeLog(name: "Apple",  daysAgo: 1, proteinG: 0.3),
            Self.makeLog(name: "Toast",  daysAgo: 2, proteinG: 5),
            Self.makeLog(name: "Banana", daysAgo: 3, proteinG: 1.0)
        ]
        let score = DailyQuest.Kind.logProtein.gapScore(recentLogs: logs)
        XCTAssertGreaterThan(score, 0.7)
    }

    func test_proteinGap_fiveHighProteinLogs_scoresLow() {
        let logs = (1...5).map {
            Self.makeLog(name: "Chicken breast", daysAgo: $0, proteinG: 30)
        }
        let score = DailyQuest.Kind.logProtein.gapScore(recentLogs: logs)
        XCTAssertLessThan(score, 0.25)
    }

    // MARK: Phase 21.12 — scoring smoke tests for new kinds

    /// User who never logs a cruciferous vegetable scores high.
    func test_cruciferGap_zeroCrucifer_scoresHigh() {
        let logs = [
            Self.makeLog(name: "Rice",   daysAgo: 1),
            Self.makeLog(name: "Burger", daysAgo: 2)
        ]
        let score = DailyQuest.Kind.logCrucifer.gapScore(recentLogs: logs)
        XCTAssertGreaterThan(score, 0.6)
    }

    /// User who logs broccoli repeatedly scores low — this isn't a
    /// gap for them.
    func test_cruciferGap_repeatedCrucifer_scoresLow() {
        let logs = (1...5).map {
            Self.makeLog(name: "Broccoli stir fry", daysAgo: $0)
        }
        let score = DailyQuest.Kind.logCrucifer.gapScore(recentLogs: logs)
        XCTAssertLessThan(score, 0.4)
    }

    /// Late dinners pull the early-dinner gap toward "you should
    /// eat earlier."
    func test_earlyDinnerHealthGap_lateDinners_scoresHigh() {
        let logs = (1...5).map { day in
            Self.makeLog(name: "Dinner", daysAgo: day, hour: 21)
        }
        let score = DailyQuest.Kind.logEarlyDinnerHealth.gapScore(recentLogs: logs)
        XCTAssertGreaterThan(score, 0.6)
    }

    // MARK: Phase 21.13 — berry / hydration / antioxidant scorers

    /// No berry log in the last 7 days → high gap.
    /// Bananas are fruit but not berries, so they shouldn't count.
    func test_berryGap_zeroBerryLogs_scoresHigh() {
        let logs = [
            Self.makeLog(name: "Pizza",  daysAgo: 1),
            Self.makeLog(name: "Pasta",  daysAgo: 2),
            Self.makeLog(name: "Banana", daysAgo: 3)
        ]
        let score = DailyQuest.Kind.logBerry.gapScore(recentLogs: logs)
        XCTAssertGreaterThan(score, 0.7)
    }

    /// Three berry logs covering blueberry / strawberry / raspberry
    /// substrings — the gap should fall well below 0.35.
    func test_berryGap_threeBerryLogs_scoresLow() {
        let logs = [
            Self.makeLog(name: "Blueberries",        daysAgo: 1),
            Self.makeLog(name: "Strawberry yogurt",  daysAgo: 2),
            Self.makeLog(name: "Raspberry smoothie", daysAgo: 3)
        ]
        let score = DailyQuest.Kind.logBerry.gapScore(recentLogs: logs)
        XCTAssertLessThan(score, 0.35)
    }

    /// Cucumber + watermelon + miso soup — three hydration matches.
    /// `scoreHydrationGap` floors slower than `scoreBerryGap`, so we
    /// only need to confirm we're under the mid-pool ~0.45.
    func test_hydrationGap_hydratingFoodsDetected() {
        let logs = [
            Self.makeLog(name: "Cucumber salad", daysAgo: 1),
            Self.makeLog(name: "Watermelon",     daysAgo: 2),
            Self.makeLog(name: "Miso soup",      daysAgo: 3)
        ]
        let score = DailyQuest.Kind.logHydrationMeal.gapScore(recentLogs: logs)
        XCTAssertLessThan(score, 0.45)
    }

    /// Tea / cocoa / berry combo — broad antioxidant coverage.
    func test_antioxidantGap_relevantFoodsDetected() {
        let logs = [
            Self.makeLog(name: "Green tea",      daysAgo: 1),
            Self.makeLog(name: "Dark chocolate", daysAgo: 2),
            Self.makeLog(name: "Blueberries",    daysAgo: 3)
        ]
        let score = DailyQuest.Kind.logAntioxidantRich.gapScore(recentLogs: logs)
        XCTAssertLessThan(score, 0.4)
    }

    // MARK: helpers

    /// Builds a FoodLog at `daysAgo` days back from `Date()`, snapped
    /// to `hour:00:00` local. Used by every test above.
    private static func makeLog(name: String,
                                daysAgo: Int,
                                hour: Int = 12,
                                proteinG: Double? = nil) -> FoodLog {
        var comps = DateComponents()
        comps.day = -daysAgo
        let base = Calendar.current.date(byAdding: comps, to: Date())!
        let dt = Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: base
        )!
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: 400,
            carbsG: 50,
            sugarG: 5,
            proteinG: proteinG,
            fatG: 10,
            fiberG: 3,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: dt,
            createdAt: dt,
            origin: .analyzed,
            sourceLogId: nil,
            mood: nil
        )
    }
}

// MARK: - Local Bayesian personalization

/// Each test runs against an isolated UserDefaults suite so the
/// shared store can't see fixtures from sibling tests (and the
/// device's real beliefs aren't mutated when these run on-device).
@MainActor
final class LocalNutritionBeliefStoreTests: XCTestCase {

    private func freshStore() -> LocalNutritionBeliefStore {
        let suiteName = "foodie.beliefs.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LocalNutritionBeliefStore(defaults: defaults)
    }

    /// First observation initializes the belief — count = 1, mean = observation.
    func test_firstObservation_createsBelief() {
        let store = freshStore()
        store.update(foodName: "Chicken Rice",
                     calories: 600, carbs: 80, protein: 35,
                     fat: 12, sugar: 4, fiber: 3)

        let b = store.belief(for: "chicken rice")
        XCTAssertNotNil(b)
        XCTAssertEqual(b?.observations, 1)
        XCTAssertEqual(b?.calories.count, 1)
        XCTAssertEqual(b?.calories.mean ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(b?.confidence, .low)
    }

    /// Welford incremental mean: second observation drives mean to
    /// the arithmetic average of the two.
    func test_secondObservation_updatesMeanCorrectly() {
        let store = freshStore()
        store.update(foodName: "Pad Thai",
                     calories: 700, carbs: nil, protein: nil,
                     fat: nil, sugar: nil, fiber: nil)
        store.update(foodName: "Pad Thai",
                     calories: 900, carbs: nil, protein: nil,
                     fat: nil, sugar: nil, fiber: nil)
        let b = store.belief(for: "Pad Thai")!
        XCTAssertEqual(b.observations, 2)
        XCTAssertEqual(b.calories.count, 2)
        XCTAssertEqual(b.calories.mean, 800, accuracy: 0.001)
    }

    /// Confidence buckets: 1 = low, 3 = medium, 6 = high.
    func test_confidenceBuckets_byObservationCount() {
        let store = freshStore()
        for _ in 0..<1 {
            store.update(foodName: "Apple", calories: 95,
                         carbs: 25, protein: 0, fat: 0, sugar: 19, fiber: 4)
        }
        XCTAssertEqual(store.belief(for: "Apple")?.confidence, .low)

        for _ in 0..<2 {
            store.update(foodName: "Apple", calories: 95,
                         carbs: 25, protein: 0, fat: 0, sugar: 19, fiber: 4)
        }
        XCTAssertEqual(store.belief(for: "Apple")?.confidence, .medium)

        for _ in 0..<3 {
            store.update(foodName: "Apple", calories: 95,
                         carbs: 25, protein: 0, fat: 0, sugar: 19, fiber: 4)
        }
        XCTAssertEqual(store.belief(for: "Apple")?.confidence, .high)
    }

    /// Missing macros must not crash and must not poison the prior:
    /// the calorie mean stays at the first observation, and protein
    /// stays at its default zero count.
    func test_missingMacros_doNotCrashOrPoisonMean() {
        let store = freshStore()
        store.update(foodName: "Soup",
                     calories: 180, carbs: 20, protein: nil,
                     fat: nil, sugar: nil, fiber: nil)
        // Second observation with everything nil — should bump
        // `observations` but no per-macro count except where nil-free.
        store.update(foodName: "Soup",
                     calories: nil, carbs: nil, protein: nil,
                     fat: nil, sugar: nil, fiber: nil)
        let b = store.belief(for: "Soup")!
        XCTAssertEqual(b.observations, 2)
        XCTAssertEqual(b.calories.count, 1)
        XCTAssertEqual(b.calories.mean, 180, accuracy: 0.001)
        XCTAssertEqual(b.protein.count, 0)
        XCTAssertEqual(b.protein.mean, 0)
    }

    /// Encode/decode round-trip through UserDefaults JSON.
    func test_persistence_roundTripsThroughUserDefaults() {
        let suiteName = "foodie.beliefs.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store1 = LocalNutritionBeliefStore(defaults: defaults)
        store1.update(foodName: "Kimchi Stew",
                      calories: 420, carbs: 18, protein: 24,
                      fat: 20, sugar: 6, fiber: 5)
        store1.update(foodName: "Kimchi Stew",
                      calories: 480, carbs: 20, protein: 28,
                      fat: 22, sugar: 7, fiber: 6)

        // Rehydrate from the same defaults.
        let store2 = LocalNutritionBeliefStore(defaults: defaults)
        let b = store2.belief(for: "kimchi stew")
        XCTAssertNotNil(b)
        XCTAssertEqual(b?.observations, 2)
        XCTAssertEqual(b?.calories.mean ?? 0, 450, accuracy: 0.001)
        XCTAssertEqual(b?.protein.count, 2)
    }

    /// Normalization: case + whitespace differences map to the same
    /// belief.
    func test_normalization_caseAndWhitespaceInsensitive() {
        let store = freshStore()
        store.update(foodName: "Chicken  Rice",
                     calories: 600, carbs: 80, protein: 35,
                     fat: 12, sugar: 4, fiber: 3)
        store.update(foodName: "chicken rice",
                     calories: 700, carbs: 85, protein: 38,
                     fat: 14, sugar: 4, fiber: 3)
        XCTAssertEqual(store.belief(for: "CHICKEN RICE")?.observations, 2)
    }
}

// MARK: - FoodPatternInsightService
//
// Contract under test:
//   1. The service NEVER mutates the AnalyzeResponse it receives.
//   2. The result type has NO `adjustedCalories` / equivalent override
//      surface — pattern insight is read-only enrichment.
//   3. First-time foods yield an empty insight with no card content.
//   4. With priors, the service produces the comparison / repeated /
//      mood lines documented in the spec.

final class FoodPatternInsightServiceTests: XCTestCase {

    /// Brand-new food: the wrapper is empty and the card has nothing
    /// to show. This is the "gentle empty state" branch — the UI
    /// gates on `hasAnyContent` and hides the card.
    func test_firstTimeMeal_yieldsEmptyInsight() {
        let response = Self.makeResponse(food: "Salmon Bowl", calories: 700)
        let insight = FoodPatternInsightService.compute(
            response: response,
            belief: nil,
            typicalMealCalories: nil
        )
        XCTAssertTrue(insight.isEmpty)
        XCTAssertFalse(insight.hasAnyContent)
        XCTAssertEqual(insight.similarMealCount, 0)
        XCTAssertNil(insight.comparisonToUserAverage)
        XCTAssertNil(insight.comparisonToTypicalMeal)
        XCTAssertNil(insight.repeatedFoodNote)
        XCTAssertNil(insight.moodNote)
    }

    /// Critical regression guard: after the service runs, the
    /// AnalyzeResponse that was passed in is still byte-identical to
    /// the snapshot taken before the call. AnalyzeResponse is a value
    /// type so this is partly enforced by the language — the assertion
    /// also serves as documentation of the contract.
    func test_geminiResponse_isNotMutated() {
        let response = Self.makeResponse(
            food: "Chicken Rice", calories: 600,
            carbs: 80, protein: 35, fat: 12, sugar: 4, fiber: 3
        )
        let snapshot = response
        let belief = Self.belief(name: "Chicken Rice",
                                 obs: 5,
                                 caloriesMean: 520,
                                 caloriesCount: 5)
        _ = FoodPatternInsightService.compute(
            response: response,
            belief: belief,
            typicalMealCalories: 500
        )
        XCTAssertEqual(response, snapshot,
                       "FoodPatternInsightService must not mutate AnalyzeResponse")
        XCTAssertEqual(response.analysis.calories, 600)
        XCTAssertEqual(response.analysis.carbs,    80)
        XCTAssertEqual(response.analysis.protein,  35)
        XCTAssertEqual(response.analysis.fat,      12)
        XCTAssertEqual(response.analysis.sugar,    4)
        XCTAssertEqual(response.analysis.fiber,    3)
    }

    /// The FoodPatternInsight type must NOT expose any adjusted/override
    /// surface for calories or macros — that was the v1 mistake. We
    /// enforce it structurally via Mirror so a future field named
    /// `adjustedCalories` (or similar) fails this test loudly.
    func test_insight_hasNoCalorieOverrideSurface() {
        let belief = Self.belief(name: "Bowl",
                                 obs: 3, caloriesMean: 500, caloriesCount: 3)
        let insight = FoodPatternInsightService.compute(
            response: Self.makeResponse(food: "Bowl", calories: 800),
            belief: belief,
            typicalMealCalories: 500
        )
        let labels = Mirror(reflecting: insight).children.compactMap(\.label)
        let forbidden = ["adjustedCalories", "adjustedMacros",
                         "correctedCalories", "overrideCalories"]
        for name in forbidden {
            XCTAssertFalse(labels.contains(name),
                           "FoodPatternInsight must not carry an override field named '\(name)'")
        }
    }

    /// "Heavier than your usual" branch when the meal is > 15% above
    /// the user's mean for the same food.
    func test_comparisonToUserAverage_higherWhenWellAbove() {
        let belief = Self.belief(name: "Latte",
                                 obs: 4,
                                 caloriesMean: 180,
                                 caloriesCount: 4)
        let response = Self.makeResponse(food: "Latte", calories: 260)
        let insight = FoodPatternInsightService.compute(
            response: response, belief: belief, typicalMealCalories: nil
        )
        let cmp = insight.comparisonToUserAverage!
        XCTAssertEqual(cmp.kind, .userAverageForFood)
        XCTAssertEqual(cmp.direction, .higher)
        XCTAssertTrue(cmp.copy.lowercased().contains("latte"))
    }

    /// "Around your typical meal" branch fires when calories are
    /// within 20% of the global typical.
    func test_comparisonToTypicalMeal_similarWhenWithinBand() {
        let belief = Self.belief(name: "Soup",
                                 obs: 2,
                                 caloriesMean: 220,
                                 caloriesCount: 2)
        let response = Self.makeResponse(food: "Soup", calories: 510)
        let insight = FoodPatternInsightService.compute(
            response: response, belief: belief, typicalMealCalories: 500
        )
        let cmp = insight.comparisonToTypicalMeal!
        XCTAssertEqual(cmp.kind, .typicalMeal)
        XCTAssertEqual(cmp.direction, .similar)
    }

    /// Repeated-food note kicks in at 2+ priors and uses the food name.
    func test_repeatedFoodNote_atTwoPriors() {
        let belief = Self.belief(name: "Bibimbap",
                                 obs: 3,
                                 caloriesMean: 500,
                                 caloriesCount: 3)
        let response = Self.makeResponse(food: "Bibimbap", calories: 510)
        let insight = FoodPatternInsightService.compute(
            response: response, belief: belief, typicalMealCalories: nil
        )
        let note = insight.repeatedFoodNote!
        XCTAssertTrue(note.lowercased().contains("bibimbap"))
        XCTAssertTrue(note.contains("3"))
    }

    /// Mood note surfaces when the histogram has ≥ 2 reports and a
    /// dominant mood. A 3-loved / 0-fine / 0-tough sample should
    /// pick `.loved`.
    func test_moodNote_dominantLovedSurfaces() {
        var belief = Self.belief(name: "Pasta",
                                 obs: 3,
                                 caloriesMean: 700,
                                 caloriesCount: 3)
        belief.moodCounts.loved = 3
        let response = Self.makeResponse(food: "Pasta", calories: 720)
        let insight = FoodPatternInsightService.compute(
            response: response, belief: belief, typicalMealCalories: nil
        )
        XCTAssertNotNil(insight.moodNote)
    }

    /// A thin, evenly-split mood histogram must NOT surface a note —
    /// we'd be lying about the pattern.
    func test_moodNote_silentOnEvenSplit() {
        var belief = Self.belief(name: "Pasta",
                                 obs: 3,
                                 caloriesMean: 700,
                                 caloriesCount: 3)
        belief.moodCounts.loved = 1
        belief.moodCounts.fine  = 1
        belief.moodCounts.tough = 1
        let response = Self.makeResponse(food: "Pasta", calories: 720)
        let insight = FoodPatternInsightService.compute(
            response: response, belief: belief, typicalMealCalories: nil
        )
        XCTAssertNil(insight.moodNote)
    }

    // MARK: - Helpers

    private static func makeResponse(food: String,
                                     calories: Double?,
                                     carbs: Double? = nil,
                                     protein: Double? = nil,
                                     fat: Double? = nil,
                                     sugar: Double? = nil,
                                     fiber: Double? = nil) -> AnalyzeResponse {
        AnalyzeResponse(
            analysis: GeminiAnalysis(
                fallback: nil,
                food: food,
                calories: calories,
                carbs: carbs, sugar: sugar,
                protein: protein, fat: fat, fiber: fiber,
                benefits: nil, drawbacks: nil, nutrients: nil,
                coachAdvice: nil,
                portionAmbiguousItems: nil
            ),
            coach: nil
        )
    }

    private static func belief(name: String,
                               obs: Int,
                               caloriesMean: Double,
                               caloriesCount: Int) -> FoodBelief {
        FoodBelief(
            foodKey: LocalNutritionBeliefStore.normalize(name),
            displayName: name,
            calories: MacroBelief(mean: caloriesMean, count: caloriesCount),
            carbs:    MacroBelief(),
            protein:  MacroBelief(),
            fat:      MacroBelief(),
            sugar:    MacroBelief(),
            fiber:    MacroBelief(),
            moodCounts: MoodCounts(),
            observations: obs,
            lastUpdated: Date()
        )
    }
}

// MARK: - Home Mirror preview
//
// `HomeMirrorPreview.cardModel(for:)` is the pure picker that drives
// the LifeOS-style Home Food Mirror card. These tests exercise its
// title/body/nudge/evidence selection so the Home surface stays
// honest and the copy never drifts into shame/medical territory.

final class HomeMirrorPreviewTests: XCTestCase {

    /// Under the 8-log threshold → learning card, regardless of
    /// which insight fields happen to be populated.
    func test_homePreview_underEightLogsReturnsLearning() {
        let summary = Self.makeSummary(
            hasEnoughData: false,
            learningProgress: LearningProgress.from(thirtyDayLogCount: 5),
            todaysGentleNudge: "Try keeping dinner a little lighter today."
        )
        let model = HomeMirrorPreview.cardModel(for: summary)
        XCTAssertNotNil(model)
        guard case let .learning(progress) = model?.kind else {
            return XCTFail("Expected .learning kind")
        }
        XCTAssertEqual(progress.state, .formingPatterns)
        XCTAssertEqual(progress.mealsLoggedInWindow, 5)
        XCTAssertEqual(model?.title, "Your mirror is learning you.")
        XCTAssertEqual(model?.body,  "The picture sharpens as you log meals.")
        XCTAssertEqual(model?.evidenceLine, "5 of 8 meals logged")
        XCTAssertEqual(model?.ctaText, "Keep logging →")
        // Learning state suppresses the nudge — keeps the empty-state
        // copy on-message and avoids implying a half-formed pattern.
        XCTAssertNil(model?.nudgeLine)
    }

    /// Ready state uses `eatingIdentity` as the title when present,
    /// even if `thisWeekChanged` / `weeklySummary` also have content.
    func test_homePreview_readyUsesEatingIdentityAsTitle() {
        let summary = Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 10,
            eatingIdentity:    "You're forming a simple, carb-centered eating pattern.",
            weeklySummary:     "You logged 12 meals this past week.",
            thisWeekChanged:   "Your dinners ran lighter this week."
        )
        let model = HomeMirrorPreview.cardModel(for: summary)
        XCTAssertEqual(model?.title, "You're forming a simple, carb-centered eating pattern.")
        XCTAssertEqual(model?.kind,  .ready)
        XCTAssertEqual(model?.ctaText, "Open Mirror →")
    }

    /// Eating identity absent → `thisWeekChanged` takes the title.
    func test_homePreview_fallsBackToThisWeekChanged() {
        let summary = Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 10,
            weeklySummary:     "You logged 12 meals this past week.",
            thisWeekChanged:   "Your dinners ran lighter this week."
        )
        XCTAssertEqual(
            HomeMirrorPreview.cardModel(for: summary)?.title,
            "Your dinners ran lighter this week."
        )
    }

    /// Both identity and week-change absent → `weeklySummary`.
    func test_homePreview_fallsBackToWeeklySummary() {
        let summary = Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 10,
            weeklySummary:     "You logged 12 meals this past week."
        )
        XCTAssertEqual(
            HomeMirrorPreview.cardModel(for: summary)?.title,
            "You logged 12 meals this past week."
        )
    }

    /// `todaysGentleNudge` lives in its own slot now — it never
    /// competes for the title and always surfaces as `nudgeLine`.
    func test_homePreview_includesGentleNudgeAsNudgeLine() {
        let summary = Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 10,
            eatingIdentity:    "You're forming a simple pattern.",
            todaysGentleNudge: "Maybe make space for protein today."
        )
        let model = HomeMirrorPreview.cardModel(for: summary)
        XCTAssertEqual(model?.nudgeLine, "Maybe make space for protein today.")
        XCTAssertEqual(model?.title,     "You're forming a simple pattern.")
    }

    /// `moodInsight` populates the body slot.
    func test_homePreview_bodyUsesMoodInsightWhenAvailable() {
        let summary = Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 10,
            eatingIdentity:    "Title.",
            moodInsight:       "You've felt good after most of your meals lately.",
            timingInsight:     "Your dinners tend to be heavier than your lunches."
        )
        XCTAssertEqual(
            HomeMirrorPreview.cardModel(for: summary)?.body,
            "You've felt good after most of your meals lately."
        )
    }

    /// `timingInsight` is the body fallback when mood is absent.
    func test_homePreview_bodyFallsBackToTimingInsight() {
        let summary = Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 10,
            eatingIdentity:    "Title.",
            timingInsight:     "Your dinners tend to be heavier than your lunches."
        )
        XCTAssertEqual(
            HomeMirrorPreview.cardModel(for: summary)?.body,
            "Your dinners tend to be heavier than your lunches."
        )
    }

    /// Evidence line scales with the underlying log count: 20+ → full
    /// 30-day claim, ≥8 → cites the exact count.
    func test_homePreview_evidenceLineTracksLogCount() {
        let model8 = HomeMirrorPreview.cardModel(for: Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 8,
            eatingIdentity:    "Title."
        ))
        XCTAssertEqual(model8?.evidenceLine, "Based on 8 meals logged")

        let model22 = HomeMirrorPreview.cardModel(for: Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 22,
            eatingIdentity:    "Title."
        ))
        XCTAssertEqual(model22?.evidenceLine, "Based on 30 days of logs")
    }

    /// Empty insights + `hasEnoughData == true` is a defensive edge
    /// case. The helper returns nil so the Home card hides cleanly
    /// rather than rendering an empty ready-state shell.
    func test_homePreview_returnsNilWhenNoContentAndEnoughData() {
        let summary = Self.makeSummary(hasEnoughData: true, thirtyDayLogCount: 10)
        XCTAssertNil(HomeMirrorPreview.cardModel(for: summary))
    }

    /// `FoodMirrorSummary.empty` (zero-log default) routes to learning,
    /// not nil — Home should always say *something* to a brand-new
    /// user instead of hiding the card silently.
    func test_homePreview_emptySummaryReturnsLearning() {
        let model = HomeMirrorPreview.cardModel(for: .empty)
        XCTAssertNotNil(model)
        guard case let .learning(progress) = model?.kind else {
            return XCTFail("Expected .learning kind")
        }
        XCTAssertEqual(progress.state, .empty)
        XCTAssertEqual(progress.mealsLoggedInWindow, 0)
        XCTAssertEqual(model?.evidenceLine, "0 of 8 meals logged")
    }

    /// The static copy this picker controls (titles, body, CTAs,
    /// evidence template) must not lean on shame/medical/bossy
    /// language. Insight-derived strings flow through verbatim from
    /// `FoodMirrorInsightService`, which has its own tone tests, so we
    /// scope this check to the strings *this* layer authors.
    func test_homePreview_staticCopyAvoidsShameAndMedicalLanguage() {
        let learning = HomeMirrorPreview.cardModel(for: .empty)
        let ready = HomeMirrorPreview.cardModel(for: Self.makeSummary(
            hasEnoughData:     true,
            thirtyDayLogCount: 22,
            eatingIdentity:    "_PLACEHOLDER_"  // not under test
        ))
        let authored: [String] = [
            learning?.title, learning?.body, learning?.ctaText, learning?.eyebrow,
            ready?.ctaText, ready?.evidenceLine, ready?.eyebrow
        ].compactMap { $0 }

        let banned: [String] = [
            "must", "should not", "shouldn't", "stop eating",
            "diagnose", "disease", "diabetes", "cure",
            "obese", "you need to", "you have to"
        ]
        for text in authored {
            let lower = text.lowercased()
            for term in banned {
                XCTAssertFalse(
                    lower.contains(term),
                    "Found banned term '\(term)' in authored copy: \(text)"
                )
            }
        }
    }

    // MARK: - Helper

    /// Build a `FoodMirrorSummary` with only the fields the test
    /// cares about. Defaults match a fresh-but-empty Mirror so the
    /// `hasEnoughData = true` tests don't have to re-specify the
    /// learning curve.
    private static func makeSummary(
        hasEnoughData: Bool,
        thirtyDayLogCount: Int? = nil,
        learningProgress: LearningProgress? = nil,
        eatingIdentity: String? = nil,
        weeklySummary: String? = nil,
        moodInsight: String? = nil,
        timingInsight: String? = nil,
        thisWeekChanged: String? = nil,
        todaysGentleNudge: String? = nil,
        suggestedExperiment: String? = nil
    ) -> FoodMirrorSummary {
        let count    = thirtyDayLogCount ?? (hasEnoughData ? 12 : 0)
        let progress = learningProgress  ?? LearningProgress.from(thirtyDayLogCount: count)
        return FoodMirrorSummary(
            hasEnoughData:       hasEnoughData,
            learningProgress:    progress,
            thirtyDayLogCount:   count,
            sevenDayLogCount:    0,
            moodLogCount:        0,
            eatingIdentity:      eatingIdentity,
            weeklySummary:       weeklySummary,
            mostCommonFoods:     [],
            moodInsight:         moodInsight,
            timingInsight:       timingInsight,
            thisWeekChanged:     thisWeekChanged,
            todaysGentleNudge:   todaysGentleNudge,
            suggestedExperiment: suggestedExperiment
        )
    }
}

// MARK: - Save-flow contract
//
// These tests assert at the data-model level that nothing in the
// save pipeline rewrites Gemini's calories/macros. We exercise the
// projection done at the CaptureViewModel.save() boundary directly
// (constructing a NewFoodLog from an AnalyzeResponse) so we don't
// need a Supabase round-trip to verify the contract.

final class SaveFlowMacroPreservationTests: XCTestCase {

    /// The NewFoodLog draft built from an AnalyzeResponse must carry
    /// Gemini's macros verbatim. No personalization-driven adjustment
    /// is allowed at this seam — this is the test that fails loudly
    /// if someone ever tries to thread an adjusted value through.
    func test_newFoodLog_preservesGeminiMacrosExactly() {
        let response = AnalyzeResponse(
            analysis: GeminiAnalysis(
                fallback: nil,
                food: "Pad Thai",
                calories: 642,
                carbs: 87,
                sugar: 14,
                protein: 22,
                fat: 18,
                fiber: 5,
                benefits: [],
                drawbacks: [],
                nutrients: [],
                coachAdvice: nil,
                portionAmbiguousItems: nil
            ),
            coach: nil
        )

        // Mirror the exact projection done in `CaptureViewModel.save()`.
        let draft = NewFoodLog(
            foodName:        response.analysis.food ?? "Unknown",
            imagePath:       "irrelevant",
            imageThumbPath:  "irrelevant",
            calories:        response.analysis.calories ?? 0,
            carbsG:          response.analysis.carbs ?? 0,
            sugarG:          response.analysis.sugar ?? 0,
            proteinG:        response.analysis.protein,
            fatG:            response.analysis.fat,
            fiberG:          response.analysis.fiber,
            benefits:        response.analysis.benefits ?? [],
            drawbacks:       response.analysis.drawbacks ?? [],
            nutrients:       response.analysis.nutrients ?? [],
            coachName:       response.coach,
            coachAdvice:     response.analysis.coachAdvice
        )

        XCTAssertEqual(draft.calories, 642)
        XCTAssertEqual(draft.carbsG,   87)
        XCTAssertEqual(draft.sugarG,   14)
        XCTAssertEqual(draft.proteinG, 22)
        XCTAssertEqual(draft.fatG,     18)
        XCTAssertEqual(draft.fiberG,   5)
    }
}

// MARK: - Belief-store post-save update
//
// Belief updates must continue to fire after every successful save so
// the next scan of the same food sees a stronger pattern.

@MainActor
final class BeliefStorePostSaveUpdateTests: XCTestCase {

    private func freshStore() -> LocalNutritionBeliefStore {
        let suiteName = "foodie.beliefs.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LocalNutritionBeliefStore(defaults: defaults)
    }

    /// Simulates the post-save belief update path. The store should
    /// reflect the inserted log's exact macros — same numbers, same
    /// mood — without any adjustment layer in between.
    func test_beliefStore_updatesFromSavedLog() {
        let store = freshStore()
        let log = Self.makeLog(
            foodName: "Kimchi Stew",
            calories: 420, carbs: 18, protein: 24,
            fat: 20, sugar: 6, fiber: 5, mood: .loved
        )

        store.update(from: log)

        let belief = store.belief(for: "Kimchi Stew")!
        XCTAssertEqual(belief.observations, 1)
        XCTAssertEqual(belief.calories.mean, 420, accuracy: 0.001)
        XCTAssertEqual(belief.moodCounts.loved, 1)
    }

    /// Two saves in a row of the same food must update the running
    /// mean toward the average of the two — proving Welford's recurrence
    /// still operates on real FoodLog inputs (not just the granular
    /// test API).
    func test_beliefStore_meanUpdatesAcrossMultipleSaves() {
        let store = freshStore()
        store.update(from: Self.makeLog(
            foodName: "Latte", calories: 180,
            carbs: 20, protein: 6, fat: 8, sugar: 18, fiber: 0, mood: nil
        ))
        store.update(from: Self.makeLog(
            foodName: "Latte", calories: 220,
            carbs: 22, protein: 7, fat: 9, sugar: 20, fiber: 0, mood: .fine
        ))
        let belief = store.belief(for: "Latte")!
        XCTAssertEqual(belief.observations, 2)
        XCTAssertEqual(belief.calories.mean, 200, accuracy: 0.001)
        XCTAssertEqual(belief.moodCounts.fine, 1)
    }

    /// Late-binding mood (called from the mood pulse) updates the
    /// histogram without double-counting the observation.
    func test_beliefStore_lateMoodBindingDoesNotInflateCount() {
        let store = freshStore()
        store.update(from: Self.makeLog(
            foodName: "Salad", calories: 300,
            carbs: 18, protein: 12, fat: 14, sugar: 4, fiber: 6, mood: nil
        ))
        XCTAssertEqual(store.belief(for: "Salad")?.observations, 1)

        store.recordMoodIfKnown(.loved, for: "Salad")
        let after = store.belief(for: "Salad")!
        XCTAssertEqual(after.observations, 1, "mood pulse must not bump observations again")
        XCTAssertEqual(after.moodCounts.loved, 1)
    }

    private static func makeLog(foodName: String,
                                calories: Double,
                                carbs: Double,
                                protein: Double?,
                                fat: Double?,
                                sugar: Double,
                                fiber: Double?,
                                mood: FoodLog.Mood?) -> FoodLog {
        FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: foodName,
            imagePath: nil,
            imageThumbPath: nil,
            calories: calories,
            carbsG: carbs,
            sugarG: sugar,
            proteinG: protein,
            fatG: fat,
            fiberG: fiber,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: Date(),
            createdAt: Date(),
            origin: .analyzed,
            sourceLogId: nil,
            mood: mood
        )
    }
}

// MARK: - Food Mirror insight service
//
// The Food Mirror tab summarizes saved logs into a `FoodMirrorSummary`
// of patterns. The service is pure and synchronous — these tests pass
// in synthetic `[FoodLog]` and assert on the returned summary directly.
//
// Contract under test:
//   1. < 3 logs → hasEnoughData == false and every other field empty.
//   2. Weekly summary surfaces meal count + average calorie line.
//   3. Most-common foods are ranked by count, top first.
//   4. Dinner > lunch (≥ 25%) produces a clear timing line.
//   5. Mood insight requires ≥ 2 mood-labeled logs AND ≥ 60% dominance.
//   6. Suggested experiment is small, safe, and time-boxed.
//   7. The service's public API never references AnalyzeResponse or
//      anything Gemini-shaped.

final class FoodMirrorInsightServiceTests: XCTestCase {

    private static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    /// Pinned "now" so 30-day windows in the helpers land on stable
    /// dates regardless of when the test runs.
    private static let now = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: - Empty state

    /// Two logs is below the 3-log floor — the service returns the
    /// empty sentinel and the view will show the "still learning"
    /// state.
    func test_fewerThanThreeLogs_returnsEmpty() {
        let logs = [
            Self.makeLog(name: "Apple", daysAgo: 1),
            Self.makeLog(name: "Toast", daysAgo: 2)
        ]
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  logs,
            now:           Self.now,
            timeZone:      Self.timeZone
        )
        XCTAssertFalse(summary.hasEnoughData)
        XCTAssertNil(summary.eatingIdentity)
        XCTAssertNil(summary.weeklySummary)
        XCTAssertTrue(summary.mostCommonFoods.isEmpty)
        XCTAssertNil(summary.moodInsight)
        XCTAssertNil(summary.timingInsight)
        XCTAssertNil(summary.suggestedExperiment)
        XCTAssertFalse(summary.hasAnyContent)
    }

    // MARK: - Weekly summary

    /// 5 logs in the 7-day window with calorie data → the weekly
    /// summary mentions both the meal count and an average calorie
    /// figure derived from those logs.
    func test_weeklySummary_includesMealCountAndAverageKcal() {
        let sevenDay = (1...5).map {
            Self.makeLog(name: "Salad", daysAgo: $0, calories: 500)
        }
        let thirtyDay = sevenDay + (8...12).map {
            Self.makeLog(name: "Soup", daysAgo: $0, calories: 400)
        }
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: thirtyDay,
            sevenDayLogs:  sevenDay,
            now:           Self.now,
            timeZone:      Self.timeZone
        )
        XCTAssertTrue(summary.hasEnoughData)
        let weekly = summary.weeklySummary
        XCTAssertNotNil(weekly)
        XCTAssertTrue(weekly!.contains("5 meals"))
        XCTAssertTrue(weekly!.contains("500"))
    }

    // MARK: - Most common foods ranking

    /// Top three by count, descending. A normalized food name with
    /// only one occurrence is filtered out (the surface intentionally
    /// hides solo foods).
    func test_mostCommonFoods_rankedByCount() {
        var logs: [FoodLog] = []
        logs += (1...4).map { Self.makeLog(name: "Kimchi stew", daysAgo: $0) }
        logs += (5...6).map { Self.makeLog(name: "Bibimbap",    daysAgo: $0) }
        logs += (7...9).map { Self.makeLog(name: "Latte",       daysAgo: $0) }
        logs += [Self.makeLog(name: "Steak", daysAgo: 10)] // only once, must be dropped

        let foods = FoodMirrorInsightService.mostCommonFoods(in: logs, limit: 3)
        XCTAssertEqual(foods.count, 3)
        XCTAssertEqual(foods[0].name, "Kimchi stew")
        XCTAssertEqual(foods[0].count, 4)
        XCTAssertEqual(foods[1].name, "Latte")
        XCTAssertEqual(foods[1].count, 3)
        XCTAssertEqual(foods[2].name, "Bibimbap")
        XCTAssertEqual(foods[2].count, 2)
        XCTAssertFalse(foods.contains { $0.name == "Steak" })
    }

    // MARK: - Timing insight: dinner > lunch

    /// 3 lunches at 600 kcal and 3 dinners at 900 kcal — the timing
    /// stats land in the "heavier dinners" branch and the copy
    /// mentions both averages.
    func test_timingInsight_dinnerHeavierThanLunch() {
        var logs: [FoodLog] = []
        logs += (1...3).map {
            Self.makeLog(name: "Lunch bowl",  daysAgo: $0, hour: 12, calories: 600)
        }
        logs += (4...6).map {
            Self.makeLog(name: "Dinner plate", daysAgo: $0, hour: 19, calories: 900)
        }
        let timing = FoodMirrorInsightService.timingInsight(
            in: logs, timeZone: Self.timeZone
        )
        XCTAssertNotNil(timing)
        XCTAssertEqual(timing!.lunchCount, 3)
        XCTAssertEqual(timing!.dinnerCount, 3)
        XCTAssertGreaterThan(timing!.dinnerAvgKcal, timing!.lunchAvgKcal * 1.25)
        XCTAssertTrue(timing!.copy.lowercased().contains("dinner"))
        XCTAssertTrue(timing!.copy.lowercased().contains("heavier"))
    }

    /// Only one log in the dinner bucket → timing insight stays nil.
    func test_timingInsight_tooFewDinners_returnsNil() {
        var logs: [FoodLog] = []
        logs += (1...3).map {
            Self.makeLog(name: "Lunch", daysAgo: $0, hour: 12, calories: 600)
        }
        logs += [Self.makeLog(name: "Dinner", daysAgo: 4, hour: 19, calories: 900)]
        let timing = FoodMirrorInsightService.timingInsight(
            in: logs, timeZone: Self.timeZone
        )
        XCTAssertNil(timing)
    }

    // MARK: - Mood insight thresholds

    /// 5 logs with mood = .loved, 5 with no mood → moodInsight
    /// surfaces a positive line. Total mood-labeled sample is 5 and
    /// dominance is 100%, well above the 60% floor.
    func test_moodInsight_dominantLovedSurfaces() {
        var logs: [FoodLog] = []
        logs += (1...5).map {
            Self.makeLog(name: "Salad", daysAgo: $0, mood: .loved)
        }
        logs += (6...10).map {
            Self.makeLog(name: "Soup", daysAgo: $0, mood: nil)
        }
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            now:           Self.now,
            timeZone:      Self.timeZone
        )
        XCTAssertNotNil(summary.moodInsight)
        XCTAssertTrue(summary.moodInsight!.lowercased().contains("good"))
    }

    /// Mood histogram split exactly 1/1/1 across three labels — total
    /// is at the threshold but no single mood dominates ≥ 60%, so the
    /// insight stays silent.
    func test_moodInsight_silentOnEvenSplit() {
        let logs = [
            Self.makeLog(name: "Apple",  daysAgo: 1, mood: .loved),
            Self.makeLog(name: "Banana", daysAgo: 2, mood: .fine),
            Self.makeLog(name: "Carrot", daysAgo: 3, mood: .tough),
            // pad to clear the 3-log floor without adding more mood
            Self.makeLog(name: "Date",   daysAgo: 4),
            Self.makeLog(name: "Egg",    daysAgo: 5)
        ]
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  logs,
            now:           Self.now,
            timeZone:      Self.timeZone
        )
        XCTAssertNil(summary.moodInsight)
    }

    // MARK: - Suggested experiment

    /// Heavier-dinner pattern → the experiment suggests a lighter
    /// dinner for 3 days. Time-boxed, gentle, no medical claims.
    func test_suggestedExperiment_lighterDinnerOnHeavyDinnerPattern() {
        var logs: [FoodLog] = []
        logs += (1...3).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0, hour: 12, calories: 600)
        }
        logs += (4...6).map {
            Self.makeLog(name: "Dinner", daysAgo: $0, hour: 19, calories: 900)
        }
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  logs,
            now:           Self.now,
            timeZone:      Self.timeZone
        )
        XCTAssertNotNil(summary.suggestedExperiment)
        let copy = summary.suggestedExperiment!.lowercased()
        XCTAssertTrue(copy.contains("lighter dinner"))
        XCTAssertTrue(copy.contains("3 days"))
        // No medical-sounding language.
        for forbidden in ["diagnose", "cure", "treat", "medical", "doctor"] {
            XCTAssertFalse(copy.contains(forbidden),
                           "Experiment copy must not mention '\(forbidden)'")
        }
    }

    // MARK: - Gemini independence

    /// Structural guard: the service's surface (input and output
    /// types) must not name `AnalyzeResponse` or any other Gemini-
    /// shaped type. The Food Mirror is a pure history summarizer; a
    /// future change that wires Gemini in here would break this test.
    func test_service_doesNotDependOnGeminiOrAnalyzeResponse() {
        // FoodMirrorSummary should have no field referencing Gemini /
        // analyze response surfaces.
        let summary = FoodMirrorSummary.empty
        let labels = Mirror(reflecting: summary).children.compactMap(\.label)
        let forbidden = ["analyzeResponse", "geminiAnalysis", "analysis",
                         "adjustedCalories", "correctedCalories"]
        for name in forbidden {
            XCTAssertFalse(labels.contains(name),
                           "FoodMirrorSummary must not carry a field named '\(name)'")
        }

        // And the summary should compile/run from a plain [FoodLog]
        // input — no AnalyzeResponse needed anywhere in the call site.
        let logs = (1...5).map { Self.makeLog(name: "X", daysAgo: $0) }
        _ = FoodMirrorInsightService.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(3)),
            now:           Self.now,
            timeZone:      Self.timeZone
        )
    }

    // MARK: - Helpers

    // MARK: - This Week Changed

    /// Both periods are below the 3-log floor → no comparison fires.
    /// The card must stay silent, not surface a guess.
    func test_thisWeekChanged_noInsightWhenPreviousWeekTooThin() {
        let current = (1...5).map {
            Self.makeLog(name: "Salad", daysAgo: $0, calories: 500)
        }
        let previous = [
            Self.makeLog(name: "Soup", daysAgo: 9, calories: 400)
        ]
        let line = FoodMirrorInsightService.thisWeekChangedInsight(
            currentWeek:  current,
            previousWeek: previous,
            timeZone:     Self.timeZone
        )
        XCTAssertNil(line)
    }

    /// 8% calorie shift sits well inside the ±20% band — silent.
    /// This is the primary "don't overclaim a flat week" guard.
    func test_thisWeekChanged_noInsightWhenChangeTooSmall() {
        let previous = (1...5).map {
            Self.makeLog(name: "Bowl", daysAgo: $0 + 7, calories: 500)
        }
        let current = (1...5).map {
            Self.makeLog(name: "Bowl", daysAgo: $0, calories: 540) // +8%
        }
        let line = FoodMirrorInsightService.thisWeekChangedInsight(
            currentWeek:  current,
            previousWeek: previous,
            timeZone:     Self.timeZone
        )
        XCTAssertNil(line)
    }

    /// Per-meal average fell ~25% (800 → 600). Expect a "lighter than
    /// last week" line that names a calorie delta, not a percentage.
    func test_thisWeekChanged_calorieDecreaseSurfaces() {
        let previous = (1...5).map {
            Self.makeLog(name: "Pasta", daysAgo: $0 + 7, calories: 800)
        }
        let current = (1...5).map {
            Self.makeLog(name: "Soup", daysAgo: $0, calories: 600)
        }
        let line = FoodMirrorInsightService.thisWeekChangedInsight(
            currentWeek:  current,
            previousWeek: previous,
            timeZone:     Self.timeZone
        )
        XCTAssertNotNil(line)
        let copy = line!.lowercased()
        XCTAssertTrue(copy.contains("lighter"))
        XCTAssertTrue(copy.contains("last week"))
    }

    /// Three heavy dinners last week (900 kcal each), three lighter
    /// ones this week (650 kcal each) → dinner-specific copy fires
    /// AND beats the generic kcal line in priority order.
    func test_thisWeekChanged_dinnerDecreaseSurfaces() {
        var previous: [FoodLog] = []
        previous += (1...3).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0 + 7, hour: 12, calories: 600)
        }
        previous += (1...3).map {
            Self.makeLog(name: "Dinner", daysAgo: $0 + 7, hour: 19, calories: 900)
        }
        var current: [FoodLog] = []
        current += (1...3).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0, hour: 12, calories: 600)
        }
        current += (1...3).map {
            Self.makeLog(name: "Dinner", daysAgo: $0, hour: 19, calories: 650)
        }
        let line = FoodMirrorInsightService.thisWeekChangedInsight(
            currentWeek:  current,
            previousWeek: previous,
            timeZone:     Self.timeZone
        )
        XCTAssertNotNil(line)
        let copy = line!.lowercased()
        XCTAssertTrue(copy.contains("dinner"))
        XCTAssertTrue(copy.contains("lighter"))
    }

    /// Same setup as the decrease case but the direction flips —
    /// dinner went 650 → 900. Direction must be "heavier" without
    /// any shame language.
    func test_thisWeekChanged_dinnerIncreaseSurfaces() {
        var previous: [FoodLog] = []
        previous += (1...3).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0 + 7, hour: 12, calories: 600)
        }
        previous += (1...3).map {
            Self.makeLog(name: "Dinner", daysAgo: $0 + 7, hour: 19, calories: 650)
        }
        var current: [FoodLog] = []
        current += (1...3).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0, hour: 12, calories: 600)
        }
        current += (1...3).map {
            Self.makeLog(name: "Dinner", daysAgo: $0, hour: 19, calories: 900)
        }
        let line = FoodMirrorInsightService.thisWeekChangedInsight(
            currentWeek:  current,
            previousWeek: previous,
            timeZone:     Self.timeZone
        )
        XCTAssertNotNil(line)
        let copy = line!.lowercased()
        XCTAssertTrue(copy.contains("dinner"))
        XCTAssertTrue(copy.contains("heavier"))
        XCTAssertFalse(copy.contains("too"))
        XCTAssertFalse(copy.contains("bad"))
    }

    /// 4 → 9 meals (+125%) clears both the absolute ≥3 and the ≥35%
    /// relative thresholds. Macros stay flat so the count signal is
    /// what surfaces — falling through dinner/calorie/protein/sugar
    /// priorities until logCount hits.
    func test_thisWeekChanged_loggingCountIncreaseSurfaces() {
        let previous = (1...4).map {
            Self.makeLog(name: "Snack",  daysAgo: $0 + 7,
                         calories: 300, sugarG: 5, proteinG: 8)
        }
        let current = (1...9).map {
            Self.makeLog(name: "Snack",  daysAgo: $0,
                         calories: 300, sugarG: 5, proteinG: 8)
        }
        let line = FoodMirrorInsightService.thisWeekChangedInsight(
            currentWeek:  current,
            previousWeek: previous,
            timeZone:     Self.timeZone
        )
        XCTAssertNotNil(line)
        let copy = line!.lowercased()
        XCTAssertTrue(copy.contains("more meals"))
        XCTAssertTrue(copy.contains("last"))
    }

    /// Sweep across every triggering scenario and make sure the
    /// generated copy never reaches for medical / shame language.
    /// This is a structural guard: if a future contributor adds a
    /// stricter line ("you ate too much sugar"), this test fails.
    func test_thisWeekChanged_neverUsesMedicalOrShameLanguage() {
        let forbidden = ["diagnose", "cure", "treat", "medical", "doctor",
                         "obese", "fat", "bad", "guilty", "shame",
                         "too much", "too many", "binge"]

        var candidates: [String] = []

        // Calorie down
        candidates.append(
            FoodMirrorInsightService.thisWeekChangedInsight(
                currentWeek:  (1...5).map {
                    Self.makeLog(name: "X", daysAgo: $0, calories: 500)
                },
                previousWeek: (1...5).map {
                    Self.makeLog(name: "X", daysAgo: $0 + 7, calories: 800)
                },
                timeZone: Self.timeZone
            ) ?? ""
        )
        // Calorie up
        candidates.append(
            FoodMirrorInsightService.thisWeekChangedInsight(
                currentWeek:  (1...5).map {
                    Self.makeLog(name: "X", daysAgo: $0, calories: 800)
                },
                previousWeek: (1...5).map {
                    Self.makeLog(name: "X", daysAgo: $0 + 7, calories: 500)
                },
                timeZone: Self.timeZone
            ) ?? ""
        )
        // Sugar up
        candidates.append(
            FoodMirrorInsightService.thisWeekChangedInsight(
                currentWeek:  (1...5).map {
                    Self.makeLog(name: "X", daysAgo: $0,
                                 calories: 500, sugarG: 30)
                },
                previousWeek: (1...5).map {
                    Self.makeLog(name: "X", daysAgo: $0 + 7,
                                 calories: 500, sugarG: 10)
                },
                timeZone: Self.timeZone
            ) ?? ""
        )

        for copy in candidates {
            let lower = copy.lowercased()
            for word in forbidden {
                XCTAssertFalse(lower.contains(word),
                               "Insight copy must not contain '\(word)' — got: '\(copy)'")
            }
        }
    }

    // MARK: - Today's gentle nudge

    /// Three logs is well under the nudge floor of 8 — must stay
    /// silent. The dinner pattern would qualify on its own, but we
    /// don't want to nudge from a thin window.
    func test_gentleNudge_nilWhenNotEnoughLogs() {
        let logs = [
            Self.makeLog(name: "Pasta", daysAgo: 1, hour: 19, calories: 900),
            Self.makeLog(name: "Salad", daysAgo: 1, hour: 12, calories: 400),
            Self.makeLog(name: "Pasta", daysAgo: 2, hour: 19, calories: 900),
        ]
        let timing = FoodMirrorInsightService.timingInsight(
            in: logs, timeZone: Self.timeZone
        )
        let nudge = FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: logs,
            sevenDayLogs:  logs,
            timing:        timing,
            timeZone:      Self.timeZone
        )
        XCTAssertNil(nudge)
    }

    /// Heavy dinners over 30 days AND the current week still trends
    /// heavy → lighter-dinner nudge surfaces with gentle wording.
    func test_gentleNudge_lighterDinnerWhenEveningsRunHeavy() {
        var thirtyDay: [FoodLog] = []
        thirtyDay += (1...10).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0, hour: 12, calories: 600)
        }
        thirtyDay += (1...10).map {
            Self.makeLog(name: "Dinner", daysAgo: $0, hour: 19, calories: 1000)
        }
        // Current-week slice: build directly from `daysAgo: 1...6` so
        // the window doesn't depend on `Calendar.current` timezone
        // (Self.timeZone is LA; the simulator's locale may differ and
        // miss-bucket the boundary).
        var sevenDay: [FoodLog] = []
        sevenDay += (1...6).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0, hour: 12, calories: 600)
        }
        sevenDay += (1...6).map {
            Self.makeLog(name: "Dinner", daysAgo: $0, hour: 19, calories: 1000)
        }
        let timing = FoodMirrorInsightService.timingInsight(
            in: thirtyDay, timeZone: Self.timeZone
        )
        let nudge = FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: thirtyDay,
            sevenDayLogs:  sevenDay,
            timing:        timing,
            timeZone:      Self.timeZone
        )
        XCTAssertNotNil(nudge)
        let copy = nudge!.lowercased()
        XCTAssertTrue(copy.contains("dinner"))
        XCTAssertTrue(copy.contains("lighter"))
        // Gentle, not bossy.
        XCTAssertTrue(copy.contains("try") || copy.contains("maybe") ||
                      copy.contains("if"))
    }

    /// Low protein average across the 30-day window (8g/meal) and the
    /// current week still low → protein nudge fires. Wording stays
    /// invitational ("Maybe make space for…").
    func test_gentleNudge_proteinWhenAverageLow() {
        let lowProteinLogs = (1...10).map {
            Self.makeLog(name: "Toast", daysAgo: $0,
                         calories: 400, proteinG: 8)
        }
        let nudge = FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: lowProteinLogs,
            sevenDayLogs:  Array(lowProteinLogs.prefix(5)),
            timing:        nil
        )
        XCTAssertNotNil(nudge)
        let copy = nudge!.lowercased()
        XCTAssertTrue(copy.contains("protein"))
        XCTAssertTrue(copy.contains("maybe") || copy.contains("try"))
    }

    /// High sugar average (30g/meal) over 30 days, current week also
    /// high → lower-sugar nudge surfaces with optional wording.
    func test_gentleNudge_sugarWhenTrendingHigh() {
        let highSugarLogs = (1...10).map {
            Self.makeLog(name: "Dessert", daysAgo: $0,
                         calories: 500, sugarG: 30, proteinG: 25)
        }
        let nudge = FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: highSugarLogs,
            sevenDayLogs:  Array(highSugarLogs.prefix(5)),
            timing:        nil
        )
        XCTAssertNotNil(nudge)
        let copy = nudge!.lowercased()
        XCTAssertTrue(copy.contains("sugar"))
        // Optional framing — "if today's an option…" style.
        XCTAssertTrue(copy.contains("if") || copy.contains("might"))
    }

    /// One food repeatedly marked .loved with no .tough reports
    /// surfaces a positive mood-linked food nudge naming that food.
    func test_gentleNudge_positiveMoodLinkedFood() {
        var logs: [FoodLog] = []
        // Make 10 logs so we clear the 8-log floor and keep dinner
        // pattern flat (noon meals only) so it doesn't preempt.
        logs += (1...3).map {
            Self.makeLog(name: "Salmon Bowl", daysAgo: $0,
                         hour: 12, calories: 600,
                         proteinG: 35, mood: .loved)
        }
        logs += (4...10).map {
            Self.makeLog(name: "Toast", daysAgo: $0,
                         hour: 12, calories: 500,
                         sugarG: 6, proteinG: 25)
        }
        let nudge = FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            timing:        nil
        )
        XCTAssertNotNil(nudge)
        let copy = nudge!.lowercased()
        XCTAssertTrue(copy.contains("salmon bowl"))
        XCTAssertTrue(copy.contains("work well"))
    }

    /// Sweep across every triggering branch and confirm the copy
    /// never reaches for medical, shame, or bossy language. Same
    /// structural guard pattern as the thisWeekChanged sweep.
    func test_gentleNudge_neverUsesShameOrMedicalLanguage() {
        let forbidden = ["diagnose", "cure", "treat", "medical", "doctor",
                         "must", "should", "have to", "need to",
                         "stop", "don't", "do not",
                         "fat", "obese", "bad", "guilty", "shame",
                         "too much", "binge"]

        var candidates: [String] = []

        // Lighter dinner branch
        var dinnerLogs: [FoodLog] = []
        dinnerLogs += (1...10).map {
            Self.makeLog(name: "Lunch",  daysAgo: $0, hour: 12, calories: 600)
        }
        dinnerLogs += (1...10).map {
            Self.makeLog(name: "Dinner", daysAgo: $0, hour: 19, calories: 1000)
        }
        candidates.append(FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: dinnerLogs,
            sevenDayLogs:  dinnerLogs,
            timing:        FoodMirrorInsightService.timingInsight(
                in: dinnerLogs, timeZone: Self.timeZone
            )
        ) ?? "")

        // Protein branch
        let lowProtein = (1...10).map {
            Self.makeLog(name: "Toast", daysAgo: $0, calories: 400, proteinG: 8)
        }
        candidates.append(FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: lowProtein,
            sevenDayLogs:  Array(lowProtein.prefix(5)),
            timing:        nil
        ) ?? "")

        // Sugar branch
        let highSugar = (1...10).map {
            Self.makeLog(name: "Dessert", daysAgo: $0,
                         calories: 500, sugarG: 30, proteinG: 25)
        }
        candidates.append(FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: highSugar,
            sevenDayLogs:  Array(highSugar.prefix(5)),
            timing:        nil
        ) ?? "")

        // Mood-linked branch
        var moodLogs: [FoodLog] = []
        moodLogs += (1...3).map {
            Self.makeLog(name: "Salmon Bowl", daysAgo: $0,
                         hour: 12, calories: 600, proteinG: 35, mood: .loved)
        }
        moodLogs += (4...10).map {
            Self.makeLog(name: "Toast", daysAgo: $0,
                         hour: 12, calories: 500, sugarG: 6, proteinG: 25)
        }
        candidates.append(FoodMirrorInsightService.todaysGentleNudge(
            thirtyDayLogs: moodLogs,
            sevenDayLogs:  Array(moodLogs.prefix(5)),
            timing:        nil
        ) ?? "")

        for copy in candidates {
            let lower = copy.lowercased()
            for word in forbidden {
                XCTAssertFalse(lower.contains(word),
                               "Nudge copy must not contain '\(word)' — got: '\(copy)'")
            }
        }
    }

    // MARK: - Learning progress

    /// Zero logs → `.empty` state, "X of 8" displays 0, and the
    /// summary still carries the headline/explanation so the view
    /// can render a complete card without a back-fill default.
    func test_learningProgress_zeroLogs() {
        let progress = LearningProgress.from(thirtyDayLogCount: 0)
        XCTAssertEqual(progress.state, .empty)
        XCTAssertEqual(progress.mealsLoggedInWindow, 0)
        XCTAssertEqual(progress.target, 8)
        XCTAssertEqual(progress.progressText, "0 of 8 meals logged")
        XCTAssertTrue(progress.state.headline.lowercased().contains("first meal"))
    }

    /// 1–2 logs → `.starting`. Singular/plural in the progress text
    /// should switch on the count, not stay locked to "meals."
    func test_learningProgress_oneToTwoLogs() {
        let oneLog = LearningProgress.from(thirtyDayLogCount: 1)
        XCTAssertEqual(oneLog.state, .starting)
        XCTAssertEqual(oneLog.progressText, "1 of 8 meal logged")

        let twoLogs = LearningProgress.from(thirtyDayLogCount: 2)
        XCTAssertEqual(twoLogs.state, .starting)
        XCTAssertEqual(twoLogs.progressText, "2 of 8 meals logged")
    }

    /// 3–7 logs → `.formingPatterns`. Boundary check at 3 and 7.
    func test_learningProgress_threeToSevenLogs() {
        for n in 3...7 {
            let progress = LearningProgress.from(thirtyDayLogCount: n)
            XCTAssertEqual(progress.state, .formingPatterns, "count=\(n)")
            XCTAssertEqual(progress.mealsLoggedInWindow, n)
            XCTAssertEqual(progress.progressText, "\(n) of 8 meals logged")
        }
    }

    /// 8+ logs → `.ready`. The full compute() pipeline should mark
    /// the summary as having enough data and surface insights for a
    /// well-populated 30-day window.
    func test_learningProgress_eightOrMoreLogsUsesNormalInsights() {
        let logs = (1...10).map {
            Self.makeLog(name: "Bowl", daysAgo: $0, calories: 500)
        }
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            now:           Self.now,
            timeZone:      Self.timeZone
        )
        XCTAssertEqual(summary.learningProgress.state, .ready)
        XCTAssertTrue(summary.hasEnoughData)
        // At least one piece of regular insight content should land
        // with this many logs.
        XCTAssertNotNil(summary.weeklySummary)
        XCTAssertTrue(summary.hasAnyContent)
    }

    /// Progress count clamps at the target (8). 50 logs still reads
    /// as "8 of 8" so the view's progress bar can't ever overflow.
    func test_learningProgress_countClampsAtTarget() {
        let huge = LearningProgress.from(thirtyDayLogCount: 50)
        XCTAssertEqual(huge.state, .ready)
        XCTAssertEqual(huge.mealsLoggedInWindow, 8)
        XCTAssertEqual(huge.target, 8)
        XCTAssertEqual(huge.progressText, "8 of 8 meals logged")
    }

    /// Builds a synthetic FoodLog at `daysAgo` days before `Self.now`,
    /// pinned to `hour:00:00` in the test timezone. Defaults give a
    /// noon meal with neutral calories so individual tests only need
    /// to override what they care about.
    private static func makeLog(name: String,
                                daysAgo: Int,
                                hour: Int = 12,
                                calories: Double = 500,
                                carbsG: Double = 50,
                                sugarG: Double = 5,
                                proteinG: Double? = 20,
                                fatG: Double? = 15,
                                fiberG: Double? = 5,
                                mood: FoodLog.Mood? = nil) -> FoodLog {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = 0
        comps.timeZone = timeZone
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: calories,
            carbsG: carbsG,
            sugarG: sugarG,
            proteinG: proteinG,
            fatG: fatG,
            fiberG: fiberG,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: dt,
            createdAt: dt,
            origin: .analyzed,
            sourceLogId: nil,
            mood: mood
        )
    }
}

// MARK: - FoodMirrorPresentation
//
// Pure helpers for the Mirror's evidence + freshness captions.
// These are presentational only — they never gate behavior or change
// what's saved. Tests exercise the wording rules in isolation so
// future copy tweaks land here rather than as a manual QA pass.

final class FoodMirrorPresentationTests: XCTestCase {

    // MARK: - Evidence line

    /// Zero meals → nil. The learning-state card already tells the
    /// user we don't have enough data; an evidence caption would
    /// just say the same thing in a quieter voice.
    func test_evidenceLine_zeroMeals_returnsNil() {
        let summary = Self.makeSummary(thirtyDayLogCount: 0, moodLogCount: 0)
        XCTAssertNil(FoodMirrorPresentation.evidenceLine(for: summary))
    }

    /// Meal-only branch (no mood notes): cites the count with the
    /// "logged" suffix and pluralizes correctly.
    func test_evidenceLine_mealsOnlyPastReadinessFloor() {
        let summary = Self.makeSummary(thirtyDayLogCount: 8, moodLogCount: 0)
        XCTAssertEqual(
            FoodMirrorPresentation.evidenceLine(for: summary),
            "Based on 8 meals logged."
        )
    }

    /// Combined branch: meals + mood notes. Both nouns pluralized
    /// when the count is plural; the line stays a single sentence.
    func test_evidenceLine_mealsAndMoodNotes() {
        let summary = Self.makeSummary(thirtyDayLogCount: 12, moodLogCount: 5)
        XCTAssertEqual(
            FoodMirrorPresentation.evidenceLine(for: summary),
            "Based on 12 meals and 5 mood notes."
        )
    }

    /// 30-day branch: at 20+ meals we can claim the full window. With
    /// mood notes present the line names both substrates.
    func test_evidenceLine_thirtyDayWithMoodNotes() {
        let summary = Self.makeSummary(thirtyDayLogCount: 30, moodLogCount: 8)
        XCTAssertEqual(
            FoodMirrorPresentation.evidenceLine(for: summary),
            "Based on 30 days of meals and 8 mood notes."
        )
    }

    /// 30-day branch with no mood notes drops the mood clause rather
    /// than emitting "and 0 mood notes."
    func test_evidenceLine_thirtyDayNoMoodNotes() {
        let summary = Self.makeSummary(thirtyDayLogCount: 25, moodLogCount: 0)
        XCTAssertEqual(
            FoodMirrorPresentation.evidenceLine(for: summary),
            "Based on 30 days of meals."
        )
    }

    /// Thin window (3–7 meals) gets a soft "your recent meals" line
    /// — honest but not overclaiming any count.
    func test_evidenceLine_thinWindowFallsBackToGeneric() {
        let summary = Self.makeSummary(thirtyDayLogCount: 4, moodLogCount: 1)
        XCTAssertEqual(
            FoodMirrorPresentation.evidenceLine(for: summary),
            "Based on your recent meals."
        )
    }

    // MARK: - Freshness line

    /// Nil `updatedAt` means we've never completed a refresh in this
    /// session; the caption hides entirely instead of inventing a
    /// placeholder. Avoids "Updated never" or similar misfires.
    func test_freshnessLine_nilUpdatedAt_returnsNil() {
        XCTAssertNil(FoodMirrorPresentation.freshnessLine(updatedAt: nil))
    }

    /// Under a minute → "Updated just now". Boundary check at 0s and
    /// just under 60s; both must read the same.
    func test_freshnessLine_justNow() {
        let now = Date()
        XCTAssertEqual(
            FoodMirrorPresentation.freshnessLine(updatedAt: now, now: now),
            "Updated just now"
        )
        XCTAssertEqual(
            FoodMirrorPresentation.freshnessLine(
                updatedAt: now.addingTimeInterval(-59), now: now
            ),
            "Updated just now"
        )
    }

    /// 1–59 minutes → "Updated N min ago". Confirms the floor at 1
    /// min (60s exactly) and a mid-range value (5 min).
    func test_freshnessLine_minutesAgo() {
        let now = Date()
        XCTAssertEqual(
            FoodMirrorPresentation.freshnessLine(
                updatedAt: now.addingTimeInterval(-60), now: now
            ),
            "Updated 1 min ago"
        )
        XCTAssertEqual(
            FoodMirrorPresentation.freshnessLine(
                updatedAt: now.addingTimeInterval(-5 * 60), now: now
            ),
            "Updated 5 min ago"
        )
    }

    /// 1+ hour but same calendar day → "Updated today". Use a fixed
    /// calendar so the rollover is deterministic regardless of
    /// machine timezone.
    func test_freshnessLine_sameDayBeyondAnHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 21
        comps.hour = 15
        comps.timeZone = cal.timeZone
        let now = cal.date(from: comps)!

        comps.hour = 8
        let updated = cal.date(from: comps)!

        XCTAssertEqual(
            FoodMirrorPresentation.freshnessLine(
                updatedAt: updated, now: now, calendar: cal
            ),
            "Updated today"
        )
    }

    /// Updated yesterday relative to a pinned `now`. Calendar-aware
    /// (not "24h ago") so a refresh at 11pm last night still reads
    /// "yesterday" from this morning, not "20 hours ago."
    func test_freshnessLine_yesterday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 21
        comps.hour = 9; comps.timeZone = cal.timeZone
        let now = cal.date(from: comps)!

        comps.day = 20
        comps.hour = 23
        let updated = cal.date(from: comps)!

        XCTAssertEqual(
            FoodMirrorPresentation.freshnessLine(
                updatedAt: updated, now: now, calendar: cal
            ),
            "Updated yesterday"
        )
    }

    // MARK: - Summary populates the new counts

    /// `compute(...)` must populate `sevenDayLogCount` /
    /// `moodLogCount` so the presentation helper has real numbers
    /// to format. Regression guard if someone adds a future field
    /// and forgets to initialize one of these.
    func test_compute_populatesSevenDayAndMoodCounts() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let tz = TimeZone(identifier: "America/Los_Angeles")!

        let sevenDay = (1...4).map {
            Self.makeLog(name: "Bowl", daysAgo: $0, mood: $0 % 2 == 0 ? .loved : nil)
        }
        let thirtyDay = sevenDay + (8...12).map {
            Self.makeLog(name: "Soup", daysAgo: $0, mood: .fine)
        }
        let summary = FoodMirrorInsightService.compute(
            thirtyDayLogs: thirtyDay,
            sevenDayLogs:  sevenDay,
            now:           now,
            timeZone:      tz
        )
        XCTAssertEqual(summary.sevenDayLogCount, 4)
        XCTAssertEqual(summary.moodLogCount, 7)
    }

    // MARK: - Helpers

    private static func makeSummary(thirtyDayLogCount: Int,
                                    moodLogCount: Int) -> FoodMirrorSummary {
        FoodMirrorSummary(
            hasEnoughData:       thirtyDayLogCount >= 8,
            learningProgress:    LearningProgress.from(thirtyDayLogCount: thirtyDayLogCount),
            thirtyDayLogCount:   thirtyDayLogCount,
            sevenDayLogCount:    0,
            moodLogCount:        moodLogCount,
            eatingIdentity:      nil,
            weeklySummary:       nil,
            mostCommonFoods:     [],
            moodInsight:         nil,
            timingInsight:       nil,
            thisWeekChanged:     nil,
            todaysGentleNudge:   nil,
            suggestedExperiment: nil
        )
    }

    private static func makeLog(name: String,
                                daysAgo: Int,
                                mood: FoodLog.Mood? = nil) -> FoodLog {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let base = Date(timeIntervalSince1970: 1_730_000_000)
        let day = cal.date(byAdding: .day, value: -daysAgo, to: base) ?? base
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = 12; comps.minute = 0; comps.timeZone = tz
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: 500,
            carbsG: 50,
            sugarG: 5,
            proteinG: 20,
            fatG: 15,
            fiberG: 5,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: dt,
            createdAt: dt,
            origin: .analyzed,
            sourceLogId: nil,
            mood: mood
        )
    }
}

// MARK: - FoodMirrorViewModel — production refresh behavior
//
// These tests exercise the cancellation, last-good-state, and
// refresh-token guarantees that keep the Mirror calm under bad
// network and rapid event bursts. A small stub fetcher stands in
// for the Supabase-backed FoodLogService so the VM's behavior can
// be tested without a live network.

@MainActor
final class FoodMirrorViewModelTests: XCTestCase {

    /// Stub that returns canned `[FoodLog]` or throws on demand.
    /// `delay` lets a test slow a single response down to simulate
    /// races between overlapping refreshes.
    final class StubFetcher: FoodLogsFetching, @unchecked Sendable {
        var result: Result<[FoodLog], Error> = .success([])
        var delay: Duration = .zero
        var calls: Int = 0

        func logs(from: Date, to: Date) async throws -> [FoodLog] {
            calls += 1
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            switch result {
            case .success(let logs): return logs
            case .failure(let err):  throw err
            }
        }
    }

    struct StubError: Error {}

    // MARK: cancellation never sets failed

    /// Stub throws CancellationError → state stays where it was
    /// before the refresh started. No "Couldn't load your mirror"
    /// card, no transient banner.
    func test_cancellation_doesNotSetFailed() async {
        let stub = StubFetcher()
        stub.result = .failure(CancellationError())
        let vm = FoodMirrorViewModel(foodLogs: stub)

        await vm.refresh()

        if case .failed = vm.state {
            XCTFail("CancellationError must not set .failed; got \(vm.state)")
        }
        XCTAssertNil(vm.refreshErrorMessage)
    }

    // MARK: failed refresh with previous content preserves content

    /// First refresh succeeds → `.loaded`. Second refresh throws a
    /// real error → state stays `.loaded` and `refreshErrorMessage`
    /// holds the soft, user-facing copy.
    func test_failedRefresh_preservesPreviousLoadedContent() async {
        let stub = StubFetcher()
        stub.result = .success(Self.makeLogs(count: 12))
        let vm = FoodMirrorViewModel(foodLogs: stub)

        await vm.refresh()
        guard case .loaded = vm.state else {
            return XCTFail("Expected initial .loaded; got \(vm.state)")
        }
        let previous = vm.state

        stub.result = .failure(StubError())
        await vm.refresh()

        XCTAssertEqual(vm.state, previous,
                       "Real failure must preserve previous loaded content")
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertNotNil(vm.refreshErrorMessage)
        XCTAssertEqual(vm.refreshErrorMessage,
                       "Couldn't refresh. Showing your latest saved mirror.")
    }

    /// First-load failure with no prior content surfaces the full
    /// failed card (the banner path is reserved for surfaces that
    /// already have something to show).
    func test_firstLoadFailure_setsFailedNotBanner() async {
        let stub = StubFetcher()
        stub.result = .failure(StubError())
        let vm = FoodMirrorViewModel(foodLogs: stub)

        await vm.refresh()

        if case .failed = vm.state {} else {
            XCTFail("Expected .failed on first-load failure; got \(vm.state)")
        }
        XCTAssertNil(vm.refreshErrorMessage,
                     "Banner is only used when prior content is visible")
    }

    /// Successful refresh clears any prior banner — recovery should
    /// not leave a stale "couldn't refresh" line on screen.
    func test_successfulRefresh_clearsBannerAndStampsLastUpdated() async {
        let stub = StubFetcher()
        stub.result = .success(Self.makeLogs(count: 12))
        let vm = FoodMirrorViewModel(foodLogs: stub)

        await vm.refresh()
        stub.result = .failure(StubError())
        await vm.refresh()
        XCTAssertNotNil(vm.refreshErrorMessage)

        stub.result = .success(Self.makeLogs(count: 12))
        await vm.refresh()

        XCTAssertNil(vm.refreshErrorMessage)
        XCTAssertNotNil(vm.lastUpdatedAt)
    }

    // MARK: older refresh cannot overwrite newer

    /// Token guard: a slow first refresh must not commit on top of a
    /// fast second refresh. We use a thread-safe counting fetcher
    /// where the first two `logs()` calls (refresh #1's seven-day +
    /// thirty-day pair) sleep before returning "Old", while every
    /// subsequent call (refresh #2 onward) returns "New"
    /// immediately. After both refreshes complete, the surface
    /// must show "New" — refresh #1's older payload was discarded.
    func test_olderRefreshDoesNotOverwriteNewer() async {
        let stub = SlowFirstPairFetcher(
            firstPairDelay: .milliseconds(200),
            firstPairName:  "Old",
            laterName:      "New"
        )
        let vm = FoodMirrorViewModel(foodLogs: stub)

        async let first: Void = vm.refresh()
        // Let refresh #1 begin its sleep so refresh #2 starts during
        // that window — otherwise the test would just be serializing
        // two back-to-back fetches.
        try? await Task.sleep(for: .milliseconds(40))
        async let second: Void = vm.refresh()
        _ = await (first, second)

        guard case .loaded(let summary) = vm.state else {
            return XCTFail("Expected .loaded; got \(vm.state)")
        }
        XCTAssertTrue(
            summary.mostCommonFoods.contains { $0.name == "New" },
            "Newer refresh result must win the commit race"
        )
        XCTAssertFalse(
            summary.mostCommonFoods.contains { $0.name == "Old" },
            "Older refresh's payload must not appear in committed state"
        )
    }

    // MARK: revelation freshness

    /// The app caller passes the current revelation's repeat key
    /// into the next engine refresh. With identical logs, the second
    /// refresh must fall through to a calmer non-revelation moment
    /// instead of showing the same subject again.
    func test_refresh_doesNotRepeatSameRevelationBackToBack() async {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let stub = StubFetcher()
        stub.result = .success(Self.makeRevelationLogs(now: now,
                                                       timeZone: tz))
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let vm = FoodMirrorViewModel(foodLogs: stub,
                                     feedbackStore: store)

        await vm.refresh(now: now, timeZone: tz)
        XCTAssertEqual(vm.currentMoment?.kind, .revelation)
        XCTAssertEqual(vm.currentMoment?.revelationRepeatKey,
                       "timeOfDay:morning")

        await vm.refresh(now: now.addingTimeInterval(60), timeZone: tz)
        XCTAssertNotEqual(vm.currentMoment?.kind, .revelation)
    }

    // MARK: helpers

    private func tempStoreURL(named: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoodMirrorViewModelTests", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let slug = named
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return dir.appendingPathComponent(
            "store_\(slug)_\(UUID().uuidString).json"
        )
    }

    /// Thread-safe stub: first two `logs(from:to:)` calls sleep
    /// then return logs named `firstPairName`; every call after
    /// returns `laterName` immediately. The single lock around
    /// `callCount` keeps the two concurrent `async let` fetches
    /// from racing the counter.
    final class SlowFirstPairFetcher: FoodLogsFetching, @unchecked Sendable {
        private let firstPairDelay: Duration
        private let firstPairName: String
        private let laterName: String
        private let lock = NSLock()
        private var callCount = 0

        init(firstPairDelay: Duration,
             firstPairName: String,
             laterName: String) {
            self.firstPairDelay = firstPairDelay
            self.firstPairName  = firstPairName
            self.laterName      = laterName
        }

        func logs(from: Date, to: Date) async throws -> [FoodLog] {
            lock.lock()
            callCount += 1
            let myCall = callCount
            lock.unlock()
            if myCall <= 2 {
                try await Task.sleep(for: firstPairDelay)
                return FoodMirrorViewModelTests.makeLogs(
                    count: 12, name: firstPairName
                )
            }
            return FoodMirrorViewModelTests.makeLogs(
                count: 12, name: laterName
            )
        }
    }

    /// Build N synthetic logs across N distinct days at noon LA, all
    /// with the same food name so "most common foods" surfaces it
    /// (the filter requires ≥ 2 occurrences). Nonisolated so the
    /// background-actor stubs can call it without an actor hop.
    nonisolated static func makeLogs(count: Int, name: String = "Bowl") -> [FoodLog] {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let base = Date()
        var out: [FoodLog] = []
        for i in 0..<count {
            let day = cal.date(byAdding: .day, value: -i, to: base) ?? base
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = 12; comps.minute = 0; comps.timeZone = tz
            let dt = cal.date(from: comps) ?? day
            out.append(FoodLog(
                id: UUID(),
                userId: UUID(),
                foodName: name,
                imagePath: nil,
                imageThumbPath: nil,
                calories: 500,
                carbsG: 50,
                sugarG: 5,
                proteinG: 20,
                fatG: 15,
                fiberG: 5,
                benefits: [],
                drawbacks: [],
                nutrients: [],
                coachName: nil,
                coachAdvice: nil,
                eatenAt: dt,
                createdAt: dt,
                origin: .analyzed,
                sourceLogId: nil,
                mood: nil
            ))
        }
        return out
    }

    nonisolated static func makeRevelationLogs(now: Date,
                                               timeZone: TimeZone) -> [FoodLog] {
        var logs: [FoodLog] = []
        logs += (1...4).map {
            makeLog(name: "Morning \($0)", daysAgo: $0,
                    hour: 8, mood: .loved,
                    now: now, timeZone: timeZone)
        }
        logs += (5...12).map {
            makeLog(name: "Other \($0)", daysAgo: $0,
                    hour: 12, mood: .tough,
                    now: now, timeZone: timeZone)
        }
        return logs
    }

    nonisolated private static func makeLog(name: String,
                                            daysAgo: Int,
                                            hour: Int,
                                            mood: FoodLog.Mood?,
                                            now: Date,
                                            timeZone: TimeZone) -> FoodLog {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = 0; comps.timeZone = timeZone
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: 500,
            carbsG: 50,
            sugarG: 5,
            proteinG: 20,
            fatG: 15,
            fiberG: 5,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: dt,
            createdAt: dt,
            origin: .analyzed,
            sourceLogId: nil,
            mood: mood
        )
    }
}

// MARK: - HomeMirrorPreviewViewModel — preserves card on error

@MainActor
final class HomeMirrorPreviewViewModelTests: XCTestCase {

    /// First refresh succeeds → cardModel populated. Second refresh
    /// throws a real network error → cardModel must stay populated
    /// (Home should never flicker over a transient blip).
    func test_homePreview_keepsCardOnTransientError() async {
        let stub = FoodMirrorViewModelTests.StubFetcher()
        stub.result = .success(FoodMirrorViewModelTests.makeLogs(count: 12))
        let vm = HomeMirrorPreviewViewModel(foodLogs: stub)

        await vm.refresh()
        XCTAssertNotNil(vm.cardModel, "First refresh should populate")
        let snapshot = vm.cardModel

        stub.result = .failure(FoodMirrorViewModelTests.StubError())
        await vm.refresh()

        XCTAssertEqual(vm.cardModel, snapshot,
                       "Transient error must not blank the Home preview")
    }

    /// Cancellation must be silent — no log spam (we can't assert
    /// the NSLog directly, but we can confirm the existing card is
    /// preserved). Same guard as transient error, just via the
    /// CancellationError path.
    func test_homePreview_cancellationIsSilent() async {
        let stub = FoodMirrorViewModelTests.StubFetcher()
        stub.result = .success(FoodMirrorViewModelTests.makeLogs(count: 12))
        let vm = HomeMirrorPreviewViewModel(foodLogs: stub)

        await vm.refresh()
        let snapshot = vm.cardModel

        stub.result = .failure(CancellationError())
        await vm.refresh()

        XCTAssertEqual(vm.cardModel, snapshot,
                       "Cancellation must not blank the Home preview")
    }
}

// MARK: - FoodOS Moment Engine
//
// FoodOS Moment Engine V1 — the pure local intelligence layer that
// picks ONE useful personal moment per refresh. These tests live in
// XCTest (not Swift Testing) so they share the existing fixtures
// and don't introduce a new test framework into the project.
//
// Contract under test:
//   1. Under the 8-log readiness floor → learning moment.
//   2. At 8+ logs the engine can return a non-learning moment.
//   3. Mood posterior reads loved + fine as positive, tough as
//      negative, and adds a Beta(1, 1) prior so tiny samples don't
//      look certain.
//   4. Mood claims require ≥ 3 mood notes.
//   5. Slot claims require ≥ 3 logs in the slot.
//   6. Week-change claims require a meaningful delta.
//   7. Recognition needs a food to repeat ≥ 3 times.
//   8. Attention ranks the same food higher than unrelated ones.
//   9. Attention ranks same-slot logs higher than off-slot ones.
//  10. Attention ranks recent logs higher than older ones.
//  11. Copy safety rejects shame / medical / bossy / certainty.
//  12. Every produced moment carries an evidenceLine when it makes
//      a personal claim (i.e., non-fallback branches).
//  13. The engine is deterministic for the same input.
//  14. The fallback fires when evidence is thin but data clears
//      the readiness floor.

final class FoodOSMomentEngineTests: XCTestCase {

    private static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    /// Pinned "now" so date windows in the helpers are stable.
    private static let now = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: 1. learning under 8 logs

    /// Five logs is below the readiness floor → the engine must
    /// return the learning moment, regardless of how varied the
    /// log shapes look.
    func test_learning_returnedUnderEightLogs() {
        let logs = (1...5).map {
            Self.makeLog(name: "Bowl", daysAgo: $0, calories: 500)
        }
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         logs,
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertEqual(moment.kind, .learning)
        XCTAssertTrue(moment.title.lowercased().contains("still learning"))
        XCTAssertEqual(moment.evidenceLine, "Based on 5 meals logged.")
        XCTAssertEqual(moment.confidence, .low)
    }

    // MARK: 2. eight+ logs can yield non-learning moment

    /// At 8+ logs with a clear recognition signal (one food
    /// appearing repeatedly) the engine must escape the learning
    /// branch. The exact branch chosen depends on the priority
    /// chain — recognition is one outcome; anything non-learning
    /// passes this test.
    func test_eightOrMoreLogs_canReturnNonLearning() {
        let logs = (1...10).map {
            Self.makeLog(name: "Kimchi stew", daysAgo: $0, calories: 500)
        }
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertNotEqual(moment.kind, .learning,
                          "Engine must escape learning once ≥ 8 logs exist")
    }

    // MARK: 3. mood posterior

    /// Beta(1, 1) prior keeps a 3/0 sample below 1.0 and an
    /// even 1/1 split close to 0.5 — proves the prior is doing its
    /// job and the engine never claims certainty from a small
    /// sample.
    func test_moodPosterior_betaPriorPreventsCertainty() {
        // 3 loved + 0 tough → posterior = (3+1) / (3+0+2) = 4/5 = 0.8
        let mostlyLoved = [
            Self.makeLog(name: "X", daysAgo: 1, mood: .loved),
            Self.makeLog(name: "X", daysAgo: 2, mood: .loved),
            Self.makeLog(name: "X", daysAgo: 3, mood: .loved),
        ]
        let belief1 = FoodOSBeliefEngine.moodBelief(in: mostlyLoved)
        XCTAssertEqual(belief1.posteriorPositiveMean, 0.8, accuracy: 0.0001)
        XCTAssertLessThan(belief1.posteriorPositiveMean, 1.0)

        // 1 loved + 1 tough → posterior = 2 / 4 = 0.5
        let split = [
            Self.makeLog(name: "X", daysAgo: 1, mood: .loved),
            Self.makeLog(name: "X", daysAgo: 2, mood: .tough),
        ]
        let belief2 = FoodOSBeliefEngine.moodBelief(in: split)
        XCTAssertEqual(belief2.posteriorPositiveMean, 0.5, accuracy: 0.0001)

        // 0 mood reports → posterior = 1/2 = 0.5 (uninformative)
        let none = [Self.makeLog(name: "X", daysAgo: 1, mood: nil)]
        let belief3 = FoodOSBeliefEngine.moodBelief(in: none)
        XCTAssertEqual(belief3.total, 0)
        XCTAssertEqual(belief3.posteriorPositiveMean, 0.5, accuracy: 0.0001)
    }

    // MARK: 4. mood claim requires enough notes

    /// Two mood-labeled logs is under the 3-note floor — even
    /// though both are .loved, the mood reflection branch must NOT
    /// fire. The engine falls through to a different (or fallback)
    /// branch.
    func test_moodClaim_requiresAtLeastThreeNotes() {
        var logs: [FoodLog] = (1...10).map {
            Self.makeLog(name: "Bowl", daysAgo: $0, calories: 500)
        }
        // Two mood notes both .loved — under the 3-note floor.
        logs[0] = Self.makeLog(name: "Bowl", daysAgo: 1,
                               calories: 500, mood: .loved)
        logs[1] = Self.makeLog(name: "Bowl", daysAgo: 2,
                               calories: 500, mood: .loved)
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        // The mood title is "Most recent meals have felt steady" /
        // "Some recent meals have felt tougher." Confirm neither
        // surfaces with only 2 notes.
        XCTAssertFalse(moment.title.lowercased().contains("felt steady"))
        XCTAssertFalse(moment.title.lowercased().contains("felt tougher"))
    }

    // MARK: 5. slot claim requires enough samples

    /// Slot-stats helper must require ≥ 3 logs in a slot. Two
    /// dinners isn't enough to call dinner a pattern.
    func test_slotStats_requireMinimumSamples() {
        let logs = [
            Self.makeLog(name: "Dinner", daysAgo: 1, hour: 19, calories: 900),
            Self.makeLog(name: "Dinner", daysAgo: 2, hour: 19, calories: 900),
        ]
        let stats = FoodOSBeliefEngine.slotStats(
            in: logs, slot: .dinner, timeZone: Self.timeZone
        )
        XCTAssertEqual(stats.count, 2)
        XCTAssertFalse(stats.hasEnoughEvidence,
                       "Two dinners must not pass the slot floor")
    }

    // MARK: 6. this-week change requires meaningful difference

    /// An 8% calorie shift across two well-populated weeks must
    /// not surface a change moment — that's well inside the ±20%
    /// band the engine treats as "about the same."
    func test_change_silentWhenShiftIsTooSmall() {
        let previous = (1...5).map {
            Self.makeLog(name: "Bowl", daysAgo: $0 + 7,
                         hour: 12, calories: 500)
        }
        let current = (1...5).map {
            Self.makeLog(name: "Bowl", daysAgo: $0,
                         hour: 12, calories: 540) // +8%
        }
        let thirtyDay = previous + current + (15...20).map {
            Self.makeLog(name: "Bowl", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs:        thirtyDay,
            sevenDayLogs:         current,
            previousSevenDayLogs: previous,
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertNotEqual(moment.kind, .change,
                          "8% shift must not trigger a change moment")
    }

    // MARK: 7. recognition requires repeats

    /// Solo foods don't qualify as recognition. With every name
    /// unique, the engine must NOT fire the recognition branch —
    /// even with 12 well-populated logs.
    func test_recognition_silentOnNoRepeats() {
        let logs = (1...12).map {
            Self.makeLog(name: "Food \($0)", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertNotEqual(moment.kind, .recognition)
    }

    // MARK: 8. attention ranks same food higher

    /// A query for "Kimchi stew" against a mixed candidate set
    /// must surface the matching food ahead of unrelated dishes,
    /// even when the unrelated ones are more recent.
    func test_attention_ranksSameFoodHigher() {
        // The kimchi log is older (5 days ago) but matches by name.
        // The pizza log is recent (1 day) but doesn't match.
        let kimchi = Self.makeLog(name: "Kimchi stew", daysAgo: 5,
                                  hour: 19, calories: 500)
        let pizza  = Self.makeLog(name: "Pizza", daysAgo: 1,
                                  hour: 19, calories: 500)
        let burger = Self.makeLog(name: "Burger", daysAgo: 2,
                                  hour: 19, calories: 500)

        let scored = FoodOSAttentionEngine.rank(
            candidates: [pizza, burger, kimchi],
            query: .init(foodName: "Kimchi stew",
                         slot: .dinner,
                         calories: 500,
                         proteinG: nil,
                         sugarG: nil,
                         mood: nil,
                         now: Self.now),
            timeZone: Self.timeZone,
            limit: 3
        )
        XCTAssertEqual(scored.first?.log.foodName, "Kimchi stew",
                       "Same-food match should out-rank unrelated logs")
    }

    // MARK: 9. attention ranks same meal slot higher

    /// Two equally-irrelevant foods, both equally recent — but one
    /// shares the query's slot. The same-slot log must win.
    func test_attention_ranksSameSlotHigher() {
        let lunchLog  = Self.makeLog(name: "Pasta", daysAgo: 1,
                                     hour: 12, calories: 600)
        let dinnerLog = Self.makeLog(name: "Pasta", daysAgo: 1,
                                     hour: 19, calories: 600)

        let scored = FoodOSAttentionEngine.rank(
            candidates: [lunchLog, dinnerLog],
            query: .init(foodName: nil,
                         slot: .dinner,
                         calories: nil,
                         proteinG: nil,
                         sugarG: nil,
                         mood: nil,
                         now: Self.now),
            timeZone: Self.timeZone,
            limit: 2
        )
        // Identify each log by its UUID so we don't rely on
        // FoodLog being a reference type.
        let dinnerScore = scored.first { $0.log.id == dinnerLog.id }
        let lunchScore  = scored.first { $0.log.id == lunchLog.id  }
        XCTAssertNotNil(dinnerScore)
        XCTAssertNotNil(lunchScore)
        XCTAssertGreaterThan(dinnerScore!.score, lunchScore!.score)
    }

    // MARK: 10. attention ranks recent logs higher

    /// All else equal, the more recent log must win. We pass two
    /// identical candidates differing only in age (1 day vs 25
    /// days) — recency should be the deciding head.
    func test_attention_ranksRecentLogsHigher() {
        let fresh = Self.makeLog(name: "Soup", daysAgo: 1,
                                 hour: 12, calories: 400)
        let stale = Self.makeLog(name: "Soup", daysAgo: 25,
                                 hour: 12, calories: 400)
        let scored = FoodOSAttentionEngine.rank(
            candidates: [stale, fresh],
            query: .init(foodName: "Soup",
                         slot: .lunch,
                         calories: 400,
                         proteinG: nil,
                         sugarG: nil,
                         mood: nil,
                         now: Self.now),
            timeZone: Self.timeZone,
            limit: 2
        )
        XCTAssertEqual(scored.first?.log.eatenAt, fresh.eatenAt,
                       "Recent log should rank above older one")
    }

    // MARK: 11. copy safety rejects banned phrasing

    /// The safety helper is the last-line guard between engine
    /// output and the view. It must flag shame, medical, bossy,
    /// and certainty phrasing — and stay quiet on warm, calm copy.
    func test_copySafety_rejectsBannedFragments() {
        // Shame
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            "You should stop binge eating like this."
        ))
        // Medical
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            "This may lead to diabetes."
        ))
        // Bossy
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            "You must eat more vegetables."
        ))
        // Certainty
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            "You always overeat at dinner."
        ))
        // Warm and calm — must pass
        XCTAssertTrue(FoodOSMomentCopySafety.isSafe(
            "Most recent meals have felt steady."
        ))
        XCTAssertTrue(FoodOSMomentCopySafety.isSafe(
            "Your dinners look lighter this week."
        ))
    }

    // MARK: 12. every personal-claim moment carries evidenceLine

    /// Sweep across all branches that fire conditionally and
    /// confirm each surfaces an evidenceLine. The fallback is
    /// allowed to skip it (it makes no specific personal claim),
    /// but every other branch must cite its basis.
    func test_everyMoment_hasEvidenceLine() {
        // Learning
        let learning = FoodOSMomentEngine.compute(
            thirtyDayLogs: [], sevenDayLogs: [], previousSevenDayLogs: [],
            now: Self.now, timeZone: Self.timeZone
        )
        XCTAssertNotNil(learning.evidenceLine)

        // Celebration: 4 → 10 meals across two weeks.
        let prev = (1...4).map {
            Self.makeLog(name: "Bowl", daysAgo: $0 + 7,
                         hour: 12, calories: 500)
        }
        let cur  = (1...10).map {
            Self.makeLog(name: "Bowl", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let celebration = FoodOSMomentEngine.compute(
            thirtyDayLogs: prev + cur,
            sevenDayLogs:  cur,
            previousSevenDayLogs: prev,
            now: Self.now, timeZone: Self.timeZone
        )
        XCTAssertNotNil(celebration.evidenceLine)

        // Recognition: kimchi 10x with no week-over-week change.
        let kimchi = (1...10).map {
            Self.makeLog(name: "Kimchi", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let prevKimchi = (1...5).map {
            Self.makeLog(name: "Kimchi", daysAgo: $0 + 7,
                         hour: 12, calories: 500)
        }
        let recognition = FoodOSMomentEngine.compute(
            thirtyDayLogs: kimchi + prevKimchi,
            sevenDayLogs:  Array(kimchi.prefix(5)),
            previousSevenDayLogs: prevKimchi,
            now: Self.now, timeZone: Self.timeZone
        )
        XCTAssertNotNil(recognition.evidenceLine)
    }

    // MARK: 13. engine is deterministic

    /// Running the engine twice with byte-identical input must
    /// produce byte-identical output. This catches accidental
    /// reliance on `Date()`, randomness, or set/dict iteration
    /// order in any of the layers.
    func test_engine_isDeterministicForSameInput() {
        let logs = (1...12).map {
            Self.makeLog(name: "Bowl", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let a = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now, timeZone: Self.timeZone
        )
        let b = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now, timeZone: Self.timeZone
        )
        XCTAssertEqual(a, b)
    }

    // MARK: 14. fallback fires when evidence is thin (but ≥ floor)

    /// 12 unique foods, no mood notes, no week-over-week change,
    /// no slot pattern, no repeats — none of the conditional
    /// branches qualify. The engine must still return something:
    /// the gentle reflection fallback.
    func test_fallback_firesWhenEvidenceIsThin() {
        // 12 unique foods, all noon, identical calories — no
        // slot pattern, no week-shift, no repeats.
        let logs = (1...12).map {
            Self.makeLog(name: "Food \($0)", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let prev = (13...18).map {
            Self.makeLog(name: "Food \($0)", daysAgo: $0,
                         hour: 12, calories: 500)
        }
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs + prev,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: prev,
            now: Self.now, timeZone: Self.timeZone
        )
        XCTAssertEqual(moment.kind, .reflection)
        XCTAssertNotNil(moment.evidenceLine)
        XCTAssertEqual(moment.priorityScore, 10,
                       "Fallback branch carries priority 10")
    }

    // MARK: 15. revelation requires surprise and evidence

    /// Morning mood notes sit far above the user's baseline, with
    /// enough observations to clear the shared 3-note floor. The new
    /// branch lives immediately after learning, so it should beat
    /// ordinary reflection/recognition candidates when the surprise
    /// gate clears.
    func test_revelation_firesForHighSurpriseTimeOfDayBelief() {
        var logs: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, mood: .loved)
        }
        logs += (5...8).map {
            Self.makeLog(name: "Midday \($0)", daysAgo: $0,
                         hour: 12, mood: .tough)
        }
        logs += (9...12).map {
            Self.makeLog(name: "Evening \($0)", daysAgo: $0,
                         hour: 19, mood: .tough)
        }

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )

        XCTAssertEqual(moment.kind, .revelation)
        XCTAssertEqual(moment.momentTag, .revelationTimeOfDay)
        XCTAssertEqual(moment.revelationRepeatKey, "timeOfDay:morning")
        XCTAssertGreaterThanOrEqual(moment.priorityScore, 95)
        XCTAssertTrue(moment.evidenceLine?.contains("4 morning meals") == true)
        XCTAssertTrue(FoodOSMomentCopySafety.isSafe(
            title: moment.title,
            body: moment.body,
            evidence: moment.evidenceLine
        ))
    }

    /// Protein-leaning meals are all positive while carb/balanced
    /// meals are tougher, so the macro paired-belief should qualify.
    /// Keeping all logs at midday prevents time-of-day from becoming
    /// the explanation instead.
    func test_revelation_firesForHighSurpriseMacroBelief() {
        var logs: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Protein \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 40, carbsG: 20, mood: .fine)
        }
        logs += (5...8).map {
            Self.makeLog(name: "Carb \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 5, carbsG: 80, mood: .tough)
        }
        logs += (9...12).map {
            Self.makeLog(name: "Balanced \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 20, carbsG: 40, mood: .tough)
        }

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )

        XCTAssertEqual(moment.kind, .revelation)
        XCTAssertEqual(moment.momentTag, .revelationMacroLean)
        XCTAssertTrue(moment.title.lowercased().contains("protein"))
    }

    /// Weekend meals have distinct composition and better mood notes.
    /// This proves the day-type candidate is implemented without
    /// depending on a specific weekday for the pinned timestamp.
    func test_revelation_firesForHighSurpriseDayTypeBelief() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        var weekendDays: [Int] = []
        var weekdayDays: [Int] = []
        for day in 1...30 {
            let date = cal.date(byAdding: .day, value: -day, to: Self.now)
                ?? Self.now
            if cal.isDateInWeekend(date) {
                weekendDays.append(day)
            } else {
                weekdayDays.append(day)
            }
        }

        var logs = Array(weekendDays.prefix(4)).enumerated().map { idx, day in
            Self.makeLog(name: "Weekend \(idx)", daysAgo: day,
                         hour: 12, calories: 800, mood: .loved)
        }
        logs += Array(weekdayDays.prefix(8)).enumerated().map { idx, day in
            Self.makeLog(name: "Weekday \(idx)", daysAgo: day,
                         hour: 12, calories: 400, mood: .tough)
        }

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )

        XCTAssertEqual(moment.kind, .revelation)
        XCTAssertEqual(moment.momentTag, .revelationDayType)
        XCTAssertTrue(moment.title.lowercased().contains("weekend"))
        XCTAssertTrue(moment.body?.lowercased().contains("weekend") == true)
    }

    /// When every bucket sits close to the user's overall baseline,
    /// the revelation branch must stay silent and let the old chain
    /// continue.
    func test_revelation_doesNotFireForLowSurprisePattern() {
        var logs: [FoodLog] = []
        for day in 1...12 {
            let mood: FoodLog.Mood = day.isMultiple(of: 2) ? .fine : .tough
            let hour = [8, 12, 19][(day - 1) % 3]
            logs.append(Self.makeLog(name: "Food \(day)", daysAgo: day,
                                     hour: hour, mood: mood))
        }

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )

        XCTAssertNotEqual(moment.kind, .revelation)
    }

    /// Two observations in the standout bucket are not enough, even
    /// when both notes are positive and the posterior is far from
    /// baseline.
    func test_revelation_requiresThreeObservationsInBucket() {
        var logs: [FoodLog] = (1...2).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, mood: .loved)
        }
        logs += (3...12).map {
            Self.makeLog(name: "Midday \($0)", daysAgo: $0,
                         hour: 12, mood: .tough)
        }

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )

        XCTAssertNotEqual(moment.kind, .revelation)
    }

    /// The optional repeat marker lets callers suppress the same
    /// revelation subject on the next refresh; when no alternate
    /// revelation exists, the engine falls through to the old chain.
    func test_revelation_doesNotRepeatSameSubjectBackToBack() {
        var logs: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, mood: .loved)
        }
        logs += (5...12).map {
            Self.makeLog(name: "Other \($0)", daysAgo: $0,
                         hour: 12, mood: .tough)
        }

        let first = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(first.kind, .revelation)

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            lastRevelationRepeatKey: first.revelationRepeatKey
        )

        XCTAssertNotEqual(moment.kind, .revelation)
    }

    /// Paired beliefs reuse the same Beta prior: even a bucket with
    /// only positive observations must stay below 1.0 and above 0.0.
    func test_pairedBeliefPosterior_neverReturnsZeroOrOne() {
        var logs: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, mood: .loved)
        }
        logs += (5...12).map {
            Self.makeLog(name: "Other \($0)", daysAgo: $0,
                         hour: 12, mood: .tough)
        }

        let candidate = FoodOSPairedBeliefs.candidates(
            in: logs,
            timeZone: Self.timeZone
        ).first

        XCTAssertNotNil(candidate)
        XCTAssertGreaterThan(candidate!.posteriorMean, 0)
        XCTAssertLessThan(candidate!.posteriorMean, 1)
        XCTAssertGreaterThan(candidate!.baselinePosterior, 0)
        XCTAssertLessThan(candidate!.baselinePosterior, 1)
    }

    /// Regression guard: when no revelation qualifies, the old
    /// recognition output remains exactly the same.
    func test_noRevelation_preservesExistingRecognitionOutput() {
        var logs: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Sweet potato", daysAgo: $0, calories: 400)
        }
        logs += (7...12).map {
            Self.makeLog(name: "Other \($0)", daysAgo: $0, calories: 400)
        }

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs: Array(logs.prefix(3)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )

        XCTAssertEqual(moment.kind, .recognition)
        XCTAssertEqual(moment.title, "Sweet potato seems to be one of your reliable meals.")
        XCTAssertEqual(moment.body, nil)
        XCTAssertEqual(moment.evidenceLine,
                       "You logged Sweet potato 6 times in the last 30 days.")
        XCTAssertEqual(moment.actionLabel, "Use it as today's anchor meal?")
    }

    // MARK: - Helpers

    /// Synthetic FoodLog at `daysAgo` days before `Self.now`, in
    /// the test timezone. Same layout as the older suite's helper
    /// but lives here so this section is self-contained.
    private static func makeLog(name: String,
                                daysAgo: Int,
                                hour: Int = 12,
                                calories: Double = 500,
                                proteinG: Double? = 20,
                                carbsG: Double = 50,
                                sugarG: Double = 5,
                                mood: FoodLog.Mood? = nil) -> FoodLog {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = 0; comps.timeZone = timeZone
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: calories,
            carbsG: carbsG,
            sugarG: sugarG,
            proteinG: proteinG,
            fatG: 15,
            fiberG: 5,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: dt,
            createdAt: dt,
            origin: .analyzed,
            sourceLogId: nil,
            mood: mood
        )
    }
}


// MARK: - FoodOSMomentFeedback (Feedback Learning V1)

final class FoodOSMomentFeedbackTests: XCTestCase {

    private static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    private static let now = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: helpers

    /// Throwaway file URL inside the test bundle's temp dir. Each
    /// test gets its own URL so two tests never race on the same
    /// JSON file.
    private func tempStoreURL(named: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoodOSFeedbackTests", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let slug = named
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return dir.appendingPathComponent(
            "store_\(slug)_\(UUID().uuidString).json"
        )
    }

    /// Build a synthetic moment of an arbitrary shape. Used by the
    /// store and bandit tests where the rest of the engine is out
    /// of scope.
    private func makeMoment(
        kind: FoodOSMoment.Kind = .nudge,
        title: String = "Test",
        body: String? = nil,
        evidenceLine: String? = nil,
        actionLabel: String? = nil
    ) -> FoodOSMoment {
        FoodOSMoment(
            kind: kind,
            title: title,
            body: body,
            evidenceLine: evidenceLine,
            confidence: .medium,
            actionLabel: actionLabel,
            priorityScore: 60,
            generatedAt: Self.now
        )
    }

    private func makeLog(name: String,
                         daysAgo: Int,
                         hour: Int = 12,
                         calories: Double = 500,
                         mood: FoodLog.Mood? = nil) -> FoodLog {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        let day = cal.date(byAdding: .day, value: -daysAgo, to: Self.now)
            ?? Self.now
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = 0; comps.timeZone = Self.timeZone
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(), userId: UUID(), foodName: name,
            imagePath: nil, imageThumbPath: nil,
            calories: calories, carbsG: 50, sugarG: 5,
            proteinG: 20, fatG: 15, fiberG: 5,
            benefits: [], drawbacks: [], nutrients: [],
            coachName: nil, coachAdvice: nil,
            eatenAt: dt, createdAt: dt,
            origin: .analyzed, sourceLogId: nil, mood: mood
        )
    }

    // MARK: 1. new store starts empty

    func test_store_startsEmpty() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.preferences.isEmpty)
    }

    // MARK: 2. helpful increases posterior

    func test_helpful_increasesPosterior() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge,
                                body: "Your dinners have been running heavier")
        store.record(feedback: .helpful, for: moment)
        let pref = store.preference(for: .lighterDinner)
        XCTAssertNotNil(pref)
        XCTAssertGreaterThan(pref!.posteriorMean, 0.5)
        XCTAssertEqual(pref!.helpfulCount, 1)
    }

    // MARK: 3. notUseful decreases posterior

    func test_notUseful_decreasesPosterior() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge,
                                body: "Your dinners have been running heavier")
        store.record(feedback: .notUseful, for: moment)
        let pref = store.preference(for: .lighterDinner)
        XCTAssertNotNil(pref)
        XCTAssertLessThan(pref!.posteriorMean, 0.5)
    }

    // MARK: 4. willTry increases posterior mildly

    func test_willTry_increasesPosteriorMildly() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge,
                                body: "Your dinners have been running heavier")
        store.record(feedback: .willTry, for: moment)
        let pref = store.preference(for: .lighterDinner)
        XCTAssertNotNil(pref)
        // alpha = 0 + 1 + 0 + 1 = 2; beta = 0 + 0 + 1 = 1; mean = 2/3
        XCTAssertEqual(pref!.posteriorMean, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertGreaterThan(pref!.posteriorMean, 0.5)
        // Mild: less than 3 helpfuls would push (4/5 = 0.8).
        XCTAssertLessThan(pref!.posteriorMean, 0.8)
    }

    // MARK: 5. low confidence does not affect priority

    func test_lowConfidence_yieldsZeroAdjustment() {
        var pref = FoodOSMomentPreference(tag: .lighterDinner,
                                          shownCount: 2,
                                          helpfulCount: 2)
        pref.recomputeDerived()
        XCTAssertEqual(pref.confidence, .low)
        XCTAssertEqual(FoodOSMomentBandit.adjustment(for: pref), 0)
    }

    // MARK: 6. high confidence positive feedback boosts matching tag

    func test_highConfidencePositive_boostsMatchingTag() {
        // 9 helpfuls, 0 notUseful → posterior 10/11 ≈ 0.91, shown 9 → high.
        var pref = FoodOSMomentPreference(tag: .lighterDinner,
                                          shownCount: 9,
                                          helpfulCount: 9)
        pref.recomputeDerived()
        XCTAssertEqual(pref.confidence, .high)
        XCTAssertEqual(FoodOSMomentBandit.adjustment(for: pref), 10)

        // End-to-end: nudge has priority 60, recognition has 50. Boost
        // the nudge tag with enough positive feedback and the engine
        // should still surface the nudge (already on top), proving
        // the integration path runs.
        let logs = (1...12).map {
            self.makeLog(name: "Kimchi", daysAgo: $0, hour: 12, calories: 400)
        }
        let dinners = (1...4).map {
            self.makeLog(name: "Burger", daysAgo: $0, hour: 19, calories: 900)
        }
        let lunches = (1...4).map {
            self.makeLog(name: "Salad", daysAgo: $0, hour: 12, calories: 400)
        }
        let thirty = logs + dinners + lunches
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: thirty,
            sevenDayLogs:  Array(thirty.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [pref]
        )
        // Either nudge (boosted) or recognition (its native priority)
        // can win — but the boost must NOT downgrade the nudge below
        // recognition.
        XCTAssertNotEqual(moment.kind, .learning)
    }

    // MARK: 7. high confidence negative feedback suppresses matching tag

    func test_highConfidenceNegative_suppressesMatchingTag() {
        // Build a scenario where the nudge branch naturally fires
        // (dinners ≥25% heavier than lunches, both well populated)
        // and recognition also has signal (kimchi 5x).
        let kimchi = (1...5).map {
            self.makeLog(name: "Kimchi", daysAgo: $0, hour: 12, calories: 400)
        }
        let dinners = (1...4).map {
            self.makeLog(name: "Burger", daysAgo: $0, hour: 19, calories: 900)
        }
        let lunches = (1...4).map {
            self.makeLog(name: "Salad", daysAgo: $0, hour: 12, calories: 400)
        }
        let thirty = kimchi + dinners + lunches

        // No preferences → nudge (priority 60) beats recognition (50).
        let baseline = FoodOSMomentEngine.compute(
            thirtyDayLogs: thirty,
            sevenDayLogs:  Array(thirty.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(baseline.kind, .nudge,
                       "Baseline assumption: nudge wins without feedback")

        // 9 notUsefuls on .lighterDinner → posterior ≈ 0.09, high
        // confidence → -10 adjustment → nudge falls to 50, ties or
        // loses to recognition (50). Tie-break preserves chain order
        // (celebration/change/mood/nudge/recognition), so a tie still
        // favors nudge — bump to 10 negatives so recognition wins.
        var pref = FoodOSMomentPreference(tag: .lighterDinner,
                                          shownCount: 10,
                                          notUsefulCount: 10)
        pref.recomputeDerived()
        XCTAssertEqual(pref.confidence, .high)
        XCTAssertEqual(FoodOSMomentBandit.adjustment(for: pref), -10)

        let withFeedback = FoodOSMomentEngine.compute(
            thirtyDayLogs: thirty,
            sevenDayLogs:  Array(thirty.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [pref]
        )
        // Nudge has been suppressed by 10 → tied with recognition at
        // 50 — but the tie-breaker keeps chain order, so nudge still
        // wins among tied. To verify suppression actually moves the
        // needle, just confirm the score moved: i.e., a moment is
        // still produced and the nudge isn't artificially elevated.
        // Stronger assertion: with even MORE suppression…
        var harsher = FoodOSMomentPreference(tag: .lighterDinner,
                                             shownCount: 20,
                                             notUsefulCount: 20)
        harsher.recomputeDerived()
        // adjustment is bounded at -10, so the harsher version
        // doesn't increase the magnitude — instead drive the result
        // by simultaneously boosting recognition.
        var liftRec = FoodOSMomentPreference(tag: .repeatReliableMeal,
                                             shownCount: 10,
                                             helpfulCount: 10)
        liftRec.recomputeDerived()
        let suppressed = FoodOSMomentEngine.compute(
            thirtyDayLogs: thirty,
            sevenDayLogs:  Array(thirty.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [harsher, liftRec]
        )
        XCTAssertEqual(suppressed.kind, .recognition,
                       "Nudge suppressed AND recognition boosted should let " +
                       "recognition win over nudge")
        _ = withFeedback // intentionally unused: documents the chain
    }

    // MARK: 8. no feedback preserves original moment ranking

    func test_noFeedback_preservesOriginalRanking() {
        let logs = (1...12).map {
            self.makeLog(name: "Kimchi", daysAgo: $0, hour: 12, calories: 500)
        }
        let baseline = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )
        let withEmptyPrefs = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: []
        )
        XCTAssertEqual(baseline, withEmptyPrefs)
    }

    // MARK: 9. corrupt storage resets safely

    func test_corruptStorage_resetsSafely() throws {
        let url = tempStoreURL()
        try "not json at all { [".data(using: .utf8)!.write(to: url)
        let store = FoodOSMomentFeedbackStore(fileURL: url)
        // Decode failed → reset to empty without throwing.
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.preferences.isEmpty)
        // And a fresh write should succeed on the cleaned slate.
        store.record(feedback: .helpful, for: makeMoment(kind: .nudge))
        let reloaded = FoodOSMomentFeedbackStore(fileURL: url)
        XCTAssertEqual(reloaded.events.count, 1)
    }

    // MARK: 10. event history caps at 500

    func test_eventHistory_capsAt500() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        // 510 taps; oldest 10 should drop.
        for _ in 0..<510 {
            store.record(feedback: .helpful, for: moment)
        }
        XCTAssertEqual(store.events.count,
                       FoodOSMomentFeedbackStore.eventHistoryCap)
    }

    // MARK: 11. momentTag derivation works for the main kinds

    func test_momentTag_derivation() {
        XCTAssertEqual(
            makeMoment(kind: .nudge,
                       body: "Your dinners have been running heavier").momentTag,
            .lighterDinner
        )
        XCTAssertEqual(
            makeMoment(kind: .nudge,
                       body: "Pair more protein with this meal").momentTag,
            .proteinPairing
        )
        XCTAssertEqual(makeMoment(kind: .change).momentTag, .weeklyChange)
        XCTAssertEqual(makeMoment(kind: .celebration).momentTag, .consistency)
        XCTAssertEqual(
            makeMoment(kind: .recognition).momentTag, .repeatReliableMeal
        )
        XCTAssertEqual(
            makeMoment(kind: .reflection,
                       evidenceLine: "Based on 5 mood notes.").momentTag,
            .moodReflection
        )
        XCTAssertEqual(
            makeMoment(kind: .reflection,
                       evidenceLine: "Based on your recent meals.").momentTag,
            .genericReflection
        )
        XCTAssertEqual(
            makeMoment(kind: .revelation,
                       title: "Your mornings have been your best-mood meals.").momentTag,
            .revelationTimeOfDay
        )
        XCTAssertEqual(
            makeMoment(kind: .revelation,
                       title: "Your higher-protein meals have been landing better.").momentTag,
            .revelationMacroLean
        )
        XCTAssertEqual(
            makeMoment(kind: .revelation,
                       title: "Your weekends look different and land steadier.").momentTag,
            .revelationDayType
        )
        XCTAssertEqual(makeMoment(kind: .learning).momentTag, .unknown)
    }

    // MARK: 12. feedback controls do not appear for learning moments

    func test_feedbackPolicy_hidesControlsForLearning() {
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsControls(
            for: makeMoment(kind: .learning)
        ))
        XCTAssertTrue(FoodOSMomentFeedbackPolicy.showsControls(
            for: makeMoment(kind: .nudge)
        ))
        XCTAssertTrue(FoodOSMomentFeedbackPolicy.showsControls(
            for: makeMoment(kind: .reflection)
        ))
        // "I'll try this" is only meaningful on action-prompting kinds.
        XCTAssertTrue(FoodOSMomentFeedbackPolicy.showsWillTry(
            for: makeMoment(kind: .nudge)
        ))
        XCTAssertTrue(FoodOSMomentFeedbackPolicy.showsWillTry(
            for: makeMoment(kind: .experiment)
        ))
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsWillTry(
            for: makeMoment(kind: .reflection)
        ))
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsWillTry(
            for: makeMoment(kind: .revelation)
        ))
    }

    // MARK: 13. recognition gets "I'll try this" only with an action label

    /// Anchor-grade recognition (engine produced "Use it as today's
    /// anchor meal?") unlocks the active-experiment loop — the chip
    /// must render so the user can opt in.
    func test_feedbackPolicy_showsWillTry_forRecognitionWithActionLabel() {
        let m = makeMoment(
            kind: .recognition,
            title: "Sweet potato seems to be one of your reliable meals.",
            body: nil,
            evidenceLine: "You logged Sweet potato 6 times in the last 30 days.",
            actionLabel: "Use it as today's anchor meal?"
        )
        XCTAssertTrue(FoodOSStoryBuilder.shouldRenderActionLabel(m),
                      "Precondition: this label is renderable.")
        XCTAssertTrue(FoodOSMomentFeedbackPolicy.showsWillTry(for: m))
    }

    /// Recognition card with no actionLabel — observation only, no
    /// promise to make.
    func test_feedbackPolicy_hidesWillTry_forRecognitionWithoutActionLabel() {
        let m = makeMoment(
            kind: .recognition,
            actionLabel: nil
        )
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsWillTry(for: m))
    }

    /// Weak recognition (count below the anchor floor) — engine
    /// returns nil for actionLabel; the chip must stay hidden.
    func test_feedbackPolicy_hidesWillTry_forWeakRecognition() {
        let m = makeMoment(
            kind: .recognition,
            title: "Sweet potato shows up here and there.",
            evidenceLine: "You logged Sweet potato 3 times in the last 30 days.",
            actionLabel: nil
        )
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(m))
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsWillTry(for: m))
    }

    /// Recognition with whitespace-only or unsafe action label still
    /// falls through to false — we route through the same renderable
    /// check the UI uses.
    func test_feedbackPolicy_hidesWillTry_forRecognitionWithUnsafeActionLabel() {
        let unsafe = makeMoment(
            kind: .recognition,
            actionLabel: "You must stop eating like this."
        )
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(unsafe))
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsWillTry(for: unsafe))

        let blank = makeMoment(
            kind: .recognition,
            actionLabel: "   "
        )
        XCTAssertFalse(FoodOSMomentFeedbackPolicy.showsWillTry(for: blank))
    }

    /// Kinds that are neither action-prompting nor recognition still
    /// hide the chip — change, celebration, reflection, learning —
    /// even if a hand-authored actionLabel slips through.
    func test_feedbackPolicy_hidesWillTry_forOtherKindsRegardlessOfActionLabel() {
        let actionable = "Use it as today's anchor meal?"
        for kind in [FoodOSMoment.Kind.change,
                     .celebration,
                     .reflection,
                     .learning,
                     .revelation] {
            let withLabel = makeMoment(kind: kind, actionLabel: actionable)
            XCTAssertFalse(
                FoodOSMomentFeedbackPolicy.showsWillTry(for: withLabel),
                "\(kind) must not surface I'll try this even with an action label"
            )
            let withoutLabel = makeMoment(kind: kind, actionLabel: nil)
            XCTAssertFalse(
                FoodOSMomentFeedbackPolicy.showsWillTry(for: withoutLabel),
                "\(kind) must not surface I'll try this"
            )
        }
    }
}

// MARK: - FoodOSMomentFeedback V2 (active experiments + worked-before)

final class FoodOSMomentFeedbackV2Tests: XCTestCase {

    private static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    private static let now = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: helpers

    private func tempStoreURL(named: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoodOSFeedbackV2Tests", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let slug = named
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return dir.appendingPathComponent(
            "v2_store_\(slug)_\(UUID().uuidString).json"
        )
    }

    private func makeMoment(
        kind: FoodOSMoment.Kind = .nudge,
        title: String = "Try keeping dinner a little lighter today.",
        body: String? = "Your dinners have been running heavier than your lunches lately.",
        evidenceLine: String? = nil
    ) -> FoodOSMoment {
        FoodOSMoment(
            kind: kind,
            title: title,
            body: body,
            evidenceLine: evidenceLine,
            confidence: .medium,
            actionLabel: nil,
            priorityScore: 60,
            generatedAt: Self.now
        )
    }

    private func makeLog(mood: FoodLog.Mood? = nil) -> FoodLog {
        FoodLog(
            id: UUID(), userId: UUID(), foodName: "Salad",
            imagePath: nil, imageThumbPath: nil,
            calories: 400, carbsG: 30, sugarG: 4,
            proteinG: 20, fatG: 10, fiberG: 6,
            benefits: [], drawbacks: [], nutrients: [],
            coachName: nil, coachAdvice: nil,
            eatenAt: Self.now, createdAt: Self.now,
            origin: .analyzed, sourceLogId: nil, mood: mood
        )
    }

    // MARK: 1. tapping willTry starts active experiment

    func test_willTry_startsActiveExperiment() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        let active = store.activeExperiments
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.momentTag, .lighterDinner)
        XCTAssertEqual(active.first?.status, .active)
    }

    // MARK: 2. active experiment expires after 24 hours

    func test_activeExperiment_expiresAfter24Hours() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        let later = Self.now.addingTimeInterval(25 * 60 * 60)
        let expiredCount = store.expireOldExperiments(now: later)
        XCTAssertEqual(expiredCount, 1)
        XCTAssertTrue(store.activeExperiments.isEmpty)
        XCTAssertEqual(store.resolvedExperiments.last?.status, .expired)
    }

    // MARK: 3. only one active experiment per tag is kept

    func test_singleActiveExperimentPerTag() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        _ = store.startExperiment(
            from: moment, now: Self.now.addingTimeInterval(5 * 60)
        )
        let active = store.activeExperiments.filter {
            $0.momentTag == .lighterDinner
        }
        XCTAssertEqual(active.count, 1)
    }

    // MARK: 4-6. mood outcome mapping

    func test_lovedMood_resolvesPositive() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        let resolved = store.resolveExperiment(
            for: makeLog(), mood: .loved, now: Self.now.addingTimeInterval(60)
        )
        XCTAssertEqual(resolved?.outcome, .positive)
        XCTAssertEqual(
            store.preference(for: .lighterDinner)?.positiveMoodAfterTryCount, 1
        )
    }

    func test_fineMood_resolvesPositive() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        let resolved = store.resolveExperiment(
            for: makeLog(), mood: .fine, now: Self.now.addingTimeInterval(60)
        )
        XCTAssertEqual(resolved?.outcome, .positive)
        XCTAssertEqual(
            store.preference(for: .lighterDinner)?.positiveMoodAfterTryCount, 1
        )
    }

    func test_toughMood_resolvesNegative() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        let resolved = store.resolveExperiment(
            for: makeLog(), mood: .tough, now: Self.now.addingTimeInterval(60)
        )
        XCTAssertEqual(resolved?.outcome, .negative)
        XCTAssertEqual(
            store.preference(for: .lighterDinner)?.negativeMoodAfterTryCount, 1
        )
    }

    // MARK: 7. no active experiment → no resolution

    func test_noActiveExperiment_doesNotResolve() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let resolved = store.resolveExperiment(
            for: makeLog(), mood: .loved, now: Self.now
        )
        XCTAssertNil(resolved)
    }

    // MARK: 8. expired experiments do not update counts

    func test_expiredExperiment_doesNotUpdateCounts() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        let later = Self.now.addingTimeInterval(25 * 60 * 60)
        let resolved = store.resolveExperiment(
            for: makeLog(), mood: .loved, now: later
        )
        XCTAssertNil(resolved, "expired experiment must not resolve")
        // No positive/negative count update for an expired row.
        let pref = store.preference(for: .lighterDinner)
        XCTAssertEqual(pref?.positiveMoodAfterTryCount ?? 0, 0)
        XCTAssertEqual(pref?.negativeMoodAfterTryCount ?? 0, 0)
    }

    // MARK: 9-10. resolving increments the right counter

    func test_positiveResolution_incrementsPositiveCounter() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        _ = store.resolveExperiment(
            for: makeLog(), mood: .loved, now: Self.now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            store.preference(for: .lighterDinner)?.positiveMoodAfterTryCount, 1
        )
    }

    func test_negativeResolution_incrementsNegativeCounter() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        _ = store.startExperiment(from: moment, now: Self.now)
        _ = store.resolveExperiment(
            for: makeLog(), mood: .tough, now: Self.now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            store.preference(for: .lighterDinner)?.negativeMoodAfterTryCount, 1
        )
    }

    // MARK: 11. worked-before requires >= 2 positive outcomes

    func test_workedBefore_requiresTwoPositives() {
        // Build a 12-log thirty-day window so we clear the learning
        // gate. Use mid-day logs so neither the dinner-change branch
        // nor the dinner-heavier nudge branch fires.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        let logs: [FoodLog] = (1...12).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: Self.now) ?? Self.now
            return FoodLog(
                id: UUID(), userId: UUID(), foodName: "Soup",
                imagePath: nil, imageThumbPath: nil,
                calories: 500, carbsG: 50, sugarG: 5,
                proteinG: 25, fatG: 10, fiberG: 5,
                benefits: [], drawbacks: [], nutrients: [],
                coachName: nil, coachAdvice: nil,
                eatenAt: day, createdAt: day,
                origin: .analyzed, sourceLogId: nil, mood: nil
            )
        }

        // One positive — not enough.
        var pref = FoodOSMomentPreference(
            tag: .lighterDinner,
            shownCount: 5,
            helpfulCount: 2,
            willTryCount: 1,
            positiveMoodAfterTryCount: 1
        )
        pref.recomputeDerived()

        let one = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [pref]
        )
        XCTAssertNotEqual(one.title, "This worked for you before.")

        // Two positives + posterior over 0.65 + medium confidence — fires.
        var pref2 = FoodOSMomentPreference(
            tag: .lighterDinner,
            shownCount: 5,
            helpfulCount: 3,
            willTryCount: 2,
            positiveMoodAfterTryCount: 2
        )
        pref2.recomputeDerived()
        XCTAssertGreaterThanOrEqual(pref2.posteriorMean, 0.65)
        XCTAssertEqual(pref2.confidence, .medium)

        let two = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [pref2]
        )
        XCTAssertEqual(two.title, "This worked for you before.")
        XCTAssertEqual(two.kind, .experiment)
    }

    // MARK: 12. worked-before requires posterior >= 0.65

    func test_workedBefore_requiresPosteriorThreshold() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        let logs: [FoodLog] = (1...12).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: Self.now) ?? Self.now
            return FoodLog(
                id: UUID(), userId: UUID(), foodName: "Soup",
                imagePath: nil, imageThumbPath: nil,
                calories: 500, carbsG: 50, sugarG: 5,
                proteinG: 25, fatG: 10, fiberG: 5,
                benefits: [], drawbacks: [], nutrients: [],
                coachName: nil, coachAdvice: nil,
                eatenAt: day, createdAt: day,
                origin: .analyzed, sourceLogId: nil, mood: nil
            )
        }

        // 2 positives but plenty of notUseful → posterior under 0.65.
        var pref = FoodOSMomentPreference(
            tag: .lighterDinner,
            shownCount: 10,
            helpfulCount: 0,
            notUsefulCount: 8,
            willTryCount: 0,
            positiveMoodAfterTryCount: 2
        )
        pref.recomputeDerived()
        XCTAssertLessThan(pref.posteriorMean, 0.65)

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [pref]
        )
        XCTAssertNotEqual(moment.title, "This worked for you before.")
    }

    // MARK: 13. worked-before is gated by the learning floor

    func test_workedBefore_gatedByLearningFloor() {
        // 4 logs — below readinessFloor (8).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        let logs: [FoodLog] = (1...4).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: Self.now) ?? Self.now
            return FoodLog(
                id: UUID(), userId: UUID(), foodName: "Soup",
                imagePath: nil, imageThumbPath: nil,
                calories: 500, carbsG: 50, sugarG: 5,
                proteinG: 25, fatG: 10, fiberG: 5,
                benefits: [], drawbacks: [], nutrients: [],
                coachName: nil, coachAdvice: nil,
                eatenAt: day, createdAt: day,
                origin: .analyzed, sourceLogId: nil, mood: nil
            )
        }
        var pref = FoodOSMomentPreference(
            tag: .lighterDinner,
            shownCount: 5,
            helpfulCount: 3,
            willTryCount: 2,
            positiveMoodAfterTryCount: 2
        )
        pref.recomputeDerived()

        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(2)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: [pref]
        )
        XCTAssertEqual(moment.kind, .learning,
                       "Learning gate must override worked-before candidate")
    }

    // MARK: 14. corrupt experiment storage resets safely

    func test_corruptExperimentStorage_resetsSafely() throws {
        let url = tempStoreURL()
        try "{ malformed".data(using: .utf8)!.write(to: url)
        let store = FoodOSMomentFeedbackStore(fileURL: url)
        XCTAssertTrue(store.activeExperiments.isEmpty)
        XCTAssertTrue(store.resolvedExperiments.isEmpty)
        // And a fresh write still works on the cleaned slate.
        _ = store.startExperiment(from: makeMoment(kind: .nudge), now: Self.now)
        let reloaded = FoodOSMomentFeedbackStore(fileURL: url)
        XCTAssertEqual(reloaded.activeExperiments.count, 1)
    }

    // MARK: 15. history caps enforced

    func test_resolvedExperimentHistory_capsAt100() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        // 120 quick start → resolve cycles to overflow the cap.
        for i in 0..<120 {
            let t = Self.now.addingTimeInterval(Double(i * 120))
            _ = store.startExperiment(from: moment, now: t)
            _ = store.resolveExperiment(
                for: makeLog(),
                mood: .fine,
                now: t.addingTimeInterval(60)
            )
        }
        XCTAssertLessThanOrEqual(
            store.resolvedExperiments.count,
            FoodOSMomentFeedbackStore.resolvedExperimentHistoryCap
        )
    }

    // MARK: 16. no feedback preserves legacy ranking

    func test_noFeedback_preservesLegacyRanking() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        let logs: [FoodLog] = (1...12).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: Self.now) ?? Self.now
            return FoodLog(
                id: UUID(), userId: UUID(), foodName: "Soup",
                imagePath: nil, imageThumbPath: nil,
                calories: 500, carbsG: 50, sugarG: 5,
                proteinG: 25, fatG: 10, fiberG: 5,
                benefits: [], drawbacks: [], nutrients: [],
                coachName: nil, coachAdvice: nil,
                eatenAt: day, createdAt: day,
                origin: .analyzed, sourceLogId: nil, mood: nil
            )
        }
        let baseline = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone
        )
        let withEmpty = FoodOSMomentEngine.compute(
            thirtyDayLogs: logs,
            sevenDayLogs:  Array(logs.prefix(5)),
            previousSevenDayLogs: [],
            now: Self.now,
            timeZone: Self.timeZone,
            preferences: []
        )
        XCTAssertEqual(baseline, withEmpty)
    }

    // MARK: 17. copy safety rejects causal / medical / shaming phrasing

    func test_copySafety_rejectsBannedPhrasing() {
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            title: "This always cures your bad mood",
            body: nil, evidence: nil
        ))
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            title: "Your doctor recommends this",
            body: nil, evidence: nil
        ))
        XCTAssertFalse(FoodOSMomentCopySafety.isSafe(
            title: "You must eat lighter",
            body: nil, evidence: nil
        ))
        // The V2 worked-before copy itself is safe.
        XCTAssertTrue(FoodOSMomentCopySafety.isSafe(
            title: "This worked for you before.",
            body: "When you tried this kind of moment before, your next mood note seemed steady or better.",
            evidence: "Based on 4 tries with 3 positive mood notes."
        ))
    }

    // MARK: 18. integration — willTry → loved increases posterior

    func test_integration_willTryThenLoved_raisesPosterior() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        store.record(feedback: .willTry, for: moment, now: Self.now)
        _ = store.startExperiment(from: moment, now: Self.now)
        let before = store.preference(for: .lighterDinner)?.posteriorMean ?? 0
        _ = store.resolveExperiment(
            for: makeLog(),
            mood: .loved,
            now: Self.now.addingTimeInterval(60)
        )
        let after = store.preference(for: .lighterDinner)?.posteriorMean ?? 0
        XCTAssertGreaterThan(after, before,
                             "resolving positive should raise posterior")
    }

    // MARK: 19. integration — negative outcome flips the bandit signal

    func test_integration_negativeOutcome_suppressesTag() {
        let store = FoodOSMomentFeedbackStore(fileURL: tempStoreURL())
        let moment = makeMoment(kind: .nudge)
        // Build a strong negative signal: many notUseful taps plus a
        // few negative mood-after-try outcomes. With shownCount ≥ 8
        // (high confidence) and posterior below 0.35, the bandit
        // returns a -10 adjustment.
        for _ in 0..<10 {
            store.record(feedback: .notUseful, for: moment, now: Self.now)
        }
        for _ in 0..<3 {
            _ = store.startExperiment(from: moment, now: Self.now)
            _ = store.resolveExperiment(
                for: makeLog(),
                mood: .tough,
                now: Self.now.addingTimeInterval(60)
            )
        }
        let pref = store.preference(for: .lighterDinner)
        XCTAssertNotNil(pref)
        XCTAssertEqual(pref?.confidence, .high)
        XCTAssertLessThanOrEqual(pref?.posteriorMean ?? 1.0, 0.35)
        XCTAssertEqual(FoodOSMomentBandit.adjustment(for: pref!), -10)
    }
}

// MARK: - FoodOS storytelling (Phase 18)
//
// Pure tests for the storytelling helpers introduced to make every
// Mirror surface follow CLAIM → SPECIFIC EVIDENCE → TINY ACTION.
//
// Numbered against the task brief:
//   1.  hero never says "rarely repeat" when top food count ≥ 5
//   2.  hero says "mostly exploring" when exploring + one anchor
//   3.  recognition evidence includes count + time window
//   4.  mood evidence includes positive ratio when notes ≥ 3
//   5.  mood claim hidden when mood note count < 3
//   6.  worked-before evidence includes tries + positive mood notes
//   7.  celebration evidence compares this week vs previous week
//   8.  nudge copy never says "works well" without supporting evidence
//   9.  Home preview uses sharper anchor copy for repeated top food
//   10. contradiction guard catches top-food vs explorer conflict
//   11. copy safety rejects shame / medical / bossy / certainty
//   12. weak evidence uses soft language ("starting to" / "may be" /
//       "looks like")
//   13. all visible personal claims carry an evidenceLine
//   14. legacy behavior still compiles (the existing suite proves
//       this — we keep that pact explicit here)

final class FoodOSStoryBuilderTests: XCTestCase {

    private static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    private static let now = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: helpers

    private static func makeLog(name: String,
                                daysAgo: Int,
                                hour: Int = 12,
                                calories: Double = 500,
                                proteinG: Double? = 20,
                                sugarG: Double = 5,
                                mood: FoodLog.Mood? = nil) -> FoodLog {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = 0; comps.timeZone = timeZone
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(), userId: UUID(), foodName: name,
            imagePath: nil, imageThumbPath: nil,
            calories: calories, carbsG: 50, sugarG: sugarG,
            proteinG: proteinG, fatG: 15, fiberG: 5,
            benefits: [], drawbacks: [], nutrients: [],
            coachName: nil, coachAdvice: nil,
            eatenAt: dt, createdAt: dt,
            origin: .analyzed, sourceLogId: nil, mood: mood
        )
    }

    // MARK: 1. hero — "rarely repeat" forbidden when an anchor exists

    /// 6 sweet potato logs in a 30-log window. The pure-explorer
    /// branch would normally fire (high uniqueness), but the
    /// contradiction guard must keep us out of the "rarely repeat"
    /// branch because a single food already crossed the anchor floor.
    func test_hero_neverSaysRarelyRepeatWhenAnchorExists() {
        // Build a 30-log window: 6 Sweet potato + 24 unique foods.
        // Uniqueness ratio = 25/30 ≈ 0.83 — over the explorer floor.
        var logs: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Sweet potato", daysAgo: $0)
        }
        logs += (7...30).map {
            Self.makeLog(name: "Food \($0)", daysAgo: $0)
        }
        let topFoods = FoodMirrorInsightService.mostCommonFoods(
            in: logs, limit: 3
        )
        let uniqueCount = Set(logs.map(\.foodName)).count
        let hero = FoodOSStoryBuilder.heroIdentityLine(
            thirtyDayLogCount: logs.count,
            topFoods:          topFoods,
            uniqueFoodCount:   uniqueCount
        )
        XCTAssertNotNil(hero)
        XCTAssertFalse(
            hero!.lowercased().contains("rarely repeat"),
            "Hero must not say 'rarely repeat' when a top food has crossed the anchor floor"
        )
    }

    // MARK: 2. hero — "mostly exploring" framing when anchor + explore

    /// Same shape as the contradiction case, but here we assert the
    /// positive: the picker chooses "mostly exploring — but X is
    /// becoming a reliable anchor."
    func test_hero_mostlyExploringWhenAnchorAndManyUnique() {
        var logs: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Sweet potato", daysAgo: $0)
        }
        logs += (7...30).map {
            Self.makeLog(name: "Food \($0)", daysAgo: $0)
        }
        let topFoods = FoodMirrorInsightService.mostCommonFoods(
            in: logs, limit: 3
        )
        let uniqueCount = Set(logs.map(\.foodName)).count
        let hero = FoodOSStoryBuilder.heroIdentityLine(
            thirtyDayLogCount: logs.count,
            topFoods:          topFoods,
            uniqueFoodCount:   uniqueCount
        )
        XCTAssertEqual(hero,
                       "You're mostly exploring — but Sweet potato is becoming a reliable anchor.")
    }

    /// Pure explorer — no food repeats more than once → "exploring
    /// widely — your meals rarely repeat." is allowed because no
    /// anchor exists.
    func test_hero_exploringWidelyWhenNoStrongRepeats() {
        let logs = (1...12).map {
            Self.makeLog(name: "Unique \($0)", daysAgo: $0)
        }
        let topFoods = FoodMirrorInsightService.mostCommonFoods(
            in: logs, limit: 3
        )
        let uniqueCount = Set(logs.map(\.foodName)).count
        let hero = FoodOSStoryBuilder.heroIdentityLine(
            thirtyDayLogCount: logs.count,
            topFoods:          topFoods,
            uniqueFoodCount:   uniqueCount
        )
        XCTAssertEqual(hero,
                       "You're exploring widely — your meals rarely repeat.")
    }

    // MARK: 3. recognition evidence includes count + window

    func test_recognitionEvidence_includesCountAndWindow() {
        let line = FoodOSEvidenceBuilder.recognitionEvidence(
            food: "Sweet potato", count: 6
        )
        XCTAssertEqual(line, "You logged Sweet potato 6 times in the last 30 days.")
    }

    // MARK: 4. mood evidence cites positive ratio when ≥ 3 notes

    func test_moodEvidence_citesPositiveOverTotal() {
        let line = FoodOSEvidenceBuilder.moodEvidence(
            positive: 22, total: 32
        )
        XCTAssertEqual(line, "22 of 32 mood notes were fine or loved.")
    }

    // MARK: 5. mood claim gated by mood-note floor

    /// Two mood notes — both loved — is below the 3-note floor.
    /// The mood-reflection branch must NOT fire even with a high
    /// posterior; the engine has to fall through to the next
    /// candidate or the fallback. The existing engine test covers
    /// this case; here we assert the policy helper directly so a
    /// future contributor can't loosen the floor by accident.
    func test_moodClaim_hiddenWhenFewerThanThreeNotes() {
        XCTAssertFalse(FoodOSNarrativePolicy.canMakeMoodClaim(moodLogCount: 2))
        XCTAssertTrue(FoodOSNarrativePolicy.canMakeMoodClaim(moodLogCount: 3))
    }

    // MARK: 6. worked-before evidence cites tries + positives

    func test_workedBeforeEvidence_includesTriesAndPositives() {
        XCTAssertEqual(
            FoodOSEvidenceBuilder.workedBeforeEvidence(tries: 3, positives: 2),
            "Based on 3 tries with 2 positive mood notes."
        )
        XCTAssertEqual(
            FoodOSEvidenceBuilder.workedBeforeEvidence(tries: 1, positives: 1),
            "Based on 1 try with 1 positive mood note."
        )
    }

    // MARK: 7. celebration evidence compares weeks

    func test_celebrationEvidence_comparesThisWeekVsLast() {
        let line = FoodOSEvidenceBuilder.celebrationEvidence(
            currentCount: 21, previousCount: 12
        )
        XCTAssertTrue(line.contains("21"))
        XCTAssertTrue(line.contains("9"))
        XCTAssertTrue(line.lowercased().contains("more than last"))
    }

    // MARK: 8. nudge copy never says "work well" without evidence

    /// The positive-mood-linked-food nudge has historically been
    /// "A meal like X often seems to work well for you." The
    /// storytelling pass must keep the phrase "work well" — older
    /// tests assert against it — but must also surface concrete
    /// evidence (count of loved logs).
    func test_nudgeCopy_includesEvidenceAlongsideWorkWell() {
        let nudge = FoodOSStoryBuilder.positiveMoodFoodNudge(
            food: "Sweet potato", lovedCount: 3
        )
        let lower = nudge.lowercased()
        XCTAssertTrue(lower.contains("work well"))
        XCTAssertTrue(lower.contains("3"),
                      "Nudge must cite the supporting count")
        XCTAssertTrue(lower.contains("mood notes"),
                      "Nudge must cite the mood-evidence source")
    }

    // MARK: 9. Home preview uses sharper anchor copy

    /// Sweet potato shows up 6× → the Home preview surfaces the
    /// anchor title and a sharper "6 logs · …" footer instead of
    /// the generic "Based on 30 days of logs" line.
    func test_homePreview_usesSharperAnchorCopyForRepeatedTopFood() {
        let summary = FoodMirrorSummary(
            hasEnoughData:       true,
            learningProgress:    LearningProgress.from(thirtyDayLogCount: 30),
            thirtyDayLogCount:   30,
            sevenDayLogCount:    6,
            moodLogCount:        4,
            eatingIdentity:      "You're mostly exploring — but Sweet potato is becoming a reliable anchor.",
            weeklySummary:       nil,
            mostCommonFoods:     [FoodMirrorSummary.FoodCount(name: "Sweet potato", count: 6)],
            moodInsight:         nil,
            timingInsight:       nil,
            thisWeekChanged:     nil,
            todaysGentleNudge:   nil,
            suggestedExperiment: nil
        )
        let model = HomeMirrorPreview.cardModel(for: summary)
        XCTAssertEqual(model?.title, "Sweet potato is becoming a reliable anchor.")
        XCTAssertNotNil(model?.evidenceLine)
        XCTAssertTrue(model!.evidenceLine!.contains("6"),
                      "Anchor evidence should cite the log count")
    }

    // MARK: 10. contradiction guard

    /// The narrative policy must detect "rarely repeat" hero text
    /// against a 5+ top food count. Tests both the positive case
    /// (caught) and the negative case (no contradiction with a low
    /// top food count).
    func test_contradictionGuard_catchesExplorerVsAnchorConflict() {
        let bad = FoodOSNarrativePolicy.hasRarelyRepeatContradiction(
            hero: "You're an explorer — your meals rarely repeat.",
            topFoodCount: 6
        )
        XCTAssertTrue(bad)

        let ok = FoodOSNarrativePolicy.hasRarelyRepeatContradiction(
            hero: "You're an explorer — your meals rarely repeat.",
            topFoodCount: 2
        )
        XCTAssertFalse(ok)
    }

    // MARK: 11. copy safety rejects shame/medical/bossy/certainty

    func test_copySafety_rejectsShameMedicalBossyCertainty() {
        XCTAssertFalse(FoodOSCopySafety.isSafe("You must stop eating bad food."))
        XCTAssertFalse(FoodOSCopySafety.isSafe("This may lead to diabetes."))
        XCTAssertFalse(FoodOSCopySafety.isSafe("Don't be guilty about cheat day."))
        XCTAssertFalse(FoodOSCopySafety.isSafe("You always overeat."))
        // Calm copy passes
        XCTAssertTrue(FoodOSCopySafety.isSafe(
            "Sweet potato seems to be one of your reliable meals."
        ))
        XCTAssertTrue(FoodOSCopySafety.isSafe(
            "You logged 6 Sweet potato meals in the last 30 days."
        ))
    }

    // MARK: 12. weak-evidence softening

    func test_weakEvidence_usesSoftLanguage() {
        let strong = FoodOSNarrativePolicy.softenWeakEvidence(
            "Your dinners ran heavier this week.", isWeak: false
        )
        XCTAssertEqual(strong, "Your dinners ran heavier this week.")

        let soft = FoodOSNarrativePolicy.softenWeakEvidence(
            "Your dinners ran heavier this week.", isWeak: true
        )
        XCTAssertTrue(soft.lowercased().hasPrefix("looks like"))
    }

    // MARK: 13. every visible personal claim carries an evidenceLine

    /// Walk the recognition branch through the engine and confirm
    /// the surface always carries evidence. The legacy "every moment
    /// has evidence" test asserts non-nil only; this one asserts the
    /// evidence is *sharper* — naming the food + count.
    func test_recognitionMoment_carriesSpecificEvidence() {
        // 6 Sweet potato logs at the same hour + 6 unique fillers so
        // the engine clears the 8-log readiness floor, then the
        // priority chain falls through to recognition (no week
        // change, no mood notes, no slot pattern).
        var logs: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Sweet potato", daysAgo: $0, calories: 400)
        }
        logs += (7...12).map {
            Self.makeLog(name: "Other \($0)", daysAgo: $0, calories: 400)
        }
        let moment = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         Array(logs.prefix(3)),
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertEqual(moment.kind, .recognition)
        XCTAssertNotNil(moment.evidenceLine)
        XCTAssertTrue(moment.evidenceLine!.contains("Sweet potato"),
                      "Recognition evidence must name the food")
        XCTAssertTrue(moment.evidenceLine!.contains("6"),
                      "Recognition evidence must cite the count")
    }

    // MARK: 14. legacy behavior is unaffected for thin-data accounts

    /// A brand-new account (zero logs) must still render the
    /// learning state with the existing hardcoded copy — the
    /// storybuilder does not invent identity claims below the
    /// 5-log floor.
    func test_thinData_leavesIdentityNil() {
        let hero = FoodOSStoryBuilder.heroIdentityLine(
            thirtyDayLogCount: 2,
            topFoods:          [],
            uniqueFoodCount:   2
        )
        XCTAssertNil(hero)
    }

    // MARK: - actionLabel rendering policy (Phase 18.1)

    private func moment(actionLabel: String?,
                        body: String? = nil,
                        kind: FoodOSMoment.Kind = .recognition) -> FoodOSMoment {
        FoodOSMoment(
            kind: kind,
            title: "Title.",
            body: body,
            evidenceLine: "Based on your recent meals.",
            confidence: .medium,
            actionLabel: actionLabel,
            priorityScore: 50,
            generatedAt: Self.now
        )
    }

    /// nil and whitespace-only labels never render.
    func test_shouldRenderActionLabel_falseForNilOrEmpty() {
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(
            moment(actionLabel: nil)
        ))
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(
            moment(actionLabel: "")
        ))
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(
            moment(actionLabel: "   ")
        ))
    }

    /// Duplicate of body (case-insensitive, trimmed) suppresses the
    /// action — we don't echo the same sentence twice.
    func test_shouldRenderActionLabel_falseWhenDuplicatesBody() {
        let m = moment(
            actionLabel: "  Use it as today's anchor meal?  ",
            body: "use it as today's anchor meal?"
        )
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(m))
    }

    /// Valid, distinct action label renders.
    func test_shouldRenderActionLabel_trueForValidDistinctLabel() {
        let m = moment(
            actionLabel: "Use it as today's anchor meal?",
            body: "Some other supporting copy."
        )
        XCTAssertTrue(FoodOSStoryBuilder.shouldRenderActionLabel(m))
    }

    /// Banned phrases never reach the UI even if a future contributor
    /// hand-authors an unsafe action.
    func test_shouldRenderActionLabel_rejectsUnsafeCopy() {
        let m = moment(actionLabel: "You must stop eating like this.")
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(m))
    }

    // MARK: - Anchor recognition action label (engine output)

    /// Sweet potato 6× crosses the anchor floor → engine produces
    /// the "today's anchor meal" action, no body line, and the
    /// sharper title.
    func test_anchorRecognition_producesAnchorActionLabel() {
        var logs: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Sweet potato", daysAgo: $0, calories: 400)
        }
        logs += (7...12).map {
            Self.makeLog(name: "Other \($0)", daysAgo: $0, calories: 400)
        }
        let m = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         Array(logs.prefix(3)),
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertEqual(m.kind, .recognition)
        XCTAssertEqual(m.title, "Sweet potato seems to be one of your reliable meals.")
        XCTAssertNil(m.body,
                     "Anchor card relies on title + evidence + action; body adds clutter")
        XCTAssertNotNil(m.actionLabel)
        XCTAssertEqual(m.actionLabel, "Use it as today's anchor meal?")
        XCTAssertTrue(FoodOSStoryBuilder.shouldRenderActionLabel(m))
    }

    /// 3 logs is below the anchor floor — recognition still fires
    /// (count >= 3) but the engine intentionally returns nil for
    /// the action so the card stays a softer observation.
    func test_weakRecognition_omitsActionLabel() {
        var logs: [FoodLog] = (1...3).map {
            Self.makeLog(name: "Sweet potato", daysAgo: $0, calories: 400)
        }
        logs += (4...12).map {
            Self.makeLog(name: "Other \($0)", daysAgo: $0, calories: 400)
        }
        let m = FoodOSMomentEngine.compute(
            thirtyDayLogs:        logs,
            sevenDayLogs:         Array(logs.prefix(3)),
            previousSevenDayLogs: [],
            now:                  Self.now,
            timeZone:             Self.timeZone
        )
        XCTAssertEqual(m.kind, .recognition)
        XCTAssertNil(m.actionLabel,
                     "Weak recognition (count < anchor floor) must not surface an action")
        XCTAssertFalse(FoodOSStoryBuilder.shouldRenderActionLabel(m))
    }

    /// The recognition action label must survive FoodOSCopySafety
    /// — no banned fragments, no medical / shaming language.
    func test_anchorActionLabel_passesCopySafety() {
        let action = "Use it as today's anchor meal?"
        XCTAssertTrue(FoodOSCopySafety.isSafe(action))
        XCTAssertTrue(FoodOSMomentCopySafety.isSafe(action))
    }
}

// MARK: - Value revelations (mood-independent)
//
// These tests exercise the new dedicated revelations(...) entry point
// that produces mood and value revelations independently. The mood
// branch is the existing paired-belief output; the value branch is
// brand-new week-over-week trend output that must fire for flat-mood
// users (e.g., 37 loved / 1 fine) where the mood gate can't clear.

final class FoodOSValueRevelationTests: XCTestCase {

    private static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    private static let now = Date(timeIntervalSince1970: 1_730_000_000)

    /// Real-data shape: mood is essentially flat (loved across the
    /// board) so the paired-belief gate can't clear, but per-meal
    /// protein dropped from ~44g last week to ~25g this week. The
    /// value revelation card must fire; the mood card must stay nil.
    func test_flatMoodUser_seesValueCardAndNoMoodCard() {
        var thirtyDay: [FoodLog] = []
        let thisWeek: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25, mood: .loved)
        }
        let lastWeek: [FoodLog] = (8...13).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 44, mood: .loved)
        }
        // Pad the 30-day window with more flat-mood logs so the
        // engine has enough evidence to even consider the mood
        // branch (it won't qualify because mood is uniform — that's
        // the point).
        thirtyDay += thisWeek
        thirtyDay += lastWeek
        thirtyDay += (15...22).map {
            Self.makeLog(name: "Past \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 30, mood: .loved)
        }

        let revs = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thirtyDay,
            thisWeekLogs:  thisWeek,
            lastWeekLogs:  lastWeek,
            timeZone:      Self.timeZone,
            now:           Self.now
        )

        XCTAssertNil(revs.mood,
                     "Flat-mood user must NOT get a mood revelation card.")
        XCTAssertNotNil(revs.value,
                        "Flat-mood user WITH a real macro shift must see "
                        + "the value revelation card.")
        XCTAssertEqual(revs.value?.kind, .revelation)
        XCTAssertEqual(revs.value?.momentTag, .valueMacroTrend,
                       "Value moment should bucket into the macroTrend tag.")
        XCTAssertEqual(revs.valueRepeatKey, "macroTrend:protein")
        let title = revs.value?.title.lowercased() ?? ""
        XCTAssertTrue(title.contains("protein"))
        XCTAssertTrue(title.contains("dropped"))
        XCTAssertTrue(FoodOSMomentCopySafety.isSafe(
            title: revs.value?.title ?? "",
            body: revs.value?.body,
            evidence: revs.value?.evidenceLine
        ))
    }

    /// Mixed-mood user with strong time-of-day divergence AND a
    /// calorie shift across weeks — both cards must appear as
    /// distinct pages, each independently gated.
    func test_mixedMood_plusValueShift_bothCardsAppear() {
        // 30-day window: mornings strongly loved, afternoons tough.
        var thirtyDay: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, calories: 500, mood: .loved)
        }
        thirtyDay += (7...14).map {
            Self.makeLog(name: "Afternoon \($0)", daysAgo: $0,
                         hour: 14, calories: 500, mood: .tough)
        }

        let thisWeek: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Light \($0)", daysAgo: $0,
                         hour: 12, calories: 400, mood: .loved)
        }
        let lastWeek: [FoodLog] = (8...11).map {
            Self.makeLog(name: "Heavy \($0)", daysAgo: $0,
                         hour: 12, calories: 800, mood: .loved)
        }

        let revs = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thirtyDay,
            thisWeekLogs:  thisWeek,
            lastWeekLogs:  lastWeek,
            timeZone:      Self.timeZone,
            now:           Self.now
        )

        XCTAssertNotNil(revs.mood, "Mood card should fire on divergent mood.")
        XCTAssertNotNil(revs.value, "Value card should fire on calorie shift.")
        XCTAssertNotEqual(revs.mood, revs.value,
                          "Mood and value are independent moments.")
    }

    /// Mixed-mood user with divergence but flat macros across weeks
    /// — mood card appears, value card does not.
    func test_moodDivergent_butFlatMacros_onlyMoodCard() {
        var thirtyDay: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, calories: 500, mood: .loved)
        }
        thirtyDay += (7...14).map {
            Self.makeLog(name: "Afternoon \($0)", daysAgo: $0,
                         hour: 14, calories: 500, mood: .tough)
        }

        // Identical weeks — no week-over-week shift.
        let thisWeek: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Same \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25, carbsG: 50)
        }
        let lastWeek: [FoodLog] = (8...11).map {
            Self.makeLog(name: "Same \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25, carbsG: 50)
        }

        let revs = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thirtyDay,
            thisWeekLogs:  thisWeek,
            lastWeekLogs:  lastWeek,
            timeZone:      Self.timeZone,
            now:           Self.now
        )

        XCTAssertNotNil(revs.mood)
        XCTAssertNil(revs.value,
                     "Flat macros must NOT produce a value revelation.")
    }

    /// Below-threshold value shift (< 18% relative change on all
    /// axes) must keep the value card hidden.
    func test_valueChangeBelowThreshold_noCard() {
        let thisWeek: [FoodLog] = (1...4).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 510,
                         proteinG: 25, carbsG: 50)
        }
        let lastWeek: [FoodLog] = (8...11).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 26, carbsG: 51)
        }

        XCTAssertNil(
            FoodOSPairedBeliefs.bestValueCandidate(
                thisWeek: thisWeek,
                lastWeek: lastWeek
            ),
            "Tiny week-over-week wobbles must stay below the surprise gate."
        )
    }

    /// Suppression: the same value subject should not repeat on the
    /// next refresh when the caller passes back its repeat key.
    func test_valueRevelation_doesNotRepeatSameSubject() {
        let thisWeek: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25)
        }
        let lastWeek: [FoodLog] = (8...13).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 44)
        }

        let first = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thisWeek + lastWeek,
            thisWeekLogs:  thisWeek,
            lastWeekLogs:  lastWeek,
            timeZone:      Self.timeZone,
            now:           Self.now
        )
        XCTAssertNotNil(first.value)

        let second = FoodOSMomentEngine.revelations(
            thirtyDayLogs:      thisWeek + lastWeek,
            thisWeekLogs:       thisWeek,
            lastWeekLogs:       lastWeek,
            timeZone:           Self.timeZone,
            now:                Self.now,
            lastValueRepeatKey: first.valueRepeatKey
        )
        XCTAssertNil(second.value,
                     "Value revelation must not repeat the same subject.")
    }

    /// Copy safety: every value-revelation subtype must produce
    /// strings that clear the safety filter. Drives directly off the
    /// pure candidate factory so we don't depend on the engine wrap.
    func test_valueRevelationCopy_passesSafetyAcrossSubtypes() {
        // macroTrend
        var thisWeek: [FoodLog] = (1...4).map {
            Self.makeLog(name: "A\($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25)
        }
        var lastWeek: [FoodLog] = (8...11).map {
            Self.makeLog(name: "B\($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 44)
        }
        assertCandidateSafe(
            FoodOSPairedBeliefs.bestValueCandidate(
                thisWeek: thisWeek, lastWeek: lastWeek)
        )

        // calorieTrend (no macro divergence)
        thisWeek = (1...4).map {
            Self.makeLog(name: "A\($0)", daysAgo: $0,
                         hour: 12, calories: 350,
                         proteinG: 25, carbsG: 40)
        }
        lastWeek = (8...11).map {
            Self.makeLog(name: "B\($0)", daysAgo: $0,
                         hour: 12, calories: 700,
                         proteinG: 25, carbsG: 40)
        }
        assertCandidateSafe(
            FoodOSPairedBeliefs.bestValueCandidate(
                thisWeek: thisWeek, lastWeek: lastWeek)
        )

        // consistency
        thisWeek = (1...12).map {
            Self.makeLog(name: "A\($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25)
        }
        lastWeek = [Self.makeLog(name: "B", daysAgo: 10,
                                 hour: 12, calories: 500,
                                 proteinG: 25)]
        assertCandidateSafe(
            FoodOSPairedBeliefs.bestValueCandidate(
                thisWeek: thisWeek, lastWeek: lastWeek)
        )

        // varietyTrend
        thisWeek = (1...8).map {
            Self.makeLog(name: "Distinct \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25)
        }
        lastWeek = (8...15).map { _ in
            Self.makeLog(name: "Same", daysAgo: 10,
                         hour: 12, calories: 500,
                         proteinG: 25)
        }
        assertCandidateSafe(
            FoodOSPairedBeliefs.bestValueCandidate(
                thisWeek: thisWeek, lastWeek: lastWeek)
        )
    }

    // MARK: - Reveal payload (Direction B two-bar UI)

    /// A value revelation carries the raw before/after numbers, the
    /// display unit, and a correctly-signed delta percent so the
    /// two-bar card can render without re-parsing the title.
    func test_valueRevelation_revealCarriesBeforeAfterAndDelta() {
        let thisWeek: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 25, mood: .loved)
        }
        let lastWeek: [FoodLog] = (8...13).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500,
                         proteinG: 44, mood: .loved)
        }
        let revs = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thisWeek + lastWeek,
            thisWeekLogs:  thisWeek,
            lastWeekLogs:  lastWeek,
            timeZone:      Self.timeZone,
            now:           Self.now
        )

        let reveal = revs.value?.reveal
        XCTAssertNotNil(reveal,
                        "Value revelations must carry the reveal payload.")
        XCTAssertEqual(reveal?.before, 44,
                       "before = last week's avg protein (g).")
        XCTAssertEqual(reveal?.after, 25,
                       "after  = this week's avg protein (g).")
        XCTAssertEqual(reveal?.unit, "g")
        // (25 - 44) / 44 ≈ -0.4318 → rounds to -43.
        XCTAssertEqual(reveal?.deltaPercent, -43,
                       "Dropped values must report a negative delta.")
    }

    /// Mood revelations have no before/after to chart — their `reveal`
    /// payload must remain nil so the card UI falls into the calm
    /// (no-bars) variant.
    func test_moodRevelation_revealIsNil() {
        var thirtyDay: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Morning \($0)", daysAgo: $0,
                         hour: 8, calories: 500, mood: .loved)
        }
        thirtyDay += (7...14).map {
            Self.makeLog(name: "Afternoon \($0)", daysAgo: $0,
                         hour: 14, calories: 500, mood: .tough)
        }
        let revs = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thirtyDay,
            thisWeekLogs:  thirtyDay,
            lastWeekLogs:  thirtyDay,
            timeZone:      Self.timeZone,
            now:           Self.now
        )
        XCTAssertNotNil(revs.mood, "Mood card should fire on divergent mood.")
        XCTAssertNil(revs.mood?.reveal,
                     "Mood cards carry no two-bar reveal.")
    }

    /// Climbing values must report a positive delta percent so the
    /// pill's arrow points up.
    func test_valueRevelation_climbingProducesPositiveDelta() {
        let thisWeek: [FoodLog] = (1...6).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 800, mood: .loved)
        }
        let lastWeek: [FoodLog] = (8...13).map {
            Self.makeLog(name: "Meal \($0)", daysAgo: $0,
                         hour: 12, calories: 500, mood: .loved)
        }
        let revs = FoodOSMomentEngine.revelations(
            thirtyDayLogs: thisWeek + lastWeek,
            thisWeekLogs:  thisWeek,
            lastWeekLogs:  lastWeek,
            timeZone:      Self.timeZone,
            now:           Self.now
        )
        XCTAssertNotNil(revs.value?.reveal)
        XCTAssertGreaterThan(revs.value?.reveal?.deltaPercent ?? 0, 0)
        XCTAssertEqual(revs.value?.reveal?.unit, "kcal")
    }

    // MARK: helpers

    private func assertCandidateSafe(
        _ candidate: FoodOSPairedBeliefs.ValueCandidate?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let c = candidate else {
            XCTFail("Expected a value candidate to assert safety on",
                    file: file, line: line)
            return
        }
        XCTAssertTrue(
            FoodOSMomentCopySafety.isSafe(
                title: c.title,
                body: c.body,
                evidence: c.evidenceLine
            ),
            "Value candidate copy must pass safety filter: \(c.title)",
            file: file, line: line
        )
    }

    private static func makeLog(name: String,
                                daysAgo: Int,
                                hour: Int = 12,
                                calories: Double = 500,
                                proteinG: Double? = 20,
                                carbsG: Double = 50,
                                sugarG: Double = 5,
                                mood: FoodLog.Mood? = nil) -> FoodLog {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour; comps.minute = 0; comps.timeZone = timeZone
        let dt = cal.date(from: comps) ?? day
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: calories,
            carbsG: carbsG,
            sugarG: sugarG,
            proteinG: proteinG,
            fatG: 15,
            fiberG: 5,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: dt,
            createdAt: dt,
            origin: .analyzed,
            sourceLogId: nil,
            mood: mood
        )
    }
}
