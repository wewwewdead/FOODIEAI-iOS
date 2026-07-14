import Foundation

// NOVEL_DIRECTIONS Idea 2 — the data step that turns raw meal history into the
// `[TwinMeal]` repertoire `MealTwinEngine` needs. Pure + local + testable.
//
// It reuses existing primitives: `MealSuggestionEngine.MealSlot.forHour` for the
// eating window and `FoodOSBeliefEngine.moodBelief` for the per-dish mood
// posterior. A dish only carries a real mood rate once it has enough evidence
// (≥ 3 mood-noted occurrences); otherwise it reports 0.5 (neutral), which makes
// the engine's mood term a no-op for that dish so it falls back to pure goal fit.

enum TwinMealBuilder {

    /// Deterministic chronological order for slot tie-breaks.
    private static func order(_ slot: MealSuggestionEngine.MealSlot) -> Int {
        switch slot {
        case .breakfast: return 0
        case .lunch:     return 1
        case .dinner:    return 2
        case .snack:     return 3
        }
    }

    /// Build the user's meal repertoire from raw recent history (e.g. the last
    /// ~30 days from `FoodLogService.logs(from:to:)`). Dishes are grouped by
    /// case-insensitive name; the most-frequent `maxMeals` are kept.
    static func build(from logs: [FoodLog],
                      timeZone: TimeZone = .current,
                      maxMeals: Int = 12) -> [TwinMeal] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        // Group by normalized name.
        var groups: [String: [FoodLog]] = [:]
        for log in logs {
            let key = log.foodName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(log)
        }

        var scored: [(meal: TwinMeal, count: Int)] = []
        for (_, groupLogs) in groups {
            guard let slot = modalSlot(groupLogs, calendar: cal) else { continue }
            // Display name = most recent occurrence (preserves the user's casing).
            let displayName = groupLogs
                .max(by: { $0.eatenAt < $1.eatenAt })?.foodName
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !displayName.isEmpty else { continue }

            let meanCalories = groupLogs.map(\.calories).reduce(0, +) / Double(groupLogs.count)
            guard meanCalories > 0 else { continue }

            let belief = FoodOSBeliefEngine.moodBelief(in: groupLogs)
            let moodRate = belief.hasEnoughEvidence ? belief.posteriorPositiveMean : 0.5

            scored.append((TwinMeal(name: displayName,
                                    calories: meanCalories,
                                    slot: slot,
                                    moodPositiveRate: moodRate),
                           groupLogs.count))
        }

        // Most-frequent first; deterministic tie-break by name so results are stable.
        scored.sort { a, b in
            a.count != b.count ? a.count > b.count : a.meal.name.lowercased() < b.meal.name.lowercased()
        }
        return Array(scored.prefix(max(0, maxMeals)).map(\.meal))
    }

    /// The eating window a dish most often lands in. Overnight-only dishes
    /// (`forHour` nil for 00–03) are dropped. Tie-break: earlier slot wins.
    private static func modalSlot(_ logs: [FoodLog],
                                  calendar: Calendar) -> MealSuggestionEngine.MealSlot? {
        var counts: [MealSuggestionEngine.MealSlot: Int] = [:]
        for log in logs {
            let hour = calendar.component(.hour, from: log.eatenAt)
            if let slot = MealSuggestionEngine.MealSlot.forHour(hour) {
                counts[slot, default: 0] += 1
            }
        }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : order(a.key) > order(b.key)
        }?.key
    }
}
