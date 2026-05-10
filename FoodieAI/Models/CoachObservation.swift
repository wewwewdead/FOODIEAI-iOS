import Foundation

/// Phase 16. Editorial card the active coach posts on Today between
/// meals — generated from a `Pattern`, persisted in
/// `public.coach_observations`, surfaced in `TodayView`.
///
/// `dismissedAt` semantics: NULL means active (the card is showing).
/// We don't delete dismissed rows because Phase 17's weekly recap
/// reads the full history (active + dismissed) to characterize the
/// coach's voice over the week.
struct CoachObservation: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let coachName: String
    let body: String
    /// Mirrors `Pattern.Kind` raw values ("frequent", "firstThisWeek",
    /// "streak"). Stored as text so future kinds don't require a schema
    /// migration.
    let patternKind: String?
    /// The food name (or nutrient label) the observation references.
    /// Used by the dedup-by-subject guardrail to avoid re-observing
    /// the same thing within a 7-day window.
    let patternSubject: String?
    let dismissedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case coachName      = "coach_name"
        case body
        case patternKind    = "pattern_kind"
        case patternSubject = "pattern_subject"
        case dismissedAt    = "dismissed_at"
        case createdAt      = "created_at"
    }

    /// Convenience for the view layer: an observation is "active" if it
    /// hasn't been dismissed.
    var isActive: Bool { dismissedAt == nil }
}

/// Insert payload — no id (DB defaults `gen_random_uuid()`), no user_id
/// (DB defaults `auth.uid()` and RLS enforces the match), no
/// dismissed_at (always NULL on insert), no created_at (DB default
/// `now()`).
struct NewCoachObservation: Encodable {
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

/// Payload for `PATCH coach_observations` to mark a card dismissed.
struct CoachObservationDismiss: Encodable {
    let dismissedAt: Date

    enum CodingKeys: String, CodingKey {
        case dismissedAt = "dismissed_at"
    }
}
