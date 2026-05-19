import Foundation
import Supabase

/// Phase 17. Reads `weekly_recaps` and orchestrates server-side
/// generation.
///
/// Two responsibilities:
///   1. CRUD reads: `latest`, `history`.
///   2. Orchestration: `generateIfNeeded(weekStart:weekEnd:)` gathers
///      logs + patterns + preferences, calls the server, and returns
///      the recap. The server owns the cache check AND the DB insert
///      under service-role so cache + write live in one place.
///
/// The unique `(user_id, week_start)` constraint is the safety net for
/// races (two devices opened on Sunday evening). The server returns
/// the existing row on cache hit OR on a unique-violation race.
actor WeeklyRecapService {
    private let client: SupabaseClient
    private let analyzeBaseURL: URL
    private let session: URLSession

    private let logService: FoodLogService
    private let history: MealHistoryService
    private let profileService: ProfileService

    init(client: SupabaseClient = FoodieClient.shared,
         analyzeBaseURL: URL = AppConfig.analyzeBaseURL,
         session: URLSession = .shared,
         logService: FoodLogService = FoodLogService(),
         history: MealHistoryService = MealHistoryService(),
         profileService: ProfileService = ProfileService()) {
        self.client = client
        self.analyzeBaseURL = analyzeBaseURL
        self.session = session
        self.logService = logService
        self.history = history
        self.profileService = profileService
    }

    // MARK: - Reads

    /// The most recent recap, if any. Used by the deep-link from the
    /// recap notification and the Today "This week" affordance.
    func latest() async throws -> WeeklyRecap? {
        let rows: [WeeklyRecap] = try await client
            .from("weekly_recaps")
            .select()
            .order("week_start", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// All historical recaps, newest-first, capped at `limit`. Surfaces
    /// the future "Past Recaps" history list.
    func history(limit: Int = 12) async throws -> [WeeklyRecap] {
        try await client
            .from("weekly_recaps")
            .select()
            .order("week_start", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    // MARK: - Orchestration

    /// Generate a recap for the given week. The server checks the cache
    /// (returning the existing row on hit) and inserts on miss under
    /// service-role, so this method just gathers context and round-trips.
    /// Returns `nil` when the week has no meals (the server's 204 path).
    func generateIfNeeded(weekStart: Date, weekEnd: Date) async throws -> WeeklyRecap? {
        // The recap range is half-open `[weekStart, weekEnd_exclusive)`.
        // `weekEnd` from the caller is the inclusive Sunday date — push
        // it forward by one day to make the food_logs range half-open.
        let weekEndExclusive = Calendar.current.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd

        async let logsTask     = logService.logs(from: weekStart, to: weekEndExclusive)
        async let patternsTask = history.patternsForRange(from: weekStart, to: weekEndExclusive)
        async let profileTask  = profileService.currentProfile()

        let logs:     [FoodLog]
        let patterns: [Pattern]
        let profile:  Profile?
        do {
            logs     = try await logsTask
            patterns = try await patternsTask
            profile  = try? await profileTask
        } catch {
            #if DEBUG
            NSLog("[Recap] gather FAILED: %@", "\(error)")
            #endif
            throw error
        }

        guard !logs.isEmpty else {
            #if DEBUG
            NSLog("[Recap] no meals for %@..%@ — skip generate",
                  WeeklyRecap.yyyyMMdd.string(from: weekStart),
                  WeeklyRecap.yyyyMMdd.string(from: weekEnd))
            #endif
            return nil
        }

        let preferred = profile?.preferredCoaches ?? []
        let response = try await requestGenerate(
            weekStart: weekStart, weekEnd: weekEnd,
            meals: logs, patterns: patterns,
            preferredCoaches: preferred
        )
        guard let response else { return nil }

        // Resolve the userId from the cached session for the model.
        // The server owns the row write and uses the JWT-verified
        // user_id; we mirror it locally for the in-memory model.
        let userId = client.auth.currentUser?.id ?? UUID()

        let recap = WeeklyRecap(
            id:           response.id,
            userId:       userId,
            weekStart:    weekStart,
            weekEnd:      weekEnd,
            coachName:    response.coachName,
            body:         response.body,
            headlineStat: response.headlineStat,
            topPattern:   response.topPattern,
            moodSummary:  response.moodSummary,
            createdAt:    Date()
        )

        #if DEBUG
        NSLog("[Recap] %@ week_start=%@ coach=%@ headline=%@",
              response.cached ? "cache hit" : "freshly generated",
              WeeklyRecap.yyyyMMdd.string(from: weekStart),
              recap.coachName,
              recap.headlineStat ?? "<nil>")
        #endif

        return recap
    }

    // MARK: - Server round-trip

    private func requestGenerate(weekStart: Date,
                                 weekEnd: Date,
                                 meals: [FoodLog],
                                 patterns: [Pattern],
                                 preferredCoaches: [String]) async throws -> GenerateResponseBody? {
        let url = analyzeBaseURL.appendingPathComponent("weekly-recap")

        // `preferred_coaches` is the allowed coach pool the server
        // must pick from; sanitize so a starred set of one means
        // "use only that coach."
        let cleanedCoaches = AnalyzeService.sanitizePreferredCoaches(preferredCoaches)

        let body = GenerateRequestBody(
            weekStart: WeeklyRecap.yyyyMMdd.string(from: weekStart),
            weekEnd:   WeeklyRecap.yyyyMMdd.string(from: weekEnd),
            meals:     meals.map(WireMeal.init(from:)),
            patterns:  patterns.map(WirePattern.init(from:)),
            preferredCoaches: cleanedCoaches
        )

        // Improvement A — server uses the JWT to verify the caller and
        // to perform the cache check + insert under that user_id.
        let authSession: Session
        do {
            authSession = try await client.auth.session
        } catch {
            throw RecapError.notAuthenticated
        }
        let accessToken = authSession.accessToken

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        // Custom encoders on `WeeklyRecap` already format dates; meals
        // need an ISO timestamp for `eaten_at`.
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(body)

        #if DEBUG
        NSLog("[Recap] POST %@ meals=%d patterns=%d prefs=%d",
              url.absoluteString, meals.count, patterns.count, cleanedCoaches.count)
        #endif

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RecapError.unexpectedResponse
        }
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw RecapError.server(status: http.statusCode, body: bodyStr)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GenerateResponseBody.self, from: data)
    }
}

// MARK: - Server JSON shapes

private struct WireMeal: Encodable {
    let food_name: String
    let eaten_at: String
    let calories: Double
    let carbs: Double
    let sugar: Double
    let protein: Double?
    let fat: Double?
    let fiber: Double?
    /// Phase 18 — mood label per meal so the recap prompt can compute
    /// `mood_summary`. Nil for rows the user didn't label.
    let mood: String?

    init(from log: FoodLog) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.food_name = log.foodName
        self.eaten_at  = f.string(from: log.eatenAt)
        self.calories  = log.calories
        self.carbs     = log.carbsG
        self.sugar     = log.sugarG
        self.protein   = log.proteinG
        self.fat       = log.fatG
        self.fiber     = log.fiberG
        self.mood      = log.mood?.rawValue
    }
}

private struct WirePattern: Encodable {
    let kind: String
    let subject: String
    let detail: String?

    init(from pattern: Pattern) {
        switch pattern.kind {
        case .frequent:      self.kind = "frequent"
        case .firstThisWeek: self.kind = "firstThisWeek"
        case .streak:        self.kind = "streak"
        case .moodCluster:   self.kind = "moodCluster"
        }
        self.subject = CoachObservationService.extractSubject(from: pattern)
                    ?? pattern.title
        self.detail = pattern.detail
    }
}

private struct GenerateRequestBody: Encodable {
    let weekStart: String
    let weekEnd: String
    let meals: [WireMeal]
    let patterns: [WirePattern]
    let preferredCoaches: [String]

    enum CodingKeys: String, CodingKey {
        case weekStart      = "week_start"
        case weekEnd        = "week_end"
        case meals
        case patterns
        case preferredCoaches = "preferred_coaches"
    }
}

private struct GenerateResponseBody: Decodable {
    /// Improvement A — server now inserts the row and returns its UUID.
    let id: UUID
    let coachName: String
    let body: String
    let headlineStat: String?
    let topPattern: String?
    /// Phase 18 — server returns null when fewer than 3 meals this
    /// week carry mood labels.
    let moodSummary: String?
    /// `true` when the server returned a previously persisted row
    /// without invoking Gemini. Useful for telemetry / debug logs.
    let cached: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case coachName      = "coach_name"
        case body
        case headlineStat   = "headline_stat"
        case topPattern     = "top_pattern"
        case moodSummary    = "mood_summary"
        case cached
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self, forKey: .id)
        self.coachName    = try c.decode(String.self, forKey: .coachName)
        self.body         = try c.decode(String.self, forKey: .body)
        self.headlineStat = try c.decodeIfPresent(String.self, forKey: .headlineStat)
        self.topPattern   = try c.decodeIfPresent(String.self, forKey: .topPattern)
        self.moodSummary  = try c.decodeIfPresent(String.self, forKey: .moodSummary)
        self.cached       = (try? c.decodeIfPresent(Bool.self, forKey: .cached)) ?? false
    }
}

// MARK: - Errors

enum RecapError: LocalizedError {
    case server(status: Int, body: String)
    case unexpectedResponse
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .server(let status, _):
            return "Weekly recap server returned HTTP \(status)."
        case .unexpectedResponse:
            return "Unexpected response from the weekly recap endpoint."
        case .notAuthenticated:
            return "You must be signed in to generate a weekly recap."
        }
    }
}

// MARK: - Week-boundary helpers

/// Phase 17. Compute Monday-of-this-week / Sunday-of-this-week as
/// date-only `Date` values in the user's timezone. Reused by the app
/// lifecycle hook (which generates "the just-completed week" — i.e.,
/// last week's bounds, not this week's).
enum WeekBounds {
    /// Monday at 00:00 local for the week containing `date`.
    static func mondayOfWeek(containing date: Date,
                             timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    /// Sunday at 00:00 local for the week containing `date`.
    static func sundayOfWeek(containing date: Date,
                             timeZone: TimeZone = .current) -> Date {
        let monday = mondayOfWeek(containing: date, timeZone: timeZone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(byAdding: .day, value: 6, to: monday) ?? monday
    }

    /// The most recently completed week's (Monday, Sunday) bounds in
    /// the given timezone. "This week" = the week containing now;
    /// "last completed week" = the one before that.
    static func lastCompletedWeek(now: Date = Date(),
                                  timeZone: TimeZone = .current) -> (Date, Date) {
        let thisMonday = mondayOfWeek(containing: now, timeZone: timeZone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let lastMonday = cal.date(byAdding: .day, value: -7, to: thisMonday) ?? thisMonday
        let lastSunday = cal.date(byAdding: .day, value: 6, to: lastMonday) ?? lastMonday
        return (lastMonday, lastSunday)
    }
}
