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

    /// Coalescing state for the fetch-based `recompute()`. Foreground,
    /// save-success, delete, and profile-goal changes can each fire an
    /// overlapping recompute within milliseconds of each other. Rather
    /// than dropping the duplicate (which would let stale totals win —
    /// e.g. foreground-recompute starts, user saves a meal, save-success
    /// recompute is dropped, and the original foreground decision based
    /// on pre-save totals is what lands), we *coalesce*: only one fetch
    /// runs at a time, but if any new call arrives during the await, the
    /// active recompute loops once more with fresh data before returning.
    private var isFetchRecomputing = false
    private var needsAnotherFetch = false

    /// Monotonic generation counter. Every recompute call (fetch or
    /// direct-data) bumps this, and an in-flight fetch only applies its
    /// decision if the generation it claimed is still current. Prevents
    /// the classic stale-async race: an older fetch finishes *after* a
    /// newer direct-data call and overwrites the fresh decision with
    /// stale totals.
    private var latestGeneration: UInt64 = 0

    init(logService: FoodLogService = FoodLogService(),
         profileService: ProfileService = ProfileService(),
         scheduler: NotificationScheduler? = nil) {
        self.logService = logService
        self.profileService = profileService
        self.scheduler = scheduler ?? .shared
    }

    /// Bump and return the new generation. Called from both recompute
    /// entry points and once per coalesced fetch pass. `&+=` so we never
    /// trap on overflow in the (astronomically unlikely) 2^64th call.
    private func nextGeneration() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
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
    ///
    /// Concurrency model: only one fetch runs at a time. If another call
    /// arrives mid-fetch (foreground + save-success arriving back-to-back
    /// is the common case), we set `needsAnotherFetch` and the active
    /// loop performs one more pass with fresh data before returning. This
    /// guarantees the freshest event lands in the final decision, while
    /// avoiding duplicate concurrent network round-trips.
    func recompute(now: Date = Date(),
                   timeZone: TimeZone = .current) async {
        if isFetchRecomputing {
            needsAnotherFetch = true
            #if DEBUG
            NSLog("[CalorieReminder] recompute coalesced — re-run queued")
            #endif
            return
        }

        isFetchRecomputing = true
        defer { isFetchRecomputing = false }

        repeat {
            needsAnotherFetch = false
            let generation = nextGeneration()
            let status = await currentStatus(now: now, timeZone: timeZone)

            // Stale-result guard: if a `recompute(consumed:goal:)` call
            // bumped the generation while we were fetching, its decision
            // is authoritative (caller had fresher data than we do).
            // Skip applying our stale fetch — but still honour
            // `needsAnotherFetch` so a queued plain recompute() runs.
            guard generation == latestGeneration else {
                #if DEBUG
                NSLog("[CalorieReminder] dropping stale fetch (gen=%llu latest=%llu)",
                      generation, latestGeneration)
                #endif
                continue
            }

            await applyReminderDecision(
                status: status, now: now, timeZone: timeZone
            )
        } while needsAnotherFetch
    }

    /// Bypass the data fetch when the caller already has fresh totals on
    /// hand (e.g. TrackerViewModel just finished a refresh). Skips one
    /// round-trip per save/delete cycle.
    ///
    /// Never gated by the fetch coalescing — the caller's data is, by
    /// definition, fresher than anything an in-flight fetch could
    /// produce. Bumps the generation so any concurrent fetch's stale
    /// result is discarded rather than overwriting this decision.
    func recompute(consumed: Double,
                   goal: Double,
                   now: Date = Date(),
                   timeZone: TimeZone = .current) async {
        _ = nextGeneration()
        let status = DailyCalorieGoalStatus.compute(consumed: consumed, goal: goal)
        #if DEBUG
        NSLog("[CalorieReminder] direct-data apply gen=%llu state=%@ consumed=%.0f goal=%.0f",
              latestGeneration, "\(status.warningState)", status.consumed, status.goal)
        #endif
        await applyReminderDecision(
            status: status, now: now, timeZone: timeZone
        )
    }

    // MARK: - Shared decision

    /// Single place where `DailyCalorieGoalStatus` becomes a
    /// schedule/cancel call. Kept private so both recompute paths funnel
    /// through identical logic — keeps the fetch and direct-data paths
    /// from drifting.
    ///
    /// `scheduleUnderCalorieReminder` already removes any prior pending
    /// request with the same identifier before adding a new one, so
    /// repeated apply calls never spawn duplicates.
    private func applyReminderDecision(status: DailyCalorieGoalStatus,
                                       now: Date,
                                       timeZone: TimeZone) async {
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
}
