import Foundation
import Supabase

enum FoodieClient {
    static let shared: SupabaseClient = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey,
        options: SupabaseClientOptions(
            // Phase 4: opt in to the post-2.x default — emits the cached
            // local session as `.initialSession` immediately, silencing the
            // deprecation warning surfaced in Phase 1. AuthService filters
            // expired initial sessions before treating the user as signed in.
            auth: SupabaseClientOptions.AuthOptions(
                emitLocalSessionAsInitialSession: true
            )
        )
    )
}

/// Reads runtime config from Info.plist values that were substituted from
/// Secrets.xcconfig at build time. All accessors are non-fatal: if a value
/// is missing or unresolved, they log a warning and return a sentinel
/// placeholder so the app can still launch (and the bug is visible at the
/// first network call instead of a crash on init).
enum AppConfig {

    // MARK: - Public accessors

    static var supabaseURL: URL {
        let host = infoString("SUPABASE_HOST")
        guard validate(host, key: "SUPABASE_HOST") else {
            return placeholderURL("https://invalid.supabase.co")
        }
        guard let url = URL(string: "https://\(host)"), url.host != nil else {
            warn("SUPABASE_HOST malformed: '\(host)'")
            return placeholderURL("https://invalid.supabase.co")
        }
        return url
    }

    static var supabaseAnonKey: String {
        let key = infoString("SUPABASE_ANON_KEY")
        guard validate(key, key: "SUPABASE_ANON_KEY") else {
            return "MISSING_ANON_KEY"
        }
        return key
    }

    static var analyzeBaseURL: URL {
        let host = infoString("ANALYZE_HOST")
        guard validate(host, key: "ANALYZE_HOST") else {
            return placeholderURL("https://invalid.example.com")
        }
        // Localhost (and loopback) needs http; everything else gets https.
        let scheme = isLoopback(host) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)"), url.host != nil else {
            warn("ANALYZE_HOST malformed: '\(host)'")
            return placeholderURL("https://invalid.example.com")
        }
        return url
    }

    // MARK: - Helpers

    /// True iff the value is non-empty AND doesn't still contain the literal
    /// `$(...)` placeholder (which would mean xcconfig substitution didn't run).
    private static func validate(_ value: String, key: String) -> Bool {
        if value.isEmpty {
            warn("\(key) not set (empty after Info.plist substitution)")
            return false
        }
        if value.contains("$(") {
            warn("\(key) unresolved: got literal '\(value)' — xcconfig substitution didn't run")
            return false
        }
        return true
    }

    private static func infoString(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.hasPrefix("localhost") || h.hasPrefix("127.0.0.1") || h.hasPrefix("[::1]")
    }

    private static func placeholderURL(_ raw: String) -> URL {
        URL(string: raw)!
    }

    private static func warn(_ message: String) {
        print("⚠️ AppConfig: \(message)")
    }

    // MARK: - Diagnostics

    /// Prints the resolved values exactly once. Call from FoodieAIApp.init().
    static func dumpDiagnostics() {
        let url = supabaseURL
        let analyze = analyzeBaseURL
        print("=== AppConfig ===")
        print("supabaseURL:", url.absoluteString)
        print("supabaseURL.host:", url.host ?? "nil")
        print("anonKey length:", supabaseAnonKey.count)
        print("analyzeBaseURL:", analyze.absoluteString)
        print("analyzeBaseURL.host:", analyze.host ?? "nil")
        print("=================")
    }
}
