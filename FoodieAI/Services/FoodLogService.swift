import Foundation
import Supabase

actor FoodLogService {
    private let client: SupabaseClient

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

    /// Today's logs for the signed-in user, in the user's local time zone.
    /// Phase 0 Q2: query food_logs directly with a local-day boundary; do not use
    /// the daily_food_totals view (which buckets by UTC and can disagree near midnight).
    func todaysLogs(timeZone: TimeZone = .current) async throws -> [FoodLog] {
        let (start, end) = Self.localDayBounds(timeZone: timeZone)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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
