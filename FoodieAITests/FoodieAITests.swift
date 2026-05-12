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
