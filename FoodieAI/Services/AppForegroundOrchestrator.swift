import Foundation
import UserNotifications
import UIKit

/// Phase 17. Single entry point for "things to do when the signed-in
/// user opens the app or it foregrounds." Three jobs, in order:
///
///   1. Sync the device's timezone into `profiles.time_zone` if it's
///      missing or has changed (DST cross-overs included).
///   2. Generate the just-completed week's recap if it's Sunday after
///      19:00 or any time on Monday — see `shouldAttemptRecap`.
///   3. Reschedule local notifications based on the latest profile +
///      inferred eating times.
///
/// All three are best-effort and independently fail-safe; one failing
/// doesn't poison the others. None block the UI: `runOnForeground` is
/// fire-and-forget, called from FoodieAIApp's auth-bootstrap path.
@MainActor
final class AppForegroundOrchestrator {
    static let shared = AppForegroundOrchestrator()

    private let profileService: ProfileService
    private let recapService: WeeklyRecapService
    private let history: MealHistoryService
    private let scheduler: NotificationScheduler

    /// In-memory guard so the timezone write doesn't fire on every
    /// foreground (the device timezone rarely changes within a session,
    /// and we don't want the DB chatter).
    private var lastTimezoneCheck: Date?

    /// Single-flight dedupe for `runOnForeground`. Cold launch can
    /// race two legitimate observers in `FoodieAIApp` —
    /// `auth.isSignedIn→true` (after `auth.bootstrap()` restores a
    /// session) and `scenePhase→active` (when the window goes live).
    /// Whichever fires second arrives within milliseconds of the first
    /// and would otherwise trigger a redundant full reschedule cycle.
    /// Calls within `dedupeWindow` of the last accepted call are
    /// dropped. The window is small enough not to mask a deliberate
    /// background→foreground bounce, big enough to catch the launch race.
    private var lastRunStartedAt: Date?
    private static let dedupeWindow: TimeInterval = 0.5

    init(profileService: ProfileService = ProfileService(),
         recapService: WeeklyRecapService = WeeklyRecapService(),
         history: MealHistoryService = MealHistoryService(),
         scheduler: NotificationScheduler? = nil) {
        self.profileService = profileService
        self.recapService = recapService
        self.history = history
        // `.shared` is `@MainActor`-isolated; default-arg expressions
        // are evaluated in the caller's context, which Swift 6 will
        // refuse if non-MainActor. Resolve inside the init (which is
        // implicitly @MainActor because the type is) to keep the
        // ergonomics while staying Swift-6-clean.
        self.scheduler = scheduler ?? .shared
    }

    /// Kick off all three side-channels. Returns once the timezone +
    /// reschedule paths complete; recap generation is detached so the
    /// model round-trip doesn't hold the foreground task open.
    func runOnForeground(now: Date = Date(),
                         timeZone: TimeZone = .current,
                         caller: String = "unspecified") async {
        if let last = lastRunStartedAt,
           now.timeIntervalSince(last) < Self.dedupeWindow {
            #if DEBUG
            NSLog("[Notif] runOnForeground deduped (last %.3fs ago) caller=%@",
                  now.timeIntervalSince(last), caller)
            #endif
            return
        }
        lastRunStartedAt = now

        #if DEBUG
        NSLog("[Notif] runOnForeground triggered by: %@", caller)
        #endif

        // 1. Timezone sync (cheap; do first so step 3 reads a fresh value).
        let profile = await syncTimeZoneIfNeeded(now: now, deviceTZ: timeZone)

        // 2. Recap generation if the window is open. Detached so it
        //    doesn't gate the rest of the orchestrator.
        if Self.shouldAttemptRecap(now: now, timeZone: timeZone) {
            Task.detached { [recapService] in
                let (start, end) = WeekBounds.lastCompletedWeek(now: now, timeZone: timeZone)
                do {
                    if let recap = try await recapService.generateIfNeeded(
                        weekStart: start, weekEnd: end
                    ) {
                        #if DEBUG
                        NSLog("[Orchestrator] generated recap %@",
                              WeeklyRecap.yyyyMMdd.string(from: recap.weekStart))
                        #endif
                    }
                } catch {
                    #if DEBUG
                    NSLog("[Orchestrator] recap generate FAILED: %@", "\(error)")
                    #endif
                }
            }
        }

        // 3. Reschedule notifications. Reads inference + the (possibly
        //    just-updated) profile.
        await rescheduleNotifications(profile: profile, deviceTZ: timeZone)
    }

    // MARK: - Step 1: timezone

    /// Returns the profile we ended up with (refreshed if a write
    /// happened). Logging is verbose in DEBUG so we can confirm the
    /// "only writes when changed" invariant during verification.
    @discardableResult
    private func syncTimeZoneIfNeeded(now: Date,
                                      deviceTZ: TimeZone) async -> Profile? {
        // Throttle: skip if we already checked within the last hour.
        if let last = lastTimezoneCheck,
           now.timeIntervalSince(last) < 3600 {
            return try? await profileService.currentProfile()
        }
        lastTimezoneCheck = now

        guard let profile = try? await profileService.currentProfile() else {
            #if DEBUG
            NSLog("[Orchestrator] timezone sync skipped — currentProfile() failed")
            #endif
            return nil
        }
        let device = deviceTZ.identifier
        if profile.timeZone == device {
            return profile
        }
        do {
            let updated = try await profileService.setTimeZone(device)
            #if DEBUG
            NSLog("[Orchestrator] time_zone synced %@ → %@",
                  profile.timeZone ?? "<nil>", device)
            #endif
            return updated
        } catch {
            #if DEBUG
            NSLog("[Orchestrator] time_zone write FAILED: %@", "\(error)")
            #endif
            return profile
        }
    }

    // MARK: - Step 2: recap window

    /// True when:
    ///   - It's Sunday in the user's timezone AND local time >= 19:00, or
    ///   - It's any time on Monday in the user's timezone.
    /// The Monday clause catches users who didn't open Sunday evening.
    static func shouldAttemptRecap(now: Date, timeZone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let weekday = cal.component(.weekday, from: now) // 1=Sun, 2=Mon
        let hour = cal.component(.hour, from: now)
        if weekday == 1 && hour >= 19 { return true }
        if weekday == 2 { return true }
        return false
    }

    // MARK: - Step 3: notifications

    private func rescheduleNotifications(profile: Profile?,
                                         deviceTZ: TimeZone) async {
        guard let profile else { return }
        let prefs = NotificationPreferences(profile: profile)
        // Bail before doing the inference fetch when notifications are
        // off — saves a `food_logs` query and keeps the scheduler in
        // the clean-slate state.
        guard prefs.masterEnabled else {
            await scheduler.reschedule(
                preferences: prefs,
                inferred: .init(breakfast: nil, lunch: nil, dinner: nil,
                                confidence: .insufficient),
                timeZone: deviceTZ
            )
            return
        }

        let logs = (try? await history.recentMealsForCoachContext()) ?? []
        let inferred = EatingTimeInference.infer(from: logs, timeZone: deviceTZ)

        // Use the profile's tz when present (server-side captured), else
        // fall back to the device's. They normally agree post step 1
        // but can diverge transiently.
        let scheduleTZ = profile.timeZone.flatMap { TimeZone(identifier: $0) } ?? deviceTZ
        await scheduler.reschedule(
            preferences: prefs, inferred: inferred, timeZone: scheduleTZ
        )
    }

    // MARK: - Save-flow suppression hook

    /// Phase 17. Called from `CaptureViewModel` after a successful
    /// food_logs insert. Picks the meal window from `eatenAt` and
    /// suppresses today's recurring reminder for that window so the
    /// app doesn't nudge a user who just logged.
    func suppressWindow(for eatenAt: Date,
                        deviceTZ: TimeZone = .current) async {
        guard let window = MealWindow.window(for: eatenAt, timeZone: deviceTZ) else {
            return
        }

        // Need to know the recurring time for the window so the one-shot
        // tomorrow replacement fires at the same hour:minute.
        guard let profile = try? await profileService.currentProfile(),
              profile.notificationsEnabled else {
            return
        }
        let logs = (try? await history.recentMealsForCoachContext()) ?? []
        let inferred = EatingTimeInference.infer(from: logs, timeZone: deviceTZ)

        let comps: DateComponents?
        switch window {
        case .breakfast: comps = inferred.breakfast
        case .lunch:     comps = inferred.lunch
        case .dinner:    comps = inferred.dinner
        }
        guard let comps else { return }

        // Only suppress if the window's reminder is actually enabled
        // for this user.
        let prefs = NotificationPreferences(profile: profile)
        let enabled: Bool
        switch window {
        case .breakfast: enabled = prefs.breakfast
        case .lunch:     enabled = prefs.lunch
        case .dinner:    enabled = prefs.dinner
        }
        guard enabled else { return }

        let scheduleTZ = profile.timeZone.flatMap { TimeZone(identifier: $0) } ?? deviceTZ
        await scheduler.suppressTodaysWindow(
            window, recurringComps: comps, timeZone: scheduleTZ
        )
    }
}
