import Foundation
import Supabase

/// Phase 16. Reads, writes, and orchestrates `coach_observations`.
///
/// Three responsibilities:
///   1. CRUD against the table (insert / dismiss / query).
///   2. Calling the server's `POST /coach-observation` to generate
///      a fresh observation from a `Pattern` set.
///   3. The "should we generate?" orchestration — `generateIfNeeded`
///      checks for an existing active card today and a 7-day dedup
///      window before paying the model round-trip.
///
/// RLS handles per-user isolation; no `user_id` filters are needed in
/// the queries below.
actor CoachObservationService {
    private let client: SupabaseClient
    private let analyzeBaseURL: URL
    private let session: URLSession

    init(client: SupabaseClient = FoodieClient.shared,
         analyzeBaseURL: URL = AppConfig.analyzeBaseURL,
         session: URLSession = .shared) {
        self.client = client
        self.analyzeBaseURL = analyzeBaseURL
        self.session = session
    }

    // MARK: - Reads

    /// Most recent active (non-dismissed) observation created today in
    /// the user's local time zone. Returns `nil` when there isn't one.
    /// Today-only because the editorial card is meant to feel current;
    /// yesterday's observation, even if undismissed, isn't the right
    /// thing to surface this morning.
    func todaysObservation(timeZone: TimeZone = .current) async throws -> CoachObservation? {
        let (start, end) = Self.localDayBounds(timeZone: timeZone)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let rows: [CoachObservation] = try await client
            .from("coach_observations")
            .select()
            .gte("created_at", value: f.string(from: start))
            .lt ("created_at", value: f.string(from: end))
            .is ("dismissed_at", value: nil)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value

        return rows.first
    }

    /// All observations (including dismissed) ordered newest-first, for
    /// a future "Coach Notes" history screen. Not consumed by Phase 16's
    /// Today UI — included now so Phase 17's recap has it ready.
    func recentObservations(limit: Int = 30) async throws -> [CoachObservation] {
        try await client
            .from("coach_observations")
            .select()
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Observations created in the last `days` days that match
    /// `(patternKind, patternSubject)`. The dedup-by-subject guardrail
    /// uses this to skip generation when the same focus pattern has
    /// already been spoken about recently.
    func recentObservationsMatching(kind: String?,
                                    subject: String?,
                                    withinDays days: Int = 7) async throws -> [CoachObservation] {
        guard let kind, let subject else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return try await client
            .from("coach_observations")
            .select()
            .eq("pattern_kind", value: kind)
            .eq("pattern_subject", value: subject)
            .gte("created_at", value: f.string(from: cutoff))
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Writes

    /// Persist a freshly-generated observation. Returns the row.
    func insert(_ draft: NewCoachObservation) async throws -> CoachObservation {
        try await client
            .from("coach_observations")
            .insert(draft, returning: .representation)
            .single()
            .execute()
            .value
    }

    /// Mark an observation as dismissed (sets `dismissed_at = now()`).
    /// The row stays in the table — Phase 17's recap reads it back.
    func dismiss(_ id: UUID) async throws {
        let patch = CoachObservationDismiss(dismissedAt: Date())
        try await client
            .from("coach_observations")
            .update(patch)
            .eq("id", value: id)
            .execute()
    }

    // MARK: - Orchestration

    /// Generate a fresh observation if the conditions warrant it,
    /// persist it, and return it. Returns `nil` when:
    ///   - there's already an active observation for today
    ///   - `patterns` is empty
    ///   - the focus pattern was already observed within the last 7 days
    ///   - the server returns 204 (defensive — shouldn't happen given
    ///     the empty-patterns guard above, but the server may also
    ///     return 204 if no focus pattern is recoverable from the input)
    ///
    /// The dedup-by-subject step is the most important behavioral
    /// guardrail in this phase. Without it, the same "you've had pizza
    /// 4 times" observation would be re-spoken every day until the
    /// count changed — feels like nagging.
    ///
    /// Phase 18 — `recentMoods` are forwarded to the server so the
    /// coach can lightly reference emotional patterns (tough-day
    /// clusters, etc.). Empty array → field omitted, byte-identical
    /// to the Phase-16 request shape.
    func generateIfNeeded(patterns: [Pattern],
                          preferredCoaches: [String],
                          recentMoods: [FoodLog] = []) async throws -> CoachObservation? {
        // Guardrail 1: already an active card for today.
        if let existing = try await todaysObservation() {
            return existing
        }

        // Guardrail 2: nothing to observe.
        guard !patterns.isEmpty else { return nil }

        // Guardrail 3: dedup-by-subject. Mirror the server's focus-
        // pattern picker (prefer .frequent over .firstThisWeek) so we
        // skip the round-trip when we can predict the server would
        // anchor on a subject we already covered this week.
        let focus = patterns.first(where: { $0.kind == .frequent })
                 ?? patterns.first(where: { $0.kind == .firstThisWeek })
                 ?? patterns.first
        if let focus, let subject = Self.extractSubject(from: focus) {
            let kindString = Self.kindRawValue(focus.kind)
            let prior = try await recentObservationsMatching(
                kind: kindString,
                subject: subject
            )
            if !prior.isEmpty {
                #if DEBUG
                NSLog("[CoachObs] skip generate — %d prior observation(s) for %@:%@",
                      prior.count, kindString, subject)
                #endif
                return nil
            }
        }

        // Round-trip the model.
        let draft = try await requestGenerate(
            patterns: patterns,
            preferredCoaches: preferredCoaches,
            recentMoods: recentMoods
        )
        guard let draft else { return nil }

        let inserted = try await insert(draft)
        #if DEBUG
        NSLog("[CoachObs] inserted id=%@ coach=%@ kind=%@ subject=%@",
              inserted.id.uuidString, inserted.coachName,
              inserted.patternKind ?? "<nil>",
              inserted.patternSubject ?? "<nil>")
        #endif
        return inserted
    }

    // MARK: - Server round-trip

    /// POST the patterns + preferences to `/coach-observation` and
    /// decode the response into a `NewCoachObservation` ready for
    /// insert. Returns `nil` on the server's 204 (empty patterns or
    /// no focus) — call site treats that as a skip, not an error.
    ///
    /// Phase 18 — `recentMoods` is encoded into the body when non-empty.
    private func requestGenerate(patterns: [Pattern],
                                 preferredCoaches: [String],
                                 recentMoods: [FoodLog]) async throws -> NewCoachObservation? {
        let url = analyzeBaseURL.appendingPathComponent("coach-observation")

        let boundedMoods = Array(recentMoods.prefix(10))
        let moodWires: [GenerateRequestMood] = boundedMoods.compactMap { log in
            guard let mood = log.mood else { return nil }
            return GenerateRequestMood(
                food_name: log.foodName,
                mood: mood.rawValue,
                eaten_at: Self.iso8601.string(from: log.eatenAt)
            )
        }

        // `preferred_coaches` is the allowed coach pool the server
        // must pick from; sanitize so a starred set of one means
        // "use only that coach."
        let cleanedCoaches = AnalyzeService.sanitizePreferredCoaches(preferredCoaches)

        let body = GenerateRequestBody(
            patterns: patterns.map(GenerateRequestPattern.init(from:)),
            preferredCoaches: cleanedCoaches,
            recentMoods: moodWires.isEmpty ? nil : moodWires
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        #if DEBUG
        NSLog("[CoachObs] POST %@ patterns=%d prefs=%d moods=%d",
              url.absoluteString, patterns.count,
              cleanedCoaches.count, moodWires.count)
        #endif

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CoachObservationError.unexpectedResponse
        }

        if http.statusCode == 204 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CoachObservationError.server(status: http.statusCode, body: bodyStr)
        }

        let decoded = try JSONDecoder().decode(GenerateResponseBody.self, from: data)
        return NewCoachObservation(
            coachName: decoded.coachName,
            body: decoded.body,
            patternKind: decoded.patternKind,
            patternSubject: decoded.patternSubject
        )
    }

    // MARK: - Helpers

    /// `Pattern.Kind` doesn't have a `RawValue` (cases like `.streak`
    /// are bare). Map to the string the schema/server expect.
    private static func kindRawValue(_ kind: Pattern.Kind) -> String {
        switch kind {
        case .frequent:      return "frequent"
        case .firstThisWeek: return "firstThisWeek"
        case .streak:        return "streak"
        case .moodCluster:   return "moodCluster"
        }
    }

    /// Pull a clean subject out of a `Pattern`. The current
    /// `analyzePatterns` builds the title with the food name embedded
    /// ("You've had Margherita Pizza 4 times…"). Re-extracting from
    /// the title is brittle, so we encode the subject from the id —
    /// `Pattern.id` uses the form `"frequent:margherita pizza"` which
    /// we split on the first colon.
    static func extractSubject(from pattern: Pattern) -> String? {
        guard let colonIdx = pattern.id.firstIndex(of: ":") else { return nil }
        let raw = String(pattern.id[pattern.id.index(after: colonIdx)...])
        return raw.isEmpty ? nil : raw
    }

    /// `[start, end)` of the user's local calendar day, expressed in
    /// absolute Dates. Mirrors `FoodLogService.localDayBounds`.
    static func localDayBounds(now: Date = Date(),
                               timeZone: TimeZone = .current) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        return (start, end)
    }

    /// Phase 18 — shared ISO formatter for mood payload timestamps.
    fileprivate static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Server JSON shapes

private struct GenerateRequestPattern: Encodable {
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

private struct GenerateRequestMood: Encodable {
    let food_name: String
    let mood: String
    let eaten_at: String
}

private struct GenerateRequestBody: Encodable {
    let patterns: [GenerateRequestPattern]
    let preferredCoaches: [String]
    /// Phase 18. Absent when the user has no mood-labeled meals yet,
    /// preserving Phase-16 byte shape for the empty case.
    let recentMoods: [GenerateRequestMood]?

    enum CodingKeys: String, CodingKey {
        case patterns
        case preferredCoaches = "preferred_coaches"
        case recentMoods      = "recent_moods"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(patterns, forKey: .patterns)
        try c.encode(preferredCoaches, forKey: .preferredCoaches)
        // Use encodeIfPresent so the field is fully omitted when nil
        // (rather than serialized as JSON null) — mirrors the
        // multipart-omit pattern in AnalyzeService.
        try c.encodeIfPresent(recentMoods, forKey: .recentMoods)
    }
}

private struct GenerateResponseBody: Decodable {
    let coachName: String
    let body: String
    let patternKind: String?
    let patternSubject: String?

    enum CodingKeys: String, CodingKey {
        case coachName      = "coach_name"
        case body
        case patternKind    = "pattern_kind"
        case patternSubject = "pattern_subject"
    }
}

// MARK: - Errors

enum CoachObservationError: LocalizedError {
    case server(status: Int, body: String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .server(let status, _):
            return "Coach observation server returned HTTP \(status)."
        case .unexpectedResponse:
            return "Unexpected response from the coach observation endpoint."
        }
    }
}
