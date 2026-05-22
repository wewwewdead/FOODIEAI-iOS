import Foundation

// MARK: - FoodOSActiveExperiment
//
// FoodOS Feedback Learning V2 — when the user taps "I'll try this"
// on a moment, we remember that promise as an active experiment.
// The next time they record a mood note on a fresh meal, the store
// "resolves" the experiment by linking the outcome (loved / fine →
// positive, tough → negative) back to the moment's tag so future
// moments can learn which kinds of nudges actually helped *this*
// user.
//
// All persistence is local. Nothing here ever touches Supabase or
// the network.

/// One live "I'll try this" promise. The store keeps at most one
/// active experiment per `momentTag`; tapping again on the same tag
/// replaces or refreshes the existing one rather than spawning a
/// duplicate.
struct FoodOSActiveExperiment: Codable, Equatable, Identifiable {

    /// Lifecycle of a single experiment row.
    ///   - `active`   : armed; waiting for the user's next mood note.
    ///   - `resolved` : a mood note arrived inside the window and
    ///                  drove a positive/negative outcome.
    ///   - `expired`  : the window passed without a mood note.
    enum Status: String, Codable, Equatable {
        case active
        case resolved
        case expired
    }

    /// Categorical outcome after a mood resolution. `unknown` only
    /// applies while the experiment is still active or was expired
    /// without a mood. The `neutral` case is reserved — V2 does not
    /// produce it (loved/fine = positive, tough = negative, skipped
    /// = no resolution) but the field is carried in the schema so a
    /// future tier doesn't need a migration.
    enum Outcome: String, Codable, Equatable {
        case unknown
        case positive
        case neutral
        case negative
    }

    let id: UUID
    let momentTag: FoodOSMomentTag
    /// Stored as the rawValue of `FoodOSMoment.Kind` so the model can
    /// stay Codable without forcing the kind enum to gain a Codable
    /// conformance it doesn't need elsewhere.
    let momentKind: String
    let momentTitle: String
    let startedAt: Date
    let expiresAt: Date
    var status: Status
    var resolvedAt: Date?
    var outcome: Outcome
    let sourceMomentEvidenceLine: String?
    var relatedFoodLogId: UUID?

    init(id: UUID = UUID(),
         momentTag: FoodOSMomentTag,
         momentKind: FoodOSMoment.Kind,
         momentTitle: String,
         startedAt: Date,
         expiresAt: Date,
         status: Status = .active,
         resolvedAt: Date? = nil,
         outcome: Outcome = .unknown,
         sourceMomentEvidenceLine: String? = nil,
         relatedFoodLogId: UUID? = nil) {
        self.id = id
        self.momentTag = momentTag
        self.momentKind = momentKind.rawValue
        self.momentTitle = momentTitle
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.status = status
        self.resolvedAt = resolvedAt
        self.outcome = outcome
        self.sourceMomentEvidenceLine = sourceMomentEvidenceLine
        self.relatedFoodLogId = relatedFoodLogId
    }

    /// Best-effort recovery of the original `FoodOSMoment.Kind` from
    /// the stored rawValue. Returns nil for rows written by a future
    /// version that added a new case.
    var kind: FoodOSMoment.Kind? { FoodOSMoment.Kind(rawValue: momentKind) }

    /// Default time-to-live for a freshly started experiment. 24h
    /// matches a single "next mood note" expectation without leaving
    /// stale promises lingering for days.
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    /// True when `now` is past the expiry instant. Pure — no side
    /// effects, the caller decides whether to mutate `status`.
    func isExpired(now: Date) -> Bool { now >= expiresAt }
}

/// Result of a successful `resolveExperiment` call. The store hands
/// one of these back to the view layer so Mirror can show a tiny
/// confirmation without the view needing to inspect the store state.
struct FoodOSResolvedExperiment: Equatable, Identifiable {
    let experimentId: UUID
    let momentTag: FoodOSMomentTag
    let outcome: FoodOSActiveExperiment.Outcome
    let mood: FoodLog.Mood
    let relatedFoodLogId: UUID?
    let resolvedAt: Date

    var id: UUID { experimentId }
}

// MARK: - FoodLog.Mood → outcome mapping
//
// Kept on the active-experiment model so the rule lives next to the
// data shape it's classifying, and so tests can exercise it without
// reaching into the store.

extension FoodOSActiveExperiment.Outcome {
    /// Map a user's mood reaction to an experiment outcome.
    ///
    ///   - `.loved` / `.fine` → `.positive` (V2 keeps the reward
    ///     signal simple: any non-tough mood is a win.)
    ///   - `.tough`           → `.negative`
    ///
    /// `nil` (mood skipped) intentionally has no mapping; the store
    /// treats that as "no resolution" instead of forcing a verdict.
    static func from(mood: FoodLog.Mood) -> FoodOSActiveExperiment.Outcome {
        switch mood {
        case .loved, .fine: return .positive
        case .tough:        return .negative
        }
    }
}

// MARK: - Notification
//
// Fired on the main queue right after a mood note resolves an active
// experiment. View layers can subscribe to surface a calm "FoodOS
// learned from your last try." banner without coupling to the store.

extension Notification.Name {
    /// Posted with `object == FoodOSResolvedExperiment` after the
    /// store successfully resolves an experiment. Best-effort
    /// notification: missing it never breaks correctness — the
    /// resolution is already persisted by the time this fires.
    static let foodOSExperimentResolved =
        Notification.Name("FoodieAI.foodOSExperimentResolved")
}
