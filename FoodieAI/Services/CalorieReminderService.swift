import Foundation

/// Phase 20. Glue between today's calorie totals and the local-notification
/// scheduler for the end-of-day under-calorie reminder.
///
/// Responsibilities:
///   - compute the current `DailyCalorieGoalStatus` (consumed today vs. the
///     user's daily calorie goal)
///   - decide whether the scan-warning should surface on the Home flow
///   - decide whether the inline end-of-day reminder card should surface
///     on the Today screen
///   - schedule / cancel the local notification with a stable identifier
///
/// No UI code lives here. The service is intentionally side-effect-free
/// at construction; everything happens through `recompute`, which is safe
/// to call repeatedly (idempotent at the scheduler boundary — see
/// `NotificationScheduler.scheduleUnderCalorieReminder`).
@MainActor
final class CalorieReminderService {
    static let shared = CalorieReminderService()

    private let logService: FoodLogService
    private let profileService: ProfileService
    private let scheduler: NotificationScheduler

    /// Trigger window for the in-app reminder card: 22:00–23:59 local.
    /// Mirrors `NotificationScheduler.underCalorieReminderHour` so the
    /// notification and the inline card share the same idea of "near
    /// midnight."
    static let inAppReminderStartHour: Int = 22
    static let inAppReminderEndHour:   Int = 24 // exclusive upper bound

    init(logService: FoodLogService = FoodLogService(),
         profileService: ProfileService = ProfileService(),
         scheduler: NotificationScheduler? = nil) {
        self.logService = logService
        self.profileService = profileService
        self.scheduler = scheduler ?? .shared
    }

    // MARK: - Decision helpers (pure)

    /// True when the in-app banner should be visible right now. Caller
    /// is responsible for the per-session/per-day "don't keep showing"
    /// gate — see TodayView's dismissal flag.
    static func shouldShowEndOfDayUnderGoalReminder(
        now: Date,
        status: DailyCalorieGoalStatus,
        timeZone: TimeZone = .current
    ) -> Bool {
        guard status.hasValidGoal else { return false }
        // Only when the user is still meaningfully under goal. `.safe`
        // and `.approaching` both qualify; `.reached` (>= 100%) does not.
        guard status.warningState != .reached else { return false }
        guard status.remaining > 0 else { return false }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: now)
        return hour >= inAppReminderStartHour && hour < inAppReminderEndHour
    }

    // MARK: - Data fetch

    /// Fetch today's totals + the user's calorie goal in one shot, then
    /// build a `DailyCalorieGoalStatus`. Errors collapse to `.invalid`
    /// so callers can treat the result uniformly — a transient network
    /// blip should not surface a warning the user can't act on.
    func currentStatus(now: Date = Date(),
                       timeZone: TimeZone = .current) async -> DailyCalorieGoalStatus {
        async let logsTask: [FoodLog]? = try? logService.todaysLogs(timeZone: timeZone)
        async let profileTask: Profile? = try? profileService.currentProfile()

        let logs = (await logsTask) ?? []
        guard let profile = await profileTask else { return .invalid }

        let consumed = LocalDailyTotals.sum(logs).totalCalories
        let goal = Double(profile.dailyCalorieGoal)
        return DailyCalorieGoalStatus.compute(consumed: consumed, goal: goal)
    }

    // MARK: - Scheduling

    /// Recompute the status and schedule / cancel the local notification
    /// accordingly. Called from:
    ///   - `AppForegroundOrchestrator.runOnForeground` (every foreground)
    ///   - `CaptureViewModel.save` success path (after a meal lands)
    ///   - `TrackerViewModel.deleteLog` (after a meal is removed)
    ///   - `ProfileViewModel.save` success path (after goal changes)
    ///
    /// All callers are fire-and-forget — any failure resolves to "leave
    /// whatever the scheduler had alone."
    func recompute(now: Date = Date(),
                   timeZone: TimeZone = .current) async {
        let status = await currentStatus(now: now, timeZone: timeZone)

        guard status.hasValidGoal else {
            // No goal → can't reason about "under"; cancel any stale
            // pending notification so we don't ship the user a number
            // they didn't ask for.
            scheduler.cancelUnderCalorieReminder()
            return
        }

        // Reached goal → cancel; if user keeps consuming, no point
        // pinging them about a goal they've already met.
        guard status.warningState != .reached else {
            scheduler.cancelUnderCalorieReminder()
            return
        }

        // Under goal → schedule (one-shot for the next 22:00).
        await scheduler.scheduleUnderCalorieReminder(
            remaining: status.remaining,
            now: now,
            timeZone: timeZone
        )
    }

    /// Bypass the data fetch when the caller already has fresh totals on
    /// hand (e.g. TrackerViewModel just finished a refresh). Skips one
    /// round-trip per save/delete cycle.
    func recompute(consumed: Double,
                   goal: Double,
                   now: Date = Date(),
                   timeZone: TimeZone = .current) async {
        let status = DailyCalorieGoalStatus.compute(consumed: consumed, goal: goal)
        guard status.hasValidGoal else {
            scheduler.cancelUnderCalorieReminder()
            return
        }
        guard status.warningState != .reached else {
            scheduler.cancelUnderCalorieReminder()
            return
        }
        await scheduler.scheduleUnderCalorieReminder(
            remaining: status.remaining,
            now: now,
            timeZone: timeZone
        )
    }
}
