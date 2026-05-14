import Foundation
import Combine

/// Local-only "logging rhythm" signal. Tracks the set of local calendar
/// days on which the user saved at least one meal so the Home check-in
/// can read continuity without database or schema changes.
///
/// Storage shape: `Set<String>` of `yyyy-MM-dd` keys persisted to
/// `UserDefaults`. Days are computed in the user's *current* time zone
/// at write/read time — consistent with the rest of the app's local-day
/// rule (`FoodLogService.todaysLogs`). Crossing time zones can shift
/// where a date falls; that is acceptable for an enrichment signal.
///
/// Public surface is intentionally narrow:
///   - `markToday()` — call on save success
///   - `rhythm(now:)` — pure, deterministic read for the UI
///
/// `@Published` so views can observe the result of `markToday()` without
/// re-fetching from disk.
@MainActor
final class LoggingRhythmStore: ObservableObject {
    static let shared = LoggingRhythmStore()

    /// Hydrated set of `yyyy-MM-dd` day-keys. Order is irrelevant.
    @Published private(set) var loggedDays: Set<String> = []

    private let defaults: UserDefaults
    private let storageKey = "foodie.loggingRhythm.v1"

    /// Cap on persisted entries so the array can't grow forever. ~400
    /// days covers any plausible rhythm window (consecutive-day counts
    /// rarely exceed a few weeks); older entries are pruned on write.
    private let retentionCap = 400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.array(forKey: storageKey) as? [String] {
            self.loggedDays = Set(saved)
        }
    }

    /// Mark today (local) as a logged day. Idempotent — repeated calls
    /// within the same calendar day are a no-op past the first.
    func markToday(now: Date = Date(),
                   calendar: Calendar = .current) {
        let key = Self.dayKey(for: now, calendar: calendar)
        guard !loggedDays.contains(key) else { return }
        loggedDays.insert(key)
        persist()
    }

    /// Pure read for the UI. `now` is parameterized for tests / previews;
    /// production callers should let it default to `Date()`.
    func rhythm(now: Date = Date(),
                calendar: Calendar = .current) -> Rhythm {
        let todayKey = Self.dayKey(for: now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterdayKey = Self.dayKey(for: yesterday, calendar: calendar)

        let todayLogged = loggedDays.contains(todayKey)
        let yesterdayLogged = loggedDays.contains(yesterdayKey)

        // Consecutive run ending today or yesterday. We don't try to
        // detect runs that ended further back — the copy doesn't use
        // them and a stale "5-day rhythm" from two weeks ago would feel
        // dishonest.
        let consecutive: Int = {
            let anchor: Date
            if todayLogged {
                anchor = now
            } else if yesterdayLogged {
                anchor = yesterday
            } else {
                return 0
            }
            var count = 0
            var cursor = anchor
            while loggedDays.contains(
                Self.dayKey(for: cursor, calendar: calendar)
            ) {
                count += 1
                guard let prev = calendar.date(
                    byAdding: .day, value: -1, to: cursor
                ) else { break }
                cursor = prev
            }
            return count
        }()

        // Last logged date (any). Used by the personalized empty state.
        let lastLogged: Date? = {
            // Cheap path: today or yesterday.
            if todayLogged { return calendar.startOfDay(for: now) }
            if yesterdayLogged { return calendar.startOfDay(for: yesterday) }
            // Walk back up to 30 days; anything older isn't useful copy.
            for offset in 2...30 {
                guard let d = calendar.date(
                    byAdding: .day, value: -offset, to: now
                ) else { break }
                if loggedDays.contains(
                    Self.dayKey(for: d, calendar: calendar)
                ) {
                    return calendar.startOfDay(for: d)
                }
            }
            return nil
        }()

        return Rhythm(
            todayLogged: todayLogged,
            yesterdayLogged: yesterdayLogged,
            consecutiveDays: consecutive,
            lastLoggedDate: lastLogged,
            totalLoggedDays: loggedDays.count
        )
    }

    // MARK: - Persistence

    private func persist() {
        // Prune to the most recent `retentionCap` entries before writing.
        // Sort by key — `yyyy-MM-dd` strings sort lexicographically the
        // same as their dates.
        let trimmed: [String]
        if loggedDays.count > retentionCap {
            let sorted = loggedDays.sorted()
            trimmed = Array(sorted.suffix(retentionCap))
            loggedDays = Set(trimmed)
        } else {
            trimmed = Array(loggedDays)
        }
        defaults.set(trimmed, forKey: storageKey)
    }

    // MARK: - Key formatting

    /// `yyyy-MM-dd` in the user's current time zone. POSIX locale +
    /// gregorian calendar so the formatter never depends on the user's
    /// region settings (which can flip the day boundary).
    private static func dayKey(for date: Date,
                               calendar: Calendar) -> String {
        let f = Self.formatter(for: calendar)
        return f.string(from: date)
    }

    /// Per-call DateFormatter so the time zone matches the supplied
    /// calendar's. Cheap (no ICU rebootstrap at this scale), and keeps
    /// the formatter from drifting if the user's region changes mid-
    /// session.
    private static func formatter(for calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    // MARK: - Rhythm

    /// Snapshot of the current rhythm state. Pure data — the copy
    /// decision lives in the view layer so non-shaming wording stays
    /// adjacent to the design.
    struct Rhythm: Equatable {
        let todayLogged: Bool
        let yesterdayLogged: Bool
        /// Run of consecutive days ending today or yesterday. `0` when
        /// the user has neither logged today nor yesterday.
        let consecutiveDays: Int
        /// Most recent logged day at midnight local; `nil` if the user
        /// has never logged. Older than 30 days resolves to `nil` so
        /// the empty-state copy doesn't surface dust.
        let lastLoggedDate: Date?
        /// Lifetime count of distinct logged days. Used to detect the
        /// "first ever" check-in vs. "back from yesterday".
        let totalLoggedDays: Int
    }
}
