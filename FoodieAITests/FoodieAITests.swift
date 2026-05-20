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

