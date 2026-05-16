import Foundation
import Supabase

actor FoodLogService {
    private let client: SupabaseClient

    /// Shared formatter for `eaten_at` filter bounds. `ISO8601DateFormatter`
    /// is thread-safe; configuring it once avoids re-bootstrapping ICU
    /// on every Tracker refresh / range query.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Insert a freshly-analyzed meal. Returns the persisted row.
    /// `NewFoodLog` deliberately omits user_id; the DB default fills it from auth.uid().
    func insert(_ draft: NewFoodLog) async throws -> FoodLog {
        try await client
            .from("food_logs")
            .insert(draft, returning: .representation)
            .single()
            .execute()
            .value
    }

    /// Phase 21 — insert a manual (typing-based) meal log. Mirrors the
    /// analyzed insert path but skips image-related fields and stashes
    /// the serving description in the existing `nutrients` array so the
    /// meal-detail UI surfaces it without a new column. Sets
    /// `origin = .manual` so callers can distinguish later.
    ///
    /// The serving description is the user-readable portion ("1 cup
    /// (158g)" or "2× 1 cup (158g)" when a multiplier was applied);
    /// it lives in `nutrients[0]` by convention so v1 doesn't need a
    /// schema change.
    func insertManual(
        foodName: String,
        servingDesc: String,
        calories: Double,
        carbsG: Double,
        proteinG: Double?,
        fatG: Double?,
        fiberG: Double?,
        sugarG: Double?
    ) async throws -> FoodLog {
        let draft = NewFoodLog(
            foodName:       foodName,
            imagePath:      nil,
            imageThumbPath: nil,
            calories:       calories,
            carbsG:         carbsG,
            sugarG:         sugarG ?? 0,
            proteinG:       proteinG,
            fatG:           fatG,
            fiberG:         fiberG,
            benefits:       [],
            drawbacks:      [],
            nutrients:      [servingDesc],
            coachName:      nil,
            coachAdvice:    nil,
            origin:         .manual,
            sourceLogId:    nil
        )

        #if DEBUG
        NSLog("[ManualLog] INSERT name=%@ cal=%.0f serving=%@",
              foodName, calories, servingDesc)
        #endif

        return try await insert(draft)
    }

    /// Today's logs for the signed-in user, in the user's local time zone.
    /// Phase 0 Q2: query food_logs directly with a local-day boundary; do not use
    /// the daily_food_totals view (which buckets by UTC and can disagree near midnight).
    func todaysLogs(timeZone: TimeZone = .current) async throws -> [FoodLog] {
        let (start, end) = Self.localDayBounds(timeZone: timeZone)
        let f = Self.iso8601Formatter

        return try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: start))
            .lt ("eaten_at", value: f.string(from: end))
            .order("eaten_at", ascending: false)
            .execute()
            .value
    }

    /// Logs in a half-open date range [from, to). Caller passes absolute Dates
    /// representing local-day boundaries (start-of-day local … start-of-next-day-after-end local).
    /// Reuses Phase 6's filter pattern (gte/lt on eaten_at, ordered desc).
    /// RLS handles per-user isolation.
    func logs(from: Date, to: Date) async throws -> [FoodLog] {
        let f = Self.iso8601Formatter

        return try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: from))
            .lt ("eaten_at", value: f.string(from: to))
            .order("eaten_at", ascending: false)
            .execute()
            .value
    }

    func delete(_ id: UUID) async throws {
        try await client
            .from("food_logs")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    /// Delete a saved meal end-to-end: the `food_logs` row first (the
    /// source of truth that the rest of the app reads from), then a
    /// best-effort cleanup of the main image and its thumbnail in
    /// Storage. Image deletion failures are swallowed because:
    ///   - the row is already gone, so nothing in the schema references
    ///     the orphaned object,
    ///   - storage cost for a 256-px thumbnail is negligible, and
    ///   - we'd rather succeed at the user's stated goal (remove the log
    ///     from their day) than fail the whole operation over a
    ///     transient storage hiccup.
    func delete(_ log: FoodLog,
                imageService: FoodImageService = FoodImageService()) async throws {
        try await delete(log.id)

        var paths: [String] = []
        if let p = log.imagePath, !p.isEmpty { paths.append(p) }
        if let p = log.imageThumbPath, !p.isEmpty { paths.append(p) }
        if !paths.isEmpty {
            do {
                try await imageService.delete(paths: paths)
            } catch {
                #if DEBUG
                NSLog("[Delete] storage cleanup FAILED for %d path(s): %@",
                      paths.count, "\(error)")
                #endif
            }
        }
    }

    /// Phase 18 — set (or clear) the post-save mood label on a saved
    /// meal. RLS scopes the row by `user_id` via the
    /// `food_logs_update_own` policy; no client-side user check needed.
    ///
    /// Passing `nil` is intentional and clears any prior label — the
    /// "Skip" path in the pulse and the Profile mood log's "clear"
    /// affordance funnel through the same call.
    @discardableResult
    func setMood(_ mood: FoodLog.Mood?, on logId: UUID) async throws -> FoodLog {
        // PostgREST's update path is happiest with an Encodable payload;
        // a typed patch keeps the wire shape obvious and round-trips the
        // optional cleanly (encodeIfPresent for nil drops the column,
        // which would leave the prior value alone — so encode `nil` as
        // explicit JSON `null` to clear).
        struct MoodPatch: Encodable {
            let mood: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                // Always encode the key; `encode(_:forKey:)` on
                // `String?` writes JSON null when the value is nil.
                try c.encode(mood, forKey: .mood)
            }
            enum CodingKeys: String, CodingKey { case mood }
        }
        let patch = MoodPatch(mood: mood?.rawValue)
        return try await client
            .from("food_logs")
            .update(patch, returning: .representation)
            .eq("id", value: logId)
            .single()
            .execute()
            .value
    }

    /// [start, end) covering the user's local calendar day, expressed as absolute Dates.
    static func localDayBounds(now: Date = Date(),
                               timeZone: TimeZone = .current) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        return (start, end)
    }
}
