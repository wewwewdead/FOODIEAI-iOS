import Foundation
import Supabase
import AdServices

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
        static let onboardingSignedIn  = "onboarding_signed_in"   // funnel: reached sign-in (quiz done)
        static let goalsPersonalized   = "goals_personalized"     // deferred-setup recovery
        static let streakRepaired      = "streak_repaired"        // repair adoption
        static let notificationOpened  = "notification_opened"    // re-engagement effectiveness
        static let paywallViewed       = "paywall_viewed"         // monetization funnel
        static let checkoutStarted     = "checkout_started"       // funnel: tapped the buy CTA
        static let checkoutAbandoned   = "checkout_abandoned"     // funnel: cancelled the StoreKit sheet
        static let checkoutPending     = "checkout_pending"       // funnel: Ask-to-Buy / SCA hold
        static let checkoutFailed      = "checkout_failed"        // funnel: StoreKit purchase error
        static let validationFailed    = "trial_validation_failed"// funnel: paid but server rejected the receipt
        static let trialStarted        = "trial_started"          // monetization (free-trial start)
        static let proPurchased        = "pro_purchased"          // monetization
    }

    private let client: SupabaseClient
    /// One id per app launch — lets queries stitch events into sessions.
    private let sessionID = UUID().uuidString
    /// Properties merged into EVERY tracked event. Set once per launch by
    /// `SearchAdsAttribution` so monetization events (`trialStarted`,
    /// `proPurchased`) carry the Apple Search Ads campaign/keyword that drove
    /// the install — letting you rank keywords by cost-per-paying-user, not just
    /// cost-per-install. Explicit per-call props win on a key collision.
    private var superProps: [String: String] = [:]

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Register persistent properties attached to all subsequent events. Merged
    /// into every `track` call; later registrations overwrite earlier keys.
    func register(superProperties props: [String: String]) {
        superProps.merge(props) { _, new in new }
    }

    /// Fire-and-forget. The network insert is awaited on a detached child task
    /// so it never blocks the caller; any error is swallowed (best-effort).
    func track(_ name: String, _ props: [String: String] = [:]) {
        let merged = superProps.merging(props) { _, explicit in explicit }
        let event = NewAnalyticsEvent(name: name, props: merged, sessionId: sessionID)
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

// MARK: - Apple Search Ads attribution

/// Resolves which Apple Search Ads campaign / ad group / keyword drove THIS
/// install (via Apple's first-party AdServices API) and registers the result as
/// analytics super-properties. First-party attribution needs NO App Tracking
/// Transparency prompt and NO entitlement. Best-effort throughout: any failure
/// is swallowed and simply leaves events unattributed.
///
/// Why it matters: without this, Search Ads can only be optimized to installs.
/// With the campaign/keyword stamped on `trial_started` / `pro_purchased`, you
/// can rank keywords by cost per PAYING user and cut the ones that install but
/// never subscribe.
enum SearchAdsAttribution {
    private static let attemptedKey = "foodie.asa.attribution.attempted.v1"
    private static let propsKey     = "foodie.asa.attribution.props.v1"
    private static let endpoint     = URL(string: "https://api-adservices.apple.com/api/v1/")!

    /// Call once early each launch. Re-applies any previously resolved
    /// attribution to this session's analytics, and — only if we've never
    /// resolved before — fetches it from Apple once.
    static func syncOnLaunch(defaults: UserDefaults = .standard) async {
        // 1. Re-apply resolved attribution to THIS launch, so events fired later
        //    in the session (trial/purchase) carry it. Super-props are in-memory
        //    and reset each launch, so this must run every time — not just on the
        //    launch we first resolved.
        if let saved = loadProps(defaults: defaults), !saved.isEmpty {
            await MainActor.run { AnalyticsService.shared.register(superProperties: saved) }
        }

        // 2. Fetch from Apple exactly once — an install's token→campaign mapping
        //    never changes, so there's nothing to refresh.
        guard !defaults.bool(forKey: attemptedKey) else { return }
        guard let token = try? AAAttribution.attributionToken(),
              let data = await fetch(token: token),
              let record = try? JSONDecoder().decode(AppleAdsAttribution.self, from: data)
        else { return }  // transient (e.g. token not ready yet) — retry next launch

        defaults.set(true, forKey: attemptedKey)   // Apple answered; don't refetch
        let props = record.analyticsProps
        saveProps(props, defaults: defaults)
        await MainActor.run {
            AnalyticsService.shared.register(superProperties: props)
            AnalyticsService.shared.track("attribution_resolved", props)
        }
    }

    /// POST the token to Apple. Returns the JSON body on HTTP 200. Apple answers
    /// 404 while the token isn't ready yet, so retry a few times with a backoff.
    private static func fetch(token: String, attempts: Int = 3) async -> Data? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)
        for attempt in 0..<attempts {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return data
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000) // 2s, 4s
            }
        }
        return nil
    }

    private static func loadProps(defaults: UserDefaults) -> [String: String]? {
        guard let data = defaults.data(forKey: propsKey) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func saveProps(_ props: [String: String], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(props) else { return }
        defaults.set(data, forKey: propsKey)
    }
}

/// Apple Ads Attribution API response. All fields optional: an organic install
/// returns `attribution == false` with the ad fields absent.
private struct AppleAdsAttribution: Decodable {
    let attribution: Bool?
    let campaignId: Int?
    let adGroupId: Int?
    let keywordId: Int?
    let adId: Int?
    let conversionType: String?
    let countryOrRegion: String?

    /// Flattened to `[String: String]` for the analytics `props` JSON column.
    /// `asa_keyword_id` is the number you cross-reference in the Search Ads
    /// dashboard to see which keyword produced a paying user.
    var analyticsProps: [String: String] {
        var p: [String: String] = ["asa_attributed": (attribution == true) ? "true" : "false"]
        if let campaignId     { p["asa_campaign_id"]     = String(campaignId) }
        if let adGroupId      { p["asa_adgroup_id"]      = String(adGroupId) }
        if let keywordId      { p["asa_keyword_id"]      = String(keywordId) }
        if let adId           { p["asa_ad_id"]           = String(adId) }
        if let conversionType { p["asa_conversion_type"] = conversionType }
        if let countryOrRegion { p["asa_country"]        = countryOrRegion }
        return p
    }
}
