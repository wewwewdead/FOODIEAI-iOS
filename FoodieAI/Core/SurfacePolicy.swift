import Foundation

// NOVEL_DIRECTIONS Idea 1 — "One Brain".
//
// The app surfaces ~30 competing cards/nudges (daily quest, eat-to-goal,
// streak nudge, trend coach, FoodOS moment, records banner, comeback…), each
// gated by its own hand-tuned `if`-statement. They contend for the same slots
// and sometimes contradict each other. This is the subtraction move from the
// thesis: replace the N independent gates with ONE policy that scores every
// candidate against a single state vector + the user's learned preference +
// how relevant the surface is right now, and lets them compete in one ranking.
//
// It composes three signals the app already has:
//   • basePriority   — the existing priority-chain order (nothing is lost).
//   • preference     — a Beta-posterior "does the user engage with this kind"
//                      (the FoodOS bandit idea, generalized to any surface).
//   • contextRelevance — feature-weighted "how relevant right now" (the
//                      attention idea: the dead FoodOSAttentionEngine's job).
//
// Pure + testable + deterministic. Wiring it into the live views (having each
// surface publish a candidate instead of gating itself) is the follow-on; this
// is the brain that would drive them.

/// The competing surfaces the policy ranks.
enum SurfaceKind: String, CaseIterable, Hashable {
    case dailyQuest
    case eatToGoal
    case streakNudge
    case trendCoach
    case foodOSMoment
    case recordsBanner
    case comeback
    /// Today-tab soft advisory nudges. One Brain arbitrates these so only the
    /// single most-relevant one shows at a time, instead of stacking.
    case firstScan
    case personalize
}

/// The single state vector every surface is scored against — "what's true for
/// the user right now".
struct SurfaceContext: Equatable {
    /// 0–23 local hour.
    let hour: Int
    /// Fraction of the calorie budget still available (0 = at/over goal, 1 = full).
    let remainingBudgetFraction: Double
    /// A live streak is one missed log from breaking.
    let streakAtRisk: Bool
    /// Days since the last logged meal (0 = today).
    let daysSinceLastLog: Int
    /// Recent post-meal mood positivity in (0, 1); 0.5 = neutral / no signal.
    let recentMoodPositiveRate: Double
}

/// One surface asking to be shown, with everything the policy needs to rank it.
struct SurfaceCandidate: Equatable {
    let kind: SurfaceKind
    /// The surface's existing priority-chain weight (higher = more important).
    let basePriority: Double
    /// The surface's own "do I have anything to say" predicate. Ineligible
    /// candidates never show, whatever their score.
    let eligible: Bool
    /// Learned engagement preference in (0, 1) from taps/helpful feedback; 0.5
    /// = neutral. This is the bandit signal, generalized.
    var preference: Double = 0.5
    /// How relevant this surface is in the current context (0…1). Defaults to
    /// `SurfacePolicy.relevance(kind:in:)` at build time via `make(...)`.
    var contextRelevance: Double = 0.5
}

struct RankedSurface: Equatable {
    let kind: SurfaceKind
    let score: Double
}

enum SurfacePolicy {

    /// Bounded contributions, in the same "points" space as `basePriority` (the
    /// engine uses ~10-pt tiers). Preference and relevance can each move a
    /// surface about one tier — enough to reorder neighbours, not to leapfrog
    /// the whole chain.
    static let preferenceWeight: Double = 12
    static let relevanceWeight: Double = 12

    /// Feature-weighted relevance per surface kind — the "attention" scorer.
    /// Pure function of the state vector; each case is a small, legible rule
    /// (this is exactly what a learned attention head would approximate).
    static func relevance(_ kind: SurfaceKind, in ctx: SurfaceContext) -> Double {
        switch kind {
        case .streakNudge:
            return ctx.streakAtRisk ? 1.0 : 0.1
        case .comeback:
            // Ramps with dormancy; saturates at ~3 idle days.
            return min(1.0, Double(max(0, ctx.daysSinceLastLog)) / 3.0)
        case .eatToGoal:
            // Relevant while there's still room to eat toward the goal.
            return clamp01(ctx.remainingBudgetFraction)
        case .dailyQuest:
            // Actionable earlier in the day; fades once the day is closing out.
            return ctx.hour < 20 ? 0.6 : 0.2
        case .trendCoach:
            return 0.5
        case .foodOSMoment:
            // Slightly more compelling when the user has a clear mood signal.
            return clamp01(0.5 + (ctx.recentMoodPositiveRate - 0.5) * 0.3)
        case .recordsBanner:
            return 0.4
        case .firstScan:
            // The single highest-leverage action for a brand-new user; whenever
            // it's eligible it should lead the soft-nudge slot.
            return 1.0
        case .personalize:
            // "Tune your goals" — useful but never time-critical, so it yields
            // to an actionable eat-to-goal or first-scan nudge.
            return 0.4
        }
    }

    /// Build a candidate, auto-filling `contextRelevance` from the state vector.
    static func make(_ kind: SurfaceKind, basePriority: Double, eligible: Bool,
                     preference: Double = 0.5, context: SurfaceContext) -> SurfaceCandidate {
        SurfaceCandidate(kind: kind, basePriority: basePriority, eligible: eligible,
                         preference: preference,
                         contextRelevance: relevance(kind, in: context))
    }

    /// The unified score: priority chain + learned preference + context
    /// relevance. Preference is centered at 0.5 so neutral feedback is a no-op
    /// (an all-neutral, all-average-relevance vector reproduces the base
    /// priority order exactly — nothing regresses).
    static func score(_ c: SurfaceCandidate) -> Double {
        let prefAdj = (clamp01(c.preference) - 0.5) * 2 * preferenceWeight
        let relAdj = (clamp01(c.contextRelevance) - 0.5) * 2 * relevanceWeight
        return c.basePriority + prefAdj + relAdj
    }

    /// Rank the eligible candidates, highest score first. Deterministic
    /// tie-break by kind so the ordering is stable.
    static func rank(_ candidates: [SurfaceCandidate]) -> [RankedSurface] {
        candidates
            .filter(\.eligible)
            .map { RankedSurface(kind: $0.kind, score: score($0)) }
            .sorted { a, b in
                a.score != b.score ? a.score > b.score : a.kind.rawValue < b.kind.rawValue
            }
    }

    /// The single surface that wins the top slot (nil if none eligible).
    static func top(_ candidates: [SurfaceCandidate]) -> RankedSurface? {
        rank(candidates).first
    }

    /// Fill a fixed number of slots, best first, no duplicates.
    static func fill(slots: Int, from candidates: [SurfaceCandidate]) -> [RankedSurface] {
        Array(rank(candidates).prefix(max(0, slots)))
    }

    private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
}
