import Foundation

/// Mirrors public.daily_food_totals.
///
/// Note: this view buckets by **UTC date**. The iOS Tracker computes its own
/// local-day totals by querying food_logs directly with a local-day range
/// (per Phase 0 Q2 decision). Keep this struct around for occasional use,
/// e.g. a "this week, by UTC day" debug screen.
struct DailyTotals: Codable, Hashable {
    let userId: UUID
    let day: Date
    let entries: Int
    let totalCalories: Double
    let totalCarbs: Double
    let totalSugar: Double
    let totalProtein: Double
    let totalFat: Double
    let totalFiber: Double

    enum CodingKeys: String, CodingKey {
        case userId        = "user_id"
        case day, entries
        case totalCalories = "total_calories"
        case totalCarbs    = "total_carbs"
        case totalSugar    = "total_sugar"
        case totalProtein  = "total_protein"
        case totalFat      = "total_fat"
        case totalFiber    = "total_fiber"
    }
}

/// Locally-computed totals (sum over food_logs in a local-day range).
/// Used by the Tracker header card.
struct LocalDailyTotals: Hashable {
    var entries: Int
    var totalCalories: Double
    var totalCarbs: Double
    var totalSugar: Double

    static let empty = LocalDailyTotals(
        entries: 0, totalCalories: 0, totalCarbs: 0, totalSugar: 0
    )

    static func sum(_ logs: [FoodLog]) -> LocalDailyTotals {
        logs.reduce(into: .empty) { acc, log in
            acc.entries += 1
            acc.totalCalories += log.calories
            acc.totalCarbs += log.carbsG
            acc.totalSugar += log.sugarG
        }
    }
}
