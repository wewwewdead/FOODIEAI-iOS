import Foundation
import UserNotifications
import UIKit

/// Phase 17. Single owner of all interaction with
/// `UNUserNotificationCenter`. Everything that schedules, suppresses,
/// or cancels a notification routes through here.
///
/// Notification cap: at most **4** scheduled at a time
///   (3 meal reminders + 1 weekly recap).
/// The system allows up to 64; we're well under, but the cap is
/// documented here so any future addition is intentional.
///
/// Identifier conventions (so cancel-and-replace is unambiguous):
///   - `reminder.breakfast.recurring`  — daily breakfast nudge
///   - `reminder.lunch.recurring`      — daily lunch nudge
///   - `reminder.dinner.recurring`     — daily dinner nudge
///   - `reminder.<window>.suppressed`  — one-shot, fires next-day at the
///                                        recurring time, replaces the
///                                        recurring trigger for today
///   - `recap.weekly`                  — Sunday 19:00 recurring
///
/// User-info keys passed via the trigger so the tap router knows what
/// the user just opened:
///   - `kind`     : "reminder" | "recap"
///   - `window`   : "breakfast" | "lunch" | "dinner" (reminders only)
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()

    /// Limits documented in the file header. Used in DEBUG asserts to
    /// catch any accidental over-scheduling during development.
    static let maxScheduledNotifications = 4

    // MARK: - Identifiers

    enum Identifier {
        static let breakfastRecurring = "reminder.breakfast.recurring"
        static let lunchRecurring     = "reminder.lunch.recurring"
        static let dinnerRecurring    = "reminder.dinner.recurring"
        static let recapWeekly        = "recap.weekly"

        /// End-of-day under-calorie reminder. One-shot, replaced each time
        /// the user saves/deletes a meal or changes their calorie goal. The
        /// identifier is stable across reschedules so cancel-and-replace
        /// never spawns duplicates (see `scheduleUnderCalorieReminder`).
        static let underCalorieReminder = "daily_under_calorie_reminder"

        /// One-shot replacement for today's cancelled recurring reminder.
        /// Fires tomorrow at the same time as today's recurring would have.
        static func suppressed(for window: MealWindow) -> String {
            "reminder.\(window.rawValue).suppressed"
        }

        static func recurring(for window: MealWindow) -> String {
            switch window {
            case .breakfast: return breakfastRecurring
            case .lunch:     return lunchRecurring
            case .dinner:    return dinnerRecurring
            }
        }

        /// All identifiers we ever produce. Used by `cancelAll(...)`
        /// to make rescheduling deterministic.
        static let allRecurringMealReminders: [String] = [
            breakfastRecurring, lunchRecurring, dinnerRecurring,
        ]
        static let allSuppressed: [String] = [
            "reminder.breakfast.suppressed",
            "reminder.lunch.suppressed",
            "reminder.dinner.suppressed",
        ]
    }

    // MARK: - Authorization

    /// Request notification authorization. Returns `true` if granted.
    /// Idempotent: if already authorized, returns true without prompting.
    /// If already denied, returns false (system won't re-prompt — caller
    /// is responsible for routing to Settings.app).
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            #if DEBUG
            NSLog("[Notif] requestAuthorization granted=%@", "\(granted)")
            #endif
            return granted
        } catch {
            #if DEBUG
            NSLog("[Notif] requestAuthorization FAILED: %@", "\(error)")
            #endif
            return false
        }
    }

    /// Current authorization status without prompting. Use this from
    /// the settings UI to render the "open Settings.app" affordance
    /// when the user has previously denied.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { cont in
            center.getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
    }

    // MARK: - Reschedule

    /// Cancel all pending Phase-17 notifications and reschedule based
    /// on the latest preferences and inferred eating times. Call after:
    ///   - Profile preferences change
    ///   - A meal is saved (might suppress a window — handled by
    ///     `suppressTodaysWindow`, which uses this internally)
    ///   - App enters foreground (catch any drift, e.g. crossed DST)
    ///
    /// `preferences.masterEnabled == false` cancels everything, full stop.
    /// Per-meal flags off → that reminder is cancelled but others remain.
    func reschedule(preferences: NotificationPreferences,
                    inferred: EatingTimeInference.InferredTimes,
                    timeZone: TimeZone = .current) async {
        #if DEBUG
        func fmt(_ c: DateComponents?) -> String {
            guard let c, let h = c.hour, let m = c.minute else { return "nil" }
            return String(format: "%02d:%02d", h, m)
        }
        let tier: String
        switch inferred.confidence {
        case .insufficient: tier = "insufficient"
        case .low:          tier = "low"
        case .good:         tier = "good"
        }
        NSLog("[Notif] inferred = breakfast:%@ lunch:%@ dinner:%@ confidence:%@",
              fmt(inferred.breakfast), fmt(inferred.lunch),
              fmt(inferred.dinner), tier)
        #endif

        // Always start from a clean slate for the identifiers we own.
        cancelAll()

        guard preferences.masterEnabled else {
            #if DEBUG
            NSLog("[Notif] reschedule: master OFF, cleared all reminders")
            #endif
            return
        }

        if preferences.breakfast, let comps = inferred.breakfast {
            await scheduleRecurring(
                window: .breakfast, comps: comps, timeZone: timeZone
            )
        }
        if preferences.lunch, let comps = inferred.lunch {
            await scheduleRecurring(
                window: .lunch, comps: comps, timeZone: timeZone
            )
        }
        if preferences.dinner, let comps = inferred.dinner {
            await scheduleRecurring(
                window: .dinner, comps: comps, timeZone: timeZone
            )
        }
        if preferences.weeklyRecap {
            await scheduleWeeklyRecap(timeZone: timeZone, enabled: true)
        }

        #if DEBUG
        await dumpPending(prefix: "[Notif] after reschedule:")
        #endif
    }

    // MARK: - Suppression

    /// User saved a meal in `window`. Cancel today's recurring trigger
    /// for that window — but keep the recurring schedule alive for
    /// tomorrow forward. Implementation detail: the recurring
    /// `UNCalendarNotificationTrigger` with `repeats: true` will fire
    /// at the next matching `DateComponents` after now. So if it's
    /// 12:31 PM and we just logged lunch, the next fire is *tomorrow*
    /// at the lunch hour — which is exactly what we want, no
    /// suppression work needed.
    ///
    /// However, if the user saves a meal *before* its window's time
    /// (e.g., logs lunch at 11:45 because they ate early), the today's
    /// 12:30 reminder would still fire — feels wrong. To handle that,
    /// we cancel-and-replace with a one-shot for tomorrow at the same
    /// time, then on the next reschedule (next foreground or save) we
    /// reinstate the recurring trigger.
    func suppressTodaysWindow(_ window: MealWindow,
                              recurringComps: DateComponents,
                              timeZone: TimeZone = .current) async {
        let recurringId = Identifier.recurring(for: window)
        let suppressedId = Identifier.suppressed(for: window)

        center.removePendingNotificationRequests(
            withIdentifiers: [recurringId, suppressedId]
        )

        // Compute "tomorrow at the same hour:minute in user's tz".
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let now = Date()
        let today = cal.startOfDay(for: now)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { return }

        var tomorrowComps = cal.dateComponents([.year, .month, .day], from: tomorrow)
        tomorrowComps.hour = recurringComps.hour
        tomorrowComps.minute = recurringComps.minute
        tomorrowComps.timeZone = timeZone

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: tomorrowComps, repeats: false
        )
        let content = makeContent(for: window)
        let request = UNNotificationRequest(
            identifier: suppressedId, content: content, trigger: trigger
        )

        do {
            try await center.add(request)
            #if DEBUG
            NSLog("[Notif] suppressed today's %@ — one-shot scheduled for tomorrow %02d:%02d",
                  window.rawValue, recurringComps.hour ?? -1, recurringComps.minute ?? -1)
            #endif
        } catch {
            #if DEBUG
            NSLog("[Notif] suppress %@ FAILED: %@", window.rawValue, "\(error)")
            #endif
        }

        #if DEBUG
        await dumpPending(prefix: "[Notif] after suppress:")
        #endif
    }

    // MARK: - Weekly recap

    /// Schedule (or cancel) the Sunday 19:00 recap. Idempotent: cancels
    /// any prior recap request before scheduling the new one.
    func scheduleWeeklyRecap(timeZone: TimeZone, enabled: Bool) async {
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.recapWeekly]
        )
        guard enabled else { return }

        // Sunday in `Calendar.Component.weekday` = 1.
        var dateComponents = DateComponents()
        dateComponents.weekday = 1
        dateComponents.hour = 19
        dateComponents.minute = 0
        dateComponents.timeZone = timeZone

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents, repeats: true
        )

        let content = UNMutableNotificationContent()
        content.title = "Your week with Foodie is ready"
        content.body = "A short recap from your coach."
        content.sound = .default
        content.userInfo = ["kind": "recap"]

        let request = UNNotificationRequest(
            identifier: Identifier.recapWeekly,
            content: content, trigger: trigger
        )

        do {
            try await center.add(request)
            #if DEBUG
            NSLog("[Notif] scheduled weekly recap for Sunday 19:00 in %@",
                  timeZone.identifier)
            #endif
        } catch {
            #if DEBUG
            NSLog("[Notif] weekly-recap schedule FAILED: %@", "\(error)")
            #endif
        }
    }

    // MARK: - Under-calorie reminder (Phase 20)

    /// Default trigger hour for the end-of-day under-calorie reminder.
    /// 22:00 local time gives roughly two hours before midnight — enough
    /// room to log a missed meal without nagging during dinner.
    static let underCalorieReminderHour = 22

    /// Schedule a one-shot under-calorie reminder at the next 22:00 local
    /// time. Idempotent — any prior pending request with the same
    /// identifier is removed first so the user never sees duplicates.
    ///
    /// `remaining` is plumbed into the body copy so the user sees a
    /// concrete number, not a generic nudge. Caller is responsible for
    /// only invoking this when the user is actually under goal; this
    /// method does NOT re-evaluate the calorie status.
    ///
    /// If notification authorization isn't granted, this is a no-op
    /// (UNUserNotificationCenter rejects `add` silently in that case
    /// anyway, but the explicit check avoids spurious DEBUG noise).
    func scheduleUnderCalorieReminder(remaining: Double,
                                      now: Date = Date(),
                                      timeZone: TimeZone = .current) async {
        // Authorization check — skip the work if we wouldn't be allowed
        // to deliver. `provisional` and `authorized` are both deliverable.
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else {
            #if DEBUG
            NSLog("[Notif] underCalorie: skip schedule — auth=%d", status.rawValue)
            #endif
            // Make sure no stale request lingers from a previous grant.
            center.removePendingNotificationRequests(
                withIdentifiers: [Identifier.underCalorieReminder]
            )
            return
        }

        // Always remove first; we replace rather than mutate.
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.underCalorieReminder]
        )

        // Build the next 22:00 local-time fire date. If `now` is already
        // past 22:00, advance one day — we don't fire an immediate
        // notification while the app is active.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        guard var fireDate = cal.date(
            bySettingHour: Self.underCalorieReminderHour,
            minute: 0, second: 0, of: today
        ) else { return }
        if fireDate <= now {
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: fireDate) else {
                return
            }
            fireDate = tomorrow
        }

        var fireComps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        fireComps.timeZone = timeZone

        // One-shot, not repeating: the next day's schedule needs a fresh
        // re-evaluation (the user might already be on track tomorrow).
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: fireComps, repeats: false
        )

        let content = UNMutableNotificationContent()
        content.title = "Still under your calorie goal"
        content.body  = Self.underCalorieBody(remaining: remaining)
        content.sound = .default
        content.userInfo = ["kind": "under_calorie_reminder"]

        let request = UNNotificationRequest(
            identifier: Identifier.underCalorieReminder,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            #if DEBUG
            NSLog("[Notif] underCalorie scheduled for %@ (remaining=%.0f)",
                  "\(fireDate)", remaining)
            #endif
        } catch {
            #if DEBUG
            NSLog("[Notif] underCalorie schedule FAILED: %@", "\(error)")
            #endif
        }
    }

    /// Cancel any pending under-calorie reminder. Safe to call when none
    /// is scheduled — `removePendingNotificationRequests` is a no-op for
    /// unknown identifiers.
    func cancelUnderCalorieReminder() {
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.underCalorieReminder]
        )
    }

    /// Round the remaining calories to a friendly multiple so the body
    /// reads naturally. Avoids "423.7 calories left" while keeping the
    /// number honest enough to be actionable.
    private static func underCalorieBody(remaining: Double) -> String {
        // Round to the nearest 10 above 100, nearest 5 below — picks a
        // number a human would say out loud.
        let value = max(0, remaining)
        let rounded: Int
        if value >= 100 {
            rounded = Int((value / 10).rounded()) * 10
        } else {
            rounded = Int((value / 5).rounded()) * 5
        }
        if rounded <= 0 {
            return "You still have room left today. Want to log your last meal?"
        }
        return "You have about \(rounded) calories left today. Want to log your last meal?"
    }

    // MARK: - Internal scheduling

    private func scheduleRecurring(window: MealWindow,
                                   comps: DateComponents,
                                   timeZone: TimeZone) async {
        var dateComponents = DateComponents()
        dateComponents.hour = comps.hour
        dateComponents.minute = comps.minute
        dateComponents.timeZone = timeZone

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents, repeats: true
        )
        let content = makeContent(for: window)

        let id = Identifier.recurring(for: window)
        let request = UNNotificationRequest(
            identifier: id, content: content, trigger: trigger
        )

        do {
            try await center.add(request)
            #if DEBUG
            NSLog("[Notif] scheduled %@ for %02d:%02d (tz=%@)",
                  id, comps.hour ?? -1, comps.minute ?? -1, timeZone.identifier)
            #endif
        } catch {
            #if DEBUG
            NSLog("[Notif] schedule %@ FAILED: %@", id, "\(error)")
            #endif
        }
    }

    /// Cancels every identifier this scheduler ever produces — both
    /// recurring meal reminders and any in-flight suppressed one-shots.
    /// The weekly recap is intentionally NOT cancelled here; it has its
    /// own lifecycle managed by `scheduleWeeklyRecap`.
    private func cancelAll() {
        center.removePendingNotificationRequests(
            withIdentifiers:
                Identifier.allRecurringMealReminders +
                Identifier.allSuppressed
        )
    }

    /// Build content for a meal-window reminder. Tagline is picked
    /// deterministically by day-of-week so the "same Tuesday-12:30
    /// reminder" doesn't repeat the same line every week, but stays
    /// stable within a given day (no flickering between reschedules).
    private func makeContent(for window: MealWindow) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = window.title
        content.body = Self.tagline(for: window, weekday: Self.todayWeekday())
        content.sound = .default
        content.userInfo = ["kind": "reminder", "window": window.rawValue]
        return content
    }

    private static func todayWeekday() -> Int {
        Calendar.current.component(.weekday, from: Date())
    }

    /// Friendly, non-naggy taglines indexed by weekday (1...7,
    /// Sunday-first). Picks deterministic per-day; same window on the
    /// same weekday says the same thing week-to-week.
    private static func tagline(for window: MealWindow, weekday: Int) -> String {
        let pool: [String]
        switch window {
        case .breakfast:
            pool = [
                "Morning. Snap it when you're ready.",
                "Whatever you're having — capture it.",
                "Breakfast time? No rush.",
                "A photo when you eat is enough.",
                "Easy start. Snap it.",
                "Whenever you're ready.",
                "Morning meal — when it lands.",
            ]
        case .lunch:
            pool = [
                "Lunch time? Snap it when you're ready.",
                "Midday meal — capture it.",
                "Whenever you eat, the photo's enough.",
                "Lunch — no pressure.",
                "Eat first, snap second.",
                "Quick photo when you can.",
                "Mid-day check-in.",
            ]
        case .dinner:
            pool = [
                "Dinner time? Snap it when you're ready.",
                "Evening meal — capture it.",
                "No rush — photo when you eat.",
                "Dinner. Whenever.",
                "End-of-day check-in.",
                "Eat well. Snap it.",
                "Last meal? Tap it in.",
            ]
        }
        let idx = max(0, weekday - 1) % pool.count
        return pool[idx]
    }

    // MARK: - Debug

    #if DEBUG
    /// List currently pending notifications. Used by the verification
    /// runbook (Step 3) and the in-app debug log when settings change.
    func dumpPending(prefix: String = "[Notif] pending:") async {
        let pending = await center.pendingNotificationRequests()
        NSLog("%@ count=%d", prefix, pending.count)
        for req in pending {
            let trig = (req.trigger as? UNCalendarNotificationTrigger)?
                .dateComponents.description ?? "<non-calendar>"
            NSLog("%@   id=%@ title=\"%@\" trigger=%@",
                  prefix, req.identifier, req.content.title, trig)
        }
        if pending.count > Self.maxScheduledNotifications {
            NSLog("⚠️ Phase 17 cap exceeded: %d > %d",
                  pending.count, Self.maxScheduledNotifications)
        }
    }
    #endif
}

// MARK: - Public value types

/// Phase 17. The four toggles + master switch the notification flow
/// reads from. Mirrors the per-column shape on `profiles` so the
/// settings UI can map directly.
struct NotificationPreferences: Equatable {
    let masterEnabled: Bool
    let breakfast: Bool
    let lunch: Bool
    let dinner: Bool
    let weeklyRecap: Bool

    init(masterEnabled: Bool,
         breakfast: Bool,
         lunch: Bool,
         dinner: Bool,
         weeklyRecap: Bool) {
        self.masterEnabled = masterEnabled
        self.breakfast = breakfast
        self.lunch = lunch
        self.dinner = dinner
        self.weeklyRecap = weeklyRecap
    }

    /// Convenience: hydrate from a `Profile` row.
    init(profile: Profile) {
        self.init(
            masterEnabled: profile.notificationsEnabled,
            breakfast:     profile.reminderBreakfast,
            lunch:         profile.reminderLunch,
            dinner:        profile.reminderDinner,
            weeklyRecap:   profile.weeklyRecapEnabled
        )
    }

    /// Default disabled set — used as a fallback when no profile is
    /// available yet.
    static let disabled = NotificationPreferences(
        masterEnabled: false, breakfast: false, lunch: false,
        dinner: false, weeklyRecap: false
    )
}

enum MealWindow: String, Hashable {
    case breakfast, lunch, dinner

    var title: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch:     return "Lunch"
        case .dinner:    return "Dinner"
        }
    }

    /// Map an `eatenAt` Date to a meal window using the same hour
    /// ranges `EatingTimeInference` clusters by. Used by the save-flow
    /// suppression hook to decide *which* window the meal landed in.
    static func window(for date: Date,
                       timeZone: TimeZone = .current) -> MealWindow? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let h = cal.component(.hour, from: date)
        if EatingTimeInference.Window.breakfast.hourRange.contains(h) {
            return .breakfast
        }
        if EatingTimeInference.Window.lunch.hourRange.contains(h) {
            return .lunch
        }
        if EatingTimeInference.Window.dinner.hourRange.contains(h) {
            return .dinner
        }
        return nil
    }
}
