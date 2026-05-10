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
