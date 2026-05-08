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
