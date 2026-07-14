import Foundation
import WidgetKit

/// App-side bridge to the home-screen widget: writes the latest daily-loop
/// snapshot to the shared App Group container and asks WidgetKit to refresh
/// its timelines. Skips the write (and the reload) when nothing meaningful
/// changed, so it's cheap to call on every Today render.
///
/// No-ops safely until the App Group capability is added (`WidgetBridge`'s
/// suite is nil before that), so wiring this in now is harmless. Once the
/// widget target + App Group exist (see `WIDGET_SETUP.md`), the widget starts
/// reflecting live data with no further app changes.
enum WidgetSnapshotUpdater {
    static func write(streakDays: Int,
                      caloriesConsumed: Int,
                      calorieGoal: Int,
                      steps: Int,
                      stepGoal: Int,
                      suggestion: String,
                      movementCreditKcal: Int = 0,
                      now: Date = Date()) {
        let snapshot = WidgetSnapshot(
            streakDays: max(0, streakDays),
            caloriesConsumed: max(0, caloriesConsumed),
            calorieGoal: max(0, calorieGoal),
            steps: max(0, steps),
            stepGoal: max(0, stepGoal),
            updatedAt: now,
            suggestion: suggestion,
            movementCreditKcal: max(0, movementCreditKcal)
        )

        // Skip needless writes/reloads when only the timestamp would change.
        let existing = WidgetBridge.read()
        if existing.streakDays == snapshot.streakDays,
           existing.caloriesConsumed == snapshot.caloriesConsumed,
           existing.calorieGoal == snapshot.calorieGoal,
           existing.steps == snapshot.steps,
           existing.stepGoal == snapshot.stepGoal,
           existing.suggestion == snapshot.suggestion,
           (existing.movementCreditKcal ?? 0) == (snapshot.movementCreditKcal ?? 0) {
            return
        }

        WidgetBridge.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Background-only update of just the step count, used by the HealthKit
    /// background-delivery observer (`HealthActivityService.enableWidgetBackgroundSync`).
    /// On a background launch the DB-backed fields (calories, streak, coach
    /// line) aren't available — and don't change from walking anyway — so we
    /// refresh only `steps` on the last snapshot the app wrote. Rolls the
    /// snapshot over first so a wake on a new day starts the daily figures at 0.
    /// Skips the cross-process reload on an idle hour (same day, count
    /// unchanged) so we don't spend the widget's limited daily reload budget.
    static func updateSteps(_ steps: Int, now: Date = Date()) {
        let current = WidgetBridge.read()
        let newSteps = max(0, steps)
        if current.isFromSameDay(as: now), current.steps == newSteps { return }

        var snapshot = current.rolledOver(to: now)
        snapshot.steps = newSteps
        snapshot.updatedAt = now
        WidgetBridge.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
