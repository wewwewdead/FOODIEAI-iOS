import Foundation

/// Phase 17. A persisted weekly summary in `public.weekly_recaps`.
///
/// `weekStart` and `weekEnd` are wire-typed as `String` (date) on the
/// PostgREST side. Swift's `Date` decoder can't always parse bare
/// "YYYY-MM-DD" via the default ISO formatter, so we go through
/// dedicated coding to keep the boundary explicit.
struct WeeklyRecap: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    /// Monday in user's tz (date-only).
    let weekStart: Date
    /// Sunday in user's tz (date-only).
    let weekEnd: Date
    let coachName: String
    let body: String
    let headlineStat: String?
    let topPattern: String?
    /// Phase 18 — one-line summary of the week's emotional shape, e.g.
    /// "Three loved meals, four tough ones. A heavy week." NULL when
    /// the server returned fewer than 3 mood-labeled meals (not enough
    /// signal to summarize).
    let moodSummary: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case weekStart      = "week_start"
        case weekEnd        = "week_end"
        case coachName      = "coach_name"
        case body
        case headlineStat   = "headline_stat"
        case topPattern     = "top_pattern"
        case moodSummary    = "mood_summary"
        case createdAt      = "created_at"
    }

    /// Date-only (YYYY-MM-DD) parser used for week_start / week_end.
    /// Local timezone on purpose: `WeekBounds` produces local-midnight
    /// Monday/Sunday `Date`s, and the DB column is a calendar-day `date`
    /// (no time, no zone). Formatting with UTC was shifting east-of-UTC
    /// users' Mondays back to the prior Sunday on write, then decoding
    /// the shifted string as UTC-midnight on read — so the recap row
    /// stored the wrong week and the food_logs query missed everything.
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(id: UUID,
         userId: UUID,
         weekStart: Date,
         weekEnd: Date,
         coachName: String,
         body: String,
         headlineStat: String?,
         topPattern: String?,
         moodSummary: String?,
         createdAt: Date) {
        self.id = id
        self.userId = userId
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.coachName = coachName
        self.body = body
        self.headlineStat = headlineStat
        self.topPattern = topPattern
        self.moodSummary = moodSummary
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        userId    = try c.decode(UUID.self,   forKey: .userId)
        coachName = try c.decode(String.self, forKey: .coachName)
        body      = try c.decode(String.self, forKey: .body)
        headlineStat = try c.decodeIfPresent(String.self, forKey: .headlineStat)
        topPattern   = try c.decodeIfPresent(String.self, forKey: .topPattern)
        moodSummary  = try c.decodeIfPresent(String.self, forKey: .moodSummary)
        createdAt    = try c.decode(Date.self, forKey: .createdAt)

        let startStr = try c.decode(String.self, forKey: .weekStart)
        let endStr   = try c.decode(String.self, forKey: .weekEnd)
        guard let start = Self.yyyyMMdd.date(from: startStr),
              let end   = Self.yyyyMMdd.date(from: endStr) else {
            throw DecodingError.dataCorruptedError(
                forKey: .weekStart, in: c,
                debugDescription: "weekly_recaps date parse failed: start=\(startStr), end=\(endStr)"
            )
        }
        weekStart = start
        weekEnd   = end
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(coachName, forKey: .coachName)
        try c.encode(body, forKey: .body)
        try c.encodeIfPresent(headlineStat, forKey: .headlineStat)
        try c.encodeIfPresent(topPattern, forKey: .topPattern)
        try c.encodeIfPresent(moodSummary, forKey: .moodSummary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(Self.yyyyMMdd.string(from: weekStart), forKey: .weekStart)
        try c.encode(Self.yyyyMMdd.string(from: weekEnd),   forKey: .weekEnd)
    }
}

/// Insert payload — no id (DB default), no user_id (DB default +
/// RLS enforce auth.uid()), no created_at (DB default).
struct NewWeeklyRecap: Encodable {
    let weekStart: Date
    let weekEnd: Date
    let coachName: String
    let body: String
    let headlineStat: String?
    let topPattern: String?
    /// Phase 18.
    let moodSummary: String?

    enum CodingKeys: String, CodingKey {
        case weekStart      = "week_start"
        case weekEnd        = "week_end"
        case coachName      = "coach_name"
        case body
        case headlineStat   = "headline_stat"
        case topPattern     = "top_pattern"
        case moodSummary    = "mood_summary"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(WeeklyRecap.yyyyMMdd.string(from: weekStart), forKey: .weekStart)
        try c.encode(WeeklyRecap.yyyyMMdd.string(from: weekEnd),   forKey: .weekEnd)
        try c.encode(coachName, forKey: .coachName)
        try c.encode(body, forKey: .body)
        try c.encodeIfPresent(headlineStat, forKey: .headlineStat)
        try c.encodeIfPresent(topPattern, forKey: .topPattern)
        try c.encodeIfPresent(moodSummary, forKey: .moodSummary)
    }
}
