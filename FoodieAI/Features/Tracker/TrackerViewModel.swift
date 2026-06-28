import Foundation

/// Drives the Tracker tab's Today + Records segments: loads today's
/// `food_logs` for the signed-in user (in their local time zone, per Phase 0
/// Q2), computes totals, and reads the streak snapshot off the profile.
///
/// Reflection (patterns / coach observation / weekly recap) moved to the
/// Insights tab — see `ReflectionLoader`. That keeps "what the app notices"
/// in one place and, crucially, means this view model no longer loads it, so
/// the same reads don't run on both tabs.
///
/// Refresh policy: caller invokes `refresh()` from `.task` on appear and from
/// `.refreshable` (pull-to-refresh). Switching to the tab re-fetches when
/// stale, accepting a brief flicker in exchange for not plumbing a shared
/// save-event publisher (matches the Phase 6 v1 sync model).
@MainActor
final class TrackerViewModel: ObservableObject {
    enum State {
        case loading
        case empty
        case loaded(logs: [FoodLog], totals: LocalDailyTotals)
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    /// Streak snapshot read off the user's Profile. Loaded alongside today's
    /// logs so the streak chip (Today) and the Records hero reflect the
    /// latest server state on every refresh. `nil` means "not loaded yet" —
    /// the chip is hidden when nil OR when the count is 0.
    @Published private(set) var streakDays: Int? = nil
    @Published private(set) var longestStreakDays: Int? = nil
    @Published private(set) var graceDaysRemaining: Int? = nil

    private let logService: FoodLogService
    private let profileService: ProfileService
    private let timeZone: TimeZone

    /// Re-entrancy guard. `refresh()` is called from `.task` and
    /// `.refreshable`; rapid tab switches + pull-to-refresh can stack
    /// concurrent requests against the same Supabase session.
    private var isRefreshing = false
    private var lastSuccessfulRefreshAt: Date?
    private var isDirty = true
    private let automaticRefreshFreshness: TimeInterval = 25

    init(logService: FoodLogService = FoodLogService(),
         profileService: ProfileService = ProfileService.shared,
         timeZone: TimeZone = .current) {
        self.logService = logService
        self.profileService = profileService
        self.timeZone = timeZone
    }

    @discardableResult
    func refresh(reason: RefreshReason = .pullToRefresh,
                 now: Date = Date(),
                 tab: AppTab? = nil) async -> Bool {
        guard shouldRefresh(reason: reason, now: now) else { return false }
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        if let tab { TabPerformanceProbe.refreshStarted(tab) }
        defer { if let tab { TabPerformanceProbe.refreshEnded(tab) } }

        // Don't flash `.loading` over an existing loaded state — pull-to-
        // refresh should keep the rows visible while the fetch is in flight.
        if case .loaded = state {
            // keep showing prior data until the new query settles
        } else {
            state = .loading
        }

        // Today's logs + the streak snapshot, in parallel. The streak load is
        // wrapped in `try?` so a transient profile failure doesn't poison the
        // primary fetch.
        async let logsTask = logService.todaysLogs(timeZone: timeZone)
        async let profileForStreakTask: Profile? = try? profileService.currentProfile()

        do {
            let logs = try await logsTask
            applyStreak(await profileForStreakTask)

            #if DEBUG
            NSLog("[Tracker] todaysLogs=%d (tz=%@)", logs.count, timeZone.identifier)
            #endif

            if logs.isEmpty {
                state = .empty
            } else {
                state = .loaded(logs: logs, totals: LocalDailyTotals.sum(logs))
            }
            lastSuccessfulRefreshAt = now
            isDirty = false
            return true
        } catch is CancellationError {
            // SwiftUI cancelled `.task` (segment/tab churn). Leave state alone.
            return true
        } catch {
            #if DEBUG
            NSLog("[Tracker] refresh FAILED: %@", "\(error)")
            #endif
            applyStreak(await profileForStreakTask)
            state = .failed(error)
            return true
        }
    }

    private func applyStreak(_ profile: Profile?) {
        guard let profile else { return }
        self.streakDays         = profile.currentStreakDays
        self.longestStreakDays  = profile.longestStreakDays
        self.graceDaysRemaining = profile.graceDaysRemaining
    }

    func markDirty() {
        isDirty = true
    }

    private func shouldRefresh(reason: RefreshReason, now: Date) -> Bool {
        if reason.isUserInitiated || reason == .foodLogChanged || isDirty {
            return true
        }
        guard let lastSuccessfulRefreshAt else { return true }
        return now.timeIntervalSince(lastSuccessfulRefreshAt) >= automaticRefreshFreshness
    }

    /// Delete a saved meal (DB row + storage objects), then refresh so the
    /// totals/ring/macro bars settle to the new state.
    func deleteLog(_ log: FoodLog) async {
        do {
            try await logService.delete(log)
        } catch {
            #if DEBUG
            NSLog("[Tracker] delete FAILED for %@: %@",
                  log.id.uuidString, "\(error)")
            #endif
        }
        await refresh()
        // Deleting a meal can drop the user back under their calorie goal —
        // re-evaluate the end-of-day under-calorie notification.
        Task {
            await CalorieReminderService.shared.recompute()
        }
    }
}
