import Foundation
import Supabase

/// First-party product analytics. Writes events to our own Supabase
/// `analytics_events` table (no third-party SDK — CLAUDE.md forbids third-party
/// networking libraries). Best-effort and non-blocking: a failed or
/// unauthenticated insert is swallowed so analytics can never disrupt UX.
///
/// `user_id` is filled by the DB default (`auth.uid()`) under RLS — never sent
/// from the client, mirroring the food-log insert contract. Events fired before
/// sign-in simply fail RLS and are dropped; all instrumented events are
/// post-auth anyway.
///
/// Aggregate analysis (activation, D1/D7/D30, funnel) is done from the Supabase
/// SQL editor / a service-role job — the client only inserts. `session_id` is
/// one id per app launch so sessions / DAU / retention cohorts are derivable.
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    /// Stable, well-known event names. Keep in sync with any dashboards/queries.
    enum Event {
        static let appOpened           = "app_opened"             // session / DAU / retention
        static let mealAnalyzed        = "meal_analyzed"          // activation / aha
        static let mealSaved           = "meal_saved"             // core action
        static let mealRelogged        = "meal_relogged"          // quick-log adoption
        static let onboardingCompleted = "onboarding_completed"   // scan-first activation
        static let goalsPersonalized   = "goals_personalized"     // deferred-setup recovery
        static let streakRepaired      = "streak_repaired"        // repair adoption
        static let notificationOpened  = "notification_opened"    // re-engagement effectiveness
        static let paywallViewed       = "paywall_viewed"         // monetization funnel
        static let proPurchased        = "pro_purchased"          // monetization
    }

    private let client: SupabaseClient
    /// One id per app launch — lets queries stitch events into sessions.
    private let sessionID = UUID().uuidString

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Fire-and-forget. The network insert is awaited on a detached child task
    /// so it never blocks the caller; any error is swallowed (best-effort).
    func track(_ name: String, _ props: [String: String] = [:]) {
        let event = NewAnalyticsEvent(name: name, props: props, sessionId: sessionID)
        Task { [client] in
            do {
                try await client.from("analytics_events").insert(event).execute()
            } catch {
                #if DEBUG
                NSLog("[Analytics] track '%@' failed: %@", name, "\(error)")
                #endif
            }
        }
    }
}

/// Insert shape: no `user_id` (RLS default fills it), no `occurred_at`
/// (DB default `now()`).
private struct NewAnalyticsEvent: Encodable {
    let name: String
    let props: [String: String]
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case name, props
        case sessionId = "session_id"
    }
}
