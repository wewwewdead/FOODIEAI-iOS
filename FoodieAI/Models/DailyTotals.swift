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
///
/// Phase 11: protein/fat/fiber added. Pre-Phase-11 rows have nil for these
/// columns; the aggregation treats nil as 0 — meals with unknown values
/// conservatively contribute nothing rather than guessing.
struct LocalDailyTotals: Hashable {
    var entries: Int
    var totalCalories: Double
    var totalCarbs: Double
    var totalSugar: Double
    var totalProtein: Double
    var totalFat: Double
    var totalFiber: Double

    static let empty = LocalDailyTotals(
        entries: 0,
        totalCalories: 0, totalCarbs: 0, totalSugar: 0,
        totalProtein: 0, totalFat: 0, totalFiber: 0
    )

    static func sum(_ logs: [FoodLog]) -> LocalDailyTotals {
        logs.reduce(into: .empty) { acc, log in
            acc.entries += 1
            acc.totalCalories += log.calories
            acc.totalCarbs    += log.carbsG
            acc.totalSugar    += log.sugarG
            acc.totalProtein  += log.proteinG ?? 0
            acc.totalFat      += log.fatG ?? 0
            acc.totalFiber    += log.fiberG ?? 0
        }
    }

    /// Alias used by Phase 9 history views to make call sites read naturally.
    static func from(_ logs: [FoodLog]) -> LocalDailyTotals { sum(logs) }
}

/// One day's bucket of logs in the user's local time zone, used by Week and
/// Month history views. `date` is start-of-day local for the bucket.
/// Identifiable on `date` so SwiftUI Charts and ForEach can iterate cheaply.
struct DailyBucket: Identifiable, Hashable {
    let date: Date
    let logs: [FoodLog]

    var id: Date { date }
    var totals: LocalDailyTotals { LocalDailyTotals.from(logs) }
    var hasLogs: Bool { !logs.isEmpty }
}

enum DailyBucketing {
    /// Buckets `logs` by local day for every day in the half-open range
    /// `[from, to)`, including empty days. Caller passes start-of-day-local for
    /// `from` and start-of-day-local for the day *after* the last day to include.
    /// Result is chronological (oldest first).
    static func bucket(_ logs: [FoodLog],
                       from: Date,
                       to: Date,
                       calendar: Calendar) -> [DailyBucket] {
        // Group logs by their start-of-day-local key once, then walk the range.
        var byDay: [Date: [FoodLog]] = [:]
        for log in logs {
            let day = calendar.startOfDay(for: log.eatenAt)
            byDay[day, default: []].append(log)
        }

        var result: [DailyBucket] = []
        var cursor = calendar.startOfDay(for: from)
        let stop = calendar.startOfDay(for: to)
        while cursor < stop {
            let dayLogs = (byDay[cursor] ?? []).sorted { $0.eatenAt < $1.eatenAt }
            result.append(DailyBucket(date: cursor, logs: dayLogs))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}
