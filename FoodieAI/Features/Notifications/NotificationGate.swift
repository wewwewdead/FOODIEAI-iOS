import Foundation
import UserNotifications

/// Phase 17. Owns the local bookkeeping that decides *when* to first
/// present `NotificationPermissionView`. Two rules from the prompt:
///
///   1. Don't prompt until the app has earned trust → wait until the
///      user's third successful save.
///   2. Don't re-prompt for 30 days if the user picked "Not now".
///
/// Both pieces of state live in UserDefaults — local-only is fine
/// because they're decisions about prompting, not data the user
/// expects to roam between devices.
@MainActor
enum NotificationGate {
    private static let savesKey       = "phase17.savesSinceInstall"
    private static let deferredKey    = "phase17.permissionDeferredUntil"
    private static let didPromptKey   = "phase17.didPresentPermissionOnce"

    /// Saves required before the permission sheet is allowed to fire.
    /// Set to 3 per the prompt; lowered for QA via the debug helper.
    static let savesThreshold = 3

    /// Defer-window after the user picks "Not now" — they won't see
    /// the sheet again for 30 days. (System permission state is
    /// independent; this is the in-app *re-prompt* cadence.)
    static let deferDays = 30

    // MARK: - State accessors

    static var savesSinceInstall: Int {
        UserDefaults.standard.integer(forKey: savesKey)
    }

    static var didPromptOnce: Bool {
        UserDefaults.standard.bool(forKey: didPromptKey)
    }

    static var deferredUntil: Date? {
        UserDefaults.standard.object(forKey: deferredKey) as? Date
    }

    // MARK: - Mutators

    /// Increment the local saves counter. Caller is `CaptureViewModel`
    /// after a successful `food_logs` insert (the analyze→save path,
    /// not re-logs — re-logs aren't a "first save" milestone).
    static func recordSave() {
        let next = savesSinceInstall + 1
        UserDefaults.standard.set(next, forKey: savesKey)
        #if DEBUG
        NSLog("[NotifGate] savesSinceInstall=%d", next)
        #endif
    }

    /// Mark the permission sheet as having been presented. Set whenever
    /// the sheet appears, regardless of which button the user taps.
    static func markPromptShown() {
        UserDefaults.standard.set(true, forKey: didPromptKey)
    }

    /// User tapped "Not now" — defer 30 days.
    static func defer30Days() {
        let target = Calendar.current.date(
            byAdding: .day, value: deferDays, to: Date()
        ) ?? Date()
        UserDefaults.standard.set(target, forKey: deferredKey)
        markPromptShown()
        #if DEBUG
        NSLog("[NotifGate] deferred until %@", "\(target)")
        #endif
    }

    // MARK: - Predicate

    /// Returns `true` if the permission sheet should appear right now.
    /// Reads the system authorization status async so a previously-
    /// authorized user never re-sees the sheet.
    static func shouldPresentPermissionSheet() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status: UNAuthorizationStatus = await withCheckedContinuation { cont in
            center.getNotificationSettings { cont.resume(returning: $0.authorizationStatus) }
        }
        // Already authorized or denied — system state takes precedence.
        // For .denied we route to Settings.app from the toggles, not
        // from this sheet.
        guard status == .notDetermined else { return false }

        // Save-count gate.
        guard savesSinceInstall >= savesThreshold else { return false }

        // Defer-window gate.
        if let deferred = deferredUntil, Date() < deferred {
            return false
        }
        return true
    }

    // MARK: - Debug

    #if DEBUG
    /// QA hook: reset the gate so the next save can re-trigger the
    /// sheet. Wired from the verification runbook's launch envvar in
    /// a future iteration; safe to call any time.
    static func debug_reset() {
        UserDefaults.standard.removeObject(forKey: savesKey)
        UserDefaults.standard.removeObject(forKey: deferredKey)
        UserDefaults.standard.removeObject(forKey: didPromptKey)
    }
    #endif
}
