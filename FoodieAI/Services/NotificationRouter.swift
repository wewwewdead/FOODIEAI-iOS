import Foundation
import UserNotifications
import Combine

/// Phase 17. Bridges `UNUserNotificationCenter`'s tap callbacks into
/// SwiftUI state. The delegate must be a class registered with
/// `UNUserNotificationCenter.current().delegate = ...` early at app
/// launch (before any notification can fire); we set it from
/// `FoodieAIApp.init()` and observe via `NotificationRouter.shared`.
///
/// Two outputs:
///   - `requestedTab` — set when a meal-window reminder is tapped;
///     the tab host reads this and switches to Capture.
///   - `requestedRecap` — set to `true` when the recap notification
///     is tapped; the tab host opens RecapView with the latest recap.
@MainActor
final class NotificationRouter: NSObject, ObservableObject {
    static let shared = NotificationRouter()

    /// 0 = Home/Capture, 1 = Tracker, 2 = Profile. Mirrors the tag
    /// values in `MainTabView`. Default nil = no pending request.
    @Published var requestedTab: Int? = nil

    /// Set true when the recap notification is tapped. The tab host
    /// flips to Tracker, presents the recap sheet, and clears.
    @Published var requestedRecap: Bool = false

    private override init() {
        super.init()
    }

    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Consumed by the receiver after handling, so successive flips
    /// of the same value still trigger downstream `.onChange`.
    func clearTabRequest() { requestedTab = nil }
    func clearRecapRequest() { requestedRecap = false }

    /// Phase 20. Programmatic tab routing for in-app shortcuts (e.g.
    /// the "View tracker" button on the calorie-goal scan warning).
    /// Routes through the same `requestedTab` publisher the
    /// notification-tap path uses so the tab host has one source of
    /// truth.
    func requestTab(_ index: Int) {
        requestedTab = index
    }
}

extension NotificationRouter: UNUserNotificationCenterDelegate {
    /// Foreground presentation: still show the banner + sound when the
    /// app is open, so the reminder isn't silently swallowed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tap response: dispatch to the published flags above.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String

        Task { @MainActor in
            switch kind {
            case "reminder":
                // Reminder tap → Home/Capture so the user can snap.
                self.requestedTab = 0
            case "recap":
                self.requestedTab = 1
                self.requestedRecap = true
            default:
                break
            }
            completionHandler()
        }
    }
}
