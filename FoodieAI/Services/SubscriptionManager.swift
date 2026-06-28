import Foundation
import StoreKit
import Supabase
import os

/// Phase 22 — StoreKit 2 manager + server-mirrored entitlement state.
///
/// The server is the source of truth for both the daily scan count and
/// the Pro entitlement: this class only mirrors what the server reports
/// so the UI can render instantly. The mirror is refreshed from
/// `/subscription/status` on launch, after a purchase, and after every
/// /analyze success (the capture VM bumps `scansUsedToday` locally and
/// then re-syncs in the background).
///
/// We never decide locally whether the user is over the limit — the
/// server returns a structured 429 on /analyze and that's the real gate.
/// The published `dailyLimit` / `scansUsedToday` are advisory only,
/// used to render the count UI without round-tripping.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    enum Tier: String, Codable {
        case free, pro
    }

    // Product IDs configured in App Store Connect. Mirror this list when
    // you add or rename a subscription tier — the server doesn't care
    // about the IDs (it reads the JWS payload directly), but the iOS UI
    // loads its prices and period strings from these.
    static let monthlyProductID = "com.thefoodieai.pro.monthly"
    static let yearlyProductID  = "com.thefoodieai.pro.yearly"
    static let allProductIDs    = [monthlyProductID, yearlyProductID]

    // MARK: - Published state

    @Published private(set) var tier: Tier = .free
    // Optimistic fallback used only before the server's
    // `subscription/status` round-trip lands (and when offline). The
    // authoritative cap comes from `apply(statusBody:)` /
    // `applyServerLimitReached(...)`. Set to 4 to match the server's
    // FREE_FIRST_WEEK_LIMIT — new users (when first-impression matters
    // most) see the correct generous cap immediately; day-8+ users see
    // 4 for one round-trip before sync corrects to 2.
    @Published private(set) var dailyLimit: Int = 4
    @Published private(set) var scansUsedToday: Int = 0
    /// Server signal that the Pro tier is presented as "unlimited". When
    /// true, every scan-count surface hides the number and renders
    /// "Unlimited" / "Pro" instead of "X of Y" — the server still keeps a
    /// silent safety cap (`dailyLimit`) but it is never shown. Defaults
    /// to false and only flips true when the server says so, so free
    /// users (and pre-flag server responses) keep the counter UI.
    @Published private(set) var isUnlimited: Bool = false
    @Published private(set) var resetsAt: Date?
    @Published private(set) var proExpiresAt: Date?
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchasing: Bool = false
    @Published var lastPurchaseError: String?

    var scansRemainingToday: Int {
        max(0, dailyLimit - scansUsedToday)
    }

    var isOverLimit: Bool {
        scansUsedToday >= dailyLimit
    }

    // MARK: - Internal

    private let client: SupabaseClient
    private var updatesTask: Task<Void, Never>?
    private let baseURL: URL
    private let session: URLSession
    private let log = Logger(subsystem: "com.thefoodieai.foodieai", category: "subscription")

    init(client: SupabaseClient = FoodieClient.shared,
         baseURL: URL = AppConfig.analyzeBaseURL,
         session: URLSession = .shared) {
        self.client = client
        self.baseURL = baseURL
        self.session = session
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Call once on launch. Loads products from StoreKit, subscribes to
    /// `Transaction.updates`, and syncs entitlement from the server.
    func bootstrap() async {
        await loadProducts()
        if updatesTask == nil {
            updatesTask = Task.detached { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    await self.handle(update: update)
                }
            }
        }
        await refreshStatusFromServer()
    }

    /// Re-sync the entitlement mirror from the server. Safe to call on
    /// every foreground / after every /analyze response — failures are
    /// swallowed (the next call will retry).
    func refreshStatusFromServer() async {
        guard let token = await currentAccessToken() else {
            // Not signed in yet — leave the conservative defaults and
            // try again after sign-in.
            return
        }
        do {
            let body = try await getJSON(path: "subscription/status",
                                         token: token,
                                         query: ["localDate": Self.localDateString()])
            apply(statusBody: body)
        } catch {
            log.warning("status refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Optimistic increment for the post-/analyze hot path — the server
    /// already incremented its counter; this just keeps the UI snappy
    /// without waiting for a status round-trip.
    func noteSuccessfulScanLocally() {
        scansUsedToday += 1
    }

    /// When /analyze returns a structured 429, the response body carries
    /// the authoritative scansUsedToday=limit. Mirror it so the UI shows
    /// "0 left" instantly.
    func applyServerLimitReached(limit: Int, tier: Tier, resetsAt: Date?) {
        self.dailyLimit = limit
        self.tier = tier
        self.scansUsedToday = limit
        if let resetsAt { self.resetsAt = resetsAt }
    }

    // MARK: - Products

    private func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.allProductIDs)
            // Sort monthly, then yearly so the paywall layout is stable.
            self.products = loaded.sorted { lhs, rhs in
                let order = Self.allProductIDs
                let li = order.firstIndex(of: lhs.id) ?? Int.max
                let ri = order.firstIndex(of: rhs.id) ?? Int.max
                return li < ri
            }
            log.info("loaded \(self.products.count) products")
        } catch {
            log.error("product load failed: \(String(describing: error), privacy: .public)")
        }
    }

    var monthlyProduct: Product? { products.first { $0.id == Self.monthlyProductID } }
    var yearlyProduct:  Product? { products.first { $0.id == Self.yearlyProductID  } }

    // MARK: - Purchase / restore

    enum PurchaseOutcome {
        case success
        case userCancelled
        case pending
        case failed(String)
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        isPurchasing = true
        defer { isPurchasing = false }
        lastPurchaseError = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    let jws = verification.jwsRepresentation
                    let ok = await validateOnServer(jws: jws)
                    await transaction.finish()
                    if ok {
                        AnalyticsService.shared.track(
                            AnalyticsService.Event.proPurchased, ["product": product.id])
                        return .success
                    } else {
                        let msg = "Server couldn't verify the purchase. Try Restore."
                        lastPurchaseError = msg
                        return .failed(msg)
                    }
                case .unverified(_, let err):
                    let msg = "Purchase couldn't be verified: \(err.localizedDescription)"
                    lastPurchaseError = msg
                    return .failed(msg)
                }
            case .userCancelled:
                return .userCancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed("Unknown purchase result")
            }
        } catch {
            let msg = "Purchase failed: \(error.localizedDescription)"
            lastPurchaseError = msg
            return .failed(msg)
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            log.warning("AppStore.sync failed: \(String(describing: error), privacy: .public)")
        }
        // Walk currentEntitlements and revalidate any active subscription
        // with the server. App Review requires Restore to be functional
        // even after a fresh install.
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.allProductIDs.contains(transaction.productID) {
                _ = await validateOnServer(jws: result.jwsRepresentation)
                await transaction.finish()
            }
        }
        await refreshStatusFromServer()
    }

    /// Background handler for renewals / refunds / reinstall replays.
    private func handle(update: VerificationResult<Transaction>) async {
        if case .verified(let transaction) = update,
           Self.allProductIDs.contains(transaction.productID) {
            _ = await validateOnServer(jws: update.jwsRepresentation)
            await transaction.finish()
            await refreshStatusFromServer()
        }
    }

    // MARK: - Server I/O

    private func validateOnServer(jws: String) async -> Bool {
        guard let token = await currentAccessToken() else { return false }
        let payload: [String: Any] = [
            "transactionJWS": jws,
            "localDate": Self.localDateString(),
        ]
        do {
            let body = try await postJSON(path: "subscription/validate",
                                          token: token,
                                          payload: payload)
            apply(statusBody: body)
            return true
        } catch {
            log.error("validate failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func apply(statusBody body: [String: Any]) {
        if let raw = body["tier"] as? String, let t = Tier(rawValue: raw) {
            self.tier = t
        }
        if let limit = body["limit"] as? Int {
            self.dailyLimit = limit
        }
        // Pro entitlements carry `unlimited: true` so the UI hides the
        // counter. Absent (older server) → leave the conservative default
        // of false and the count UI renders normally.
        if let unlimited = body["unlimited"] as? Bool {
            self.isUnlimited = unlimited
        }
        if let used = body["scansUsedToday"] as? Int {
            self.scansUsedToday = used
        }
        if let resets = body["resetsAt"] as? String {
            self.resetsAt = Self.parseLocalWallClock(resets)
        }
        if let exp = body["proExpiresAt"] as? String {
            self.proExpiresAt = ISO8601DateFormatter().date(from: exp)
        } else {
            self.proExpiresAt = nil
        }
        log.info("entitlement: tier=\(self.tier.rawValue, privacy: .public) used=\(self.scansUsedToday)/\(self.dailyLimit)")
    }

    private func currentAccessToken() async -> String? {
        do {
            let session = try await client.auth.session
            return session.accessToken
        } catch {
            return nil
        }
    }

    private func getJSON(path: String, token: String, query: [String: String]) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "Subscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad URL for \(path)"])
        }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw NSError(domain: "Subscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad URL for \(path)"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Subscription", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "GET \(path) failed (\(status))"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json
    }

    private func postJSON(path: String, token: String, payload: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Subscription", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "POST \(path) failed (\(status))"])
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Date helpers

    /// Local YYYY-MM-DD used as the scan bucket key on the server.
    /// Uses the device's current calendar / time zone so an east-of-UTC
    /// user gets midnight in their own zone, not UTC's.
    static func localDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }

    /// Parse the server's wall-clock `resetsAt` string ("2026-05-25T00:00:00")
    /// as a Date in the device's local zone.
    static func parseLocalWallClock(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.date(from: s)
    }
}
