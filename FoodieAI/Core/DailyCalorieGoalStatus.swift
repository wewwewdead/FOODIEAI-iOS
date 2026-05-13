import Foundation

/// Snapshot of where the user sits against their daily calorie goal.
///
/// Centralizes the math + guards already used (ad-hoc) by `goalWarningState`
/// so the scan-warning flow on Home and the end-of-day reminder on Tracker
/// don't drift from the progress ring / macro bars.
///
/// Invariants:
///   - `consumed` is clamped to `>= 0`
///   - `progress` is finite (NaN/Inf collapse to 0)
///   - `remaining` is `max(0, goal - consumed)`
///   - `exceededBy` is `max(0, consumed - goal)`
///   - `hasValidGoal == false` iff `goal <= 0` or non-finite; consumers MUST
///     check this before surfacing any warning.
///
/// Visual progress can cap at 1.0 (callers do that), but this struct keeps
/// true values so callers can render "200 cal over" without re-deriving it.
struct DailyCalorieGoalStatus: Equatable {
    let consumed: Double
    let goal: Double
    let progress: Double
    let warningState: GoalWarningState
    let remaining: Double
    let exceededBy: Double
    let hasValidGoal: Bool

    /// Safe zero-state for callers that can't yet compute (no totals loaded,
    /// goal not yet hydrated). Renders as "no warning" everywhere.
    static let invalid = DailyCalorieGoalStatus(
        consumed: 0,
        goal: 0,
        progress: 0,
        warningState: .safe,
        remaining: 0,
        exceededBy: 0,
        hasValidGoal: false
    )

    static func compute(consumed: Double, goal: Double) -> DailyCalorieGoalStatus {
        let safeConsumed: Double = {
            guard consumed.isFinite else { return 0 }
            return max(0, consumed)
        }()
        guard goal.isFinite, goal > 0 else { return .invalid }

        let rawProgress = safeConsumed / goal
        let progress = rawProgress.isFinite ? rawProgress : 0
        return DailyCalorieGoalStatus(
            consumed: safeConsumed,
            goal: goal,
            progress: progress,
            warningState: goalWarningState(consumed: safeConsumed, goal: goal),
            remaining: max(0, goal - safeConsumed),
            exceededBy: max(0, safeConsumed - goal),
            hasValidGoal: true
        )
    }
}
