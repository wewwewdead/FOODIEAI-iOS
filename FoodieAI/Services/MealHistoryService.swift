import Foundation
import Supabase

/// Phase 15 — single entry point for "food memory" reads against
/// `food_logs`. Three concerns:
///
///   1. `priorOccurrences(of:excluding:)` — repeat detection on the
///      Result screen ("you've had this 3 times").
///   2. `recentUniqueMeals(limit:)` — deduplicated recents picker for
///      Quick Re-log.
///   3. `patternsForToday()` — 0–2 lightweight observations for the
///      Today screen's Patterns section.
///
/// Everything funnels through `food_logs` — no new tables. RLS handles
/// per-user isolation, so no `user_id` filter is needed in any query
/// here. Future phases (coach continuity in Phase 16, weekly recap in
/// Phase 17) read from this same surface.
///
/// Case sensitivity: all three surfaces are case-insensitive.
///   - `priorOccurrences` uses Postgres `ILIKE` against an escaped
///     food name (no wildcards passed through).
///   - `recentUniqueMeals` dedupes by `foodName.lowercased()`.
///   - `patternsForToday` groups by `foodName.lowercased()`.
/// This keeps repeat-detection, the picker, and the patterns card
/// agreeing on identity — without this, a row of "Margherita Pizza"
/// plus a row of "margherita pizza" would show as 2 in patterns and
/// 1 in the chip on the same screen. A future cleanup may add a
/// `food_name_lower` generated column or migrate to `citext`, but the
/// per-query `ilike` keeps v1 honest with no schema change.
actor MealHistoryService {
    private let client: SupabaseClient

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    // MARK: - Repeat detection

    /// All prior saved occurrences of `foodName` for the signed-in user.
    /// Optionally excludes `currentLogId` so the just-saved row isn't
    /// counted as a "prior" of itself.
    ///
    /// Ordered newest-first so callers can read `.first?.eatenAt` for
    /// the "last time" line.
    func priorOccurrences(of foodName: String,
                          excluding currentLogId: UUID? = nil) async throws -> [FoodLog] {
        let trimmed = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Use ILIKE against the escaped, un-wildcarded value so the
        // comparison is case-insensitive but exact in length. Without
        // escaping, a food name containing `%` or `_` would behave like
        // a wildcard match. Real food names never carry these, but
        // defensive escaping is cheap.
        let pattern = Self.escapeLikePattern(trimmed)

        var query = client
            .from("food_logs")
            .select()
            .ilike("food_name", pattern: pattern)

        if let currentLogId {
            query = query.neq("id", value: currentLogId)
        }

        return try await query
            .order("eaten_at", ascending: false)
            .execute()
            .value
    }

    /// Escape `%`, `_`, and `\` so a value can be passed to ILIKE as a
    /// literal. Order matters: escape backslashes first.
    static func escapeLikePattern(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: #"\"#, with: #"\\"#)
        out = out.replacingOccurrences(of: "%", with: #"\%"#)
        out = out.replacingOccurrences(of: "_", with: #"\_"#)
        return out
    }

    // MARK: - Recent unique meals (Quick Re-log picker)

    /// Most recent saved meals, deduplicated by food name (newest
    /// instance per name kept). Used to populate the Quick Re-log
    /// picker — the user shouldn't see "Oatmeal" listed eight times.
    ///
    /// We pull the last 30 days then dedup client-side; PostgREST has
    /// no first-class DISTINCT ON and the volumes here are small
    /// (a single user's 30 days of meals — typically <100 rows).
    func recentUniqueMeals(limit: Int = 12) async throws -> [FoodLog] {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -30, to: Date()
        ) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let logs: [FoodLog] = try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: cutoff))
            .order("eaten_at", ascending: false)
            .execute()
            .value

        var seen = Set<String>()
        var unique: [FoodLog] = []
        unique.reserveCapacity(min(logs.count, limit))
        for log in logs {
            let key = log.foodName.lowercased()
            if seen.insert(key).inserted {
                unique.append(log)
                if unique.count >= limit { break }
            }
        }
        return unique
    }

    // MARK: - Coach context (Phase 16)

    /// Up to 14 of the user's most recent meals from the last 14 days,
    /// newest-first. Used as `recent_meals` context on `/analyze` so
    /// the coach can reference repetition. Strict cap so the multipart
    /// payload stays small — the server re-bounds defensively.
    func recentMealsForCoachContext() async throws -> [FoodLog] {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -14, to: Date()
        ) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: cutoff))
            .order("eaten_at", ascending: false)
            .limit(14)
            .execute()
            .value
    }

    /// Phase 18 — up to 10 of the user's most recent mood-labeled
    /// meals, newest-first. Mirrors `recentMealsForCoachContext` but
    /// filters to rows with a non-null `mood`. Tighter cap than
    /// recent-meals (10 vs. 14) because mood signal compounds and too
    /// many entries produce noisy patterns; the server re-bounds
    /// defensively.
    func recentMoodsForCoachContext() async throws -> [FoodLog] {
        try await client
            .from("food_logs")
            .select()
            .not("mood", operator: .is, value: "null")
            .order("eaten_at", ascending: false)
            .limit(10)
            .execute()
            .value
    }

    /// Phase 18 — mood log surface on the Profile screen. Returns the
    /// last 30 days of mood-labeled meals, newest-first. Optionally
    /// filtered to a single mood. Larger cap than the coach-context
    /// path because this is a user-facing list.
    func moodLog(filter: FoodLog.Mood? = nil,
                 limit: Int = 200) async throws -> [FoodLog] {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -30, to: Date()
        ) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var query = client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: cutoff))
            .not("mood", operator: .is, value: "null")

        if let filter {
            query = query.eq("mood", value: filter.rawValue)
        }

        return try await query
            .order("eaten_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    // MARK: - Patterns

    /// 0–2 observations about the user's recent eating to surface in the
    /// Today screen's Patterns section. Keep simple, deterministic, and
    /// honest — return `[]` if nothing useful, never manufacture filler.
    ///
    /// v1 rules (in priority order):
    ///   - "frequent": any food name appearing 3+ times in the last 14
    ///     days. Detail mentions a weekday cluster if 3 of N occurrences
    ///     fall on the same weekday.
    ///   - "firstThisWeek": any food in the last 7 days that doesn't
    ///     appear in the prior 7 days (8–14 days ago).
    ///
    /// The pattern-analysis logic is the highest-judgment code in this
    /// phase. It's a pure function of `[FoodLog]` so future phases can
    /// move it server-side without touching the call site.
    func patternsForToday(now: Date = Date()) async throws -> [Pattern] {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -14, to: now) else {
            return []
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let logs: [FoodLog] = try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: cutoff))
            .order("eaten_at", ascending: false)
            .execute()
            .value

        return Self.analyzePatterns(logs: logs, now: now, calendar: cal)
    }

    /// Phase 17 — patterns for an arbitrary closed range. Used by the
    /// weekly recap generator: `analyzePatterns` runs against the
    /// week's logs only, so the recap's "top pattern" is the
    /// week-level dominant repetition rather than the trailing-14-day
    /// one. Range is half-open `[from, to)` matching `FoodLogService.logs`.
    func patternsForRange(from: Date, to: Date) async throws -> [Pattern] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let logs: [FoodLog] = try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: from))
            .lt ("eaten_at", value: f.string(from: to))
            .order("eaten_at", ascending: false)
            .execute()
            .value

        // Use `to` as the analyzer's "now" so the firstThisWeek logic
        // (which compares last-7-days vs. the prior 7) bisects against
        // the end of the analyzed range, not Date().
        return Self.analyzePatterns(logs: logs, now: to, calendar: .current)
    }

    // MARK: - Pattern analysis (pure)

    /// Pure function. Deterministic given the same inputs. Tested via
    /// the call paths but easy to unit-test directly if regressions
    /// turn up. Cap at 2 patterns. Prefer `.frequent` over
    /// `.firstThisWeek` when both fire.
    static func analyzePatterns(logs: [FoodLog],
                                now: Date,
                                calendar: Calendar) -> [Pattern] {
        guard !logs.isEmpty else { return [] }

        var patterns: [Pattern] = []

        // ---- Frequent (3+ occurrences in last 14d) -------------------
        // Group by lowercased food name; keep a representative original
        // casing for the title.
        var counts: [String: (display: String, dates: [Date])] = [:]
        for log in logs {
            let key = log.foodName.lowercased()
            counts[key, default: (log.foodName, [])].dates.append(log.eatenAt)
        }

        // Sort by count descending so the strongest pattern wins the
        // single "frequent" slot.
        let frequents = counts
            .filter { $0.value.dates.count >= 3 }
            .sorted { $0.value.dates.count > $1.value.dates.count }

        if let top = frequents.first {
            let n = top.value.dates.count
            let title = "You've had \(top.value.display) \(n) times in the last two weeks."
            let detail = weekdayClusterDetail(
                dates: top.value.dates, calendar: calendar
            )
            patterns.append(Pattern(
                id: "frequent:\(top.key)",
                kind: .frequent,
                title: title,
                detail: detail
            ))
        }

        // ---- Mood cluster (Phase 18) --------------------------------
        // 3+ meals with mood='tough' in the last 7 days. v1 deliberately
        // only emits this for `tough`: clustering on `loved` would feel
        // like the app applauding the user's eating; `fine` is the
        // boring middle and produces noisy filler.
        if patterns.count < 2,
           let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
            let toughCount = logs.lazy
                .filter { $0.eatenAt >= weekAgo && $0.mood == .tough }
                .count
            if toughCount >= 3 {
                patterns.append(Pattern(
                    id: "moodCluster:tough",
                    kind: .moodCluster,
                    title: "\(toughCount) meals you marked as tough this week.",
                    detail: nil
                ))
            }
        }

        // ---- First this week ----------------------------------------
        // Only consider it if we still have a slot left.
        if patterns.count < 2,
           let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: now) {
            // Names that appeared 8–14 days ago. A name is "new this week"
            // iff it appears in the last 7 days but NOT in this set.
            let priorNames = Set(
                logs
                    .filter { $0.eatenAt >= twoWeeksAgo && $0.eatenAt < weekAgo }
                    .map { $0.foodName.lowercased() }
            )
            // A food that:
            //   (a) appears this week,
            //   (b) didn't appear in the prior week, and
            //   (c) isn't already the "frequent" pattern (would be weird
            //       to surface the same food twice with different framings).
            let usedKeys = Set(patterns.map { $0.id })
            let candidate = logs
                .filter { $0.eatenAt >= weekAgo }
                .first(where: {
                    let key = $0.foodName.lowercased()
                    return !priorNames.contains(key)
                        && !usedKeys.contains("frequent:\(key)")
                })
            if let candidate {
                patterns.append(Pattern(
                    id: "firstThisWeek:\(candidate.foodName.lowercased())",
                    kind: .firstThisWeek,
                    title: "Trying new things — \(candidate.foodName) was new this week.",
                    detail: nil
                ))
            }
        }

        return Array(patterns.prefix(2))
    }

    /// "Mostly Fridays." style detail when 3+ occurrences cluster on
    /// the same weekday. Returns nil otherwise.
    private static func weekdayClusterDetail(dates: [Date],
                                             calendar: Calendar) -> String? {
        guard dates.count >= 3 else { return nil }
        let weekdays = dates.map { calendar.component(.weekday, from: $0) }
        var hist: [Int: Int] = [:]
        for w in weekdays { hist[w, default: 0] += 1 }
        guard let (top, count) = hist.max(by: { $0.value < $1.value }),
              count >= 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        // Calendar.weekday is 1...7 (Sunday = 1). DateFormatter.weekdaySymbols
        // is 0-indexed Sunday-first, matching that natural ordering.
        let symbols = formatter.weekdaySymbols ?? []
        guard symbols.indices.contains(top - 1) else { return nil }
        return "Mostly \(symbols[top - 1])s."
    }
}

// MARK: - Pattern

/// A surfaced observation in the Today → Patterns section. Stable `id`
/// is used as both list identity and analytics key — derived from the
/// kind + lowercased food name so consecutive refreshes produce the
/// same id for the same pattern (avoids needless re-renders).
struct Pattern: Identifiable, Hashable {
    let id: String
    let kind: Kind
    let title: String
    let detail: String?

    enum Kind: Hashable {
        /// Eaten 3+ times in the last 14 days.
        case frequent
        /// Streak of a nutrient/category. Reserved for a future phase;
        /// not produced by the v1 analyzer.
        case streak
        /// First time logging this food in the last 7 days.
        case firstThisWeek
        /// Phase 18. 3+ meals in the last 7 days share the same
        /// non-loved mood. v1 only emits the `tough` cluster — see
        /// `analyzePatterns` for the rationale (clustering on `loved`
        /// reads as the app applauding the user; `fine` is the boring
        /// middle and produces noisy filler).
        case moodCluster
    }
}
