import Foundation

/// Phase 17. Pure helper: takes a list of `FoodLog`s and infers the
/// user's typical breakfast / lunch / dinner times in their local
/// timezone. No network, no DB, no `MealHistoryService` coupling —
/// the caller fetches logs and hands them in.
///
/// Approach (intentionally simple):
///   1. Bucket logs by (hour, minute) in the user's timezone.
///   2. Within each meal-of-day window (breakfast 04:00-09:59,
///      lunch 10:00-14:59, dinner 15:00-21:59), find the densest hour.
///   3. Within the densest hour, find the most-frequent minute.
///   4. Emit a `DateComponents(hour:minute:)` for each window that
///      had at least one log; nil for windows the user never logs.
///
/// The minute granularity matters for "feels personal": a user who
/// logs lunch at 12:15 most days gets a 12:15 reminder, not 12:00.
///
/// Confidence is a function of total log count over the input window
/// (typically last 30 days, but this helper doesn't enforce that —
/// the caller picks the lookback). Fewer than 5 logs => `.insufficient`
/// and we return *defaults* (08:00/12:30/19:00) so the UI can still
/// show suggestions; 5–14 => `.low` (use real distribution but warn
/// the UI it's thin); 15+ => `.good`.
enum EatingTimeInference {
    struct InferredTimes: Equatable {
        /// Hour + minute in the user's timezone. `nil` for a window
        /// the user has never logged in.
        let breakfast: DateComponents?
        let lunch: DateComponents?
        let dinner: DateComponents?
        let confidence: Confidence
    }

    enum Confidence: Equatable {
        case insufficient
        case low
        case good
    }

    /// Default suggestions used when confidence is `.insufficient`.
    /// Match the prompt's "fallback to defaults with light adjustment"
    /// guidance — no adjustment in v1, just static reasonable times.
    static let defaultBreakfast = DateComponents(hour: 8,  minute: 0)
    static let defaultLunch     = DateComponents(hour: 12, minute: 30)
    static let defaultDinner    = DateComponents(hour: 19, minute: 0)

    /// Hour ranges (inclusive lower, inclusive upper) used to assign a
    /// log to a meal window. Tweak with care — too-narrow windows leave
    /// snacks unbucketed; too-wide windows merge meals.
    enum Window: CaseIterable {
        case breakfast, lunch, dinner

        var hourRange: ClosedRange<Int> {
            switch self {
            case .breakfast: return 4...9
            case .lunch:     return 10...14
            case .dinner:    return 15...21
            }
        }
    }

    static func infer(from logs: [FoodLog],
                      timeZone: TimeZone = .current) -> InferredTimes {
        let confidence: Confidence
        switch logs.count {
        case 0..<5:   confidence = .insufficient
        case 5..<15:  confidence = .low
        default:      confidence = .good
        }

        // For .insufficient confidence the caller wants defaults.
        // Returning real (sparse) inference here would make the
        // settings UI show a 9pm "lunch" because the user happened to
        // log a single late dinner — net negative.
        guard confidence != .insufficient else {
            return InferredTimes(
                breakfast:  defaultBreakfast,
                lunch:      defaultLunch,
                dinner:     defaultDinner,
                confidence: .insufficient
            )
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        // Bucket logs by (hour, minute).
        var byHour: [Int: [Int]] = [:] // hour -> [minutes]
        for log in logs {
            let comps = cal.dateComponents([.hour, .minute], from: log.eatenAt)
            guard let h = comps.hour, let m = comps.minute else { continue }
            byHour[h, default: []].append(m)
        }

        let breakfast = pickTime(in: Window.breakfast.hourRange, from: byHour,
                                 fallback: defaultBreakfast)
        let lunch     = pickTime(in: Window.lunch.hourRange,     from: byHour,
                                 fallback: defaultLunch)
        let dinner    = pickTime(in: Window.dinner.hourRange,    from: byHour,
                                 fallback: defaultDinner)

        return InferredTimes(
            breakfast:  breakfast,
            lunch:      lunch,
            dinner:     dinner,
            confidence: confidence
        )
    }

    /// Find the densest hour in the given range (most logs), then the
    /// most-frequent minute within that hour. Ties broken by the
    /// earliest hour / minute (deterministic so reschedules don't
    /// flutter). Returns `fallback` when the range has zero logs —
    /// matches the .insufficient-confidence branch so a user whose
    /// logs all fall outside any meal window still gets a usable
    /// default per window instead of a silently-skipped reminder.
    private static func pickTime(in hourRange: ClosedRange<Int>,
                                 from byHour: [Int: [Int]],
                                 fallback: DateComponents) -> DateComponents {
        var bestHour: Int?
        var bestHourCount = 0
        for h in hourRange {
            let count = byHour[h]?.count ?? 0
            if count > bestHourCount {
                bestHourCount = count
                bestHour = h
            }
        }
        guard let bestHour, let minutes = byHour[bestHour], !minutes.isEmpty else {
            return fallback
        }

        // Most-frequent minute. Ties → earliest minute, so 12:00 beats
        // 12:30 when each appears once but the user has more 12:00
        // logs in the surrounding hour. Within the same hour bucket
        // this keeps reminders from drifting later over time.
        var minuteCounts: [Int: Int] = [:]
        for m in minutes { minuteCounts[m, default: 0] += 1 }
        let bestMinute = minuteCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first?.key ?? 0

        return DateComponents(hour: bestHour, minute: bestMinute)
    }
}
