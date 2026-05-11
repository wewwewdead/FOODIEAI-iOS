import Foundation
import Supabase
import AuthenticationServices
import UIKit

/// Phase 4 auth: Google OAuth via `ASWebAuthenticationSession` + Supabase
/// SDK session storage. Sign in with Apple is intentionally not wired into
/// the UI in v1 (free personal team can't use the SIWA entitlement) but the
/// `signInWithApple(idToken:nonce:)` entry point is kept for re-enable.
@MainActor
final class AuthService: NSObject, ObservableObject {
    /// Current Supabase session, mirrored from `auth.authStateChanges`.
    @Published private(set) var session: Session?

    /// True until the first `authStateChanges` event lands. Drives the
    /// LaunchView so we don't flash Onboarding for already-signed-in users.
    @Published private(set) var isLoading: Bool = true

    /// Set when a sign-in attempt fails. Cleared at the start of each new attempt.
    @Published var lastError: AuthError?

    var isSignedIn: Bool {
        guard let session else { return false }
        // SDK's `isExpired` includes a 30s safety margin. If true, the
        // refresh task is in flight and will re-emit a fresh session shortly.
        return !session.isExpired
    }

    let client: SupabaseClient
    private var stateChangeTask: Task<Void, Never>?
    private var presentationProvider: PresentationContextProvider?
    /// Safety net for the "expired cached session" case below: if the SDK
    /// never emits a follow-up `tokenRefreshed` / `signedOut` event (no
    /// network, refresh token revoked, etc.) we flip out of the loading
    /// state after this deadline so RootView doesn't hang on LaunchView.
    private var loadingTimeoutTask: Task<Void, Never>?
    private static let loadingFallbackTimeout: UInt64 = 5_000_000_000  // 5s

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
        super.init()
    }

    /// Subscribe to auth state changes. Call once at app launch from
    /// `FoodieAIApp.body.task`. Idempotent.
    func bootstrap() async {
        if stateChangeTask != nil { return }
        stateChangeTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.client.auth.authStateChanges {
                self.apply(event: event, session: session)
            }
        }
    }

    private func apply(event: AuthChangeEvent, session newSession: Session?) {
        // Stale (expired) initial session: the SDK's `tokenRefreshed`
        // event is imminent. Stay in the loading state so RootView
        // doesn't briefly flash OnboardingFlow before the refresh lands
        // — the bug users see on cold launch.
        if event == .initialSession, let s = newSession, s.isExpired {
            self.session = nil
            scheduleLoadingTimeout()
            return
        }

        self.session = newSession
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
        if isLoading { isLoading = false }
    }

    private func scheduleLoadingTimeout() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.loadingFallbackTimeout)
            await MainActor.run {
                guard let self else { return }
                if self.isLoading { self.isLoading = false }
            }
        }
    }

    deinit {
        stateChangeTask?.cancel()
        loadingTimeoutTask?.cancel()
    }

    // MARK: - Google OAuth

    func signInWithGoogle() async throws {
        lastError = nil
        let scheme = Bundle.main.bundleIdentifier ?? "com.foodieai.FoodieAI"
        let redirect = URL(string: "\(scheme)://login-callback")!
        let oauthURL = try client.auth.getOAuthSignInURL(provider: .google, redirectTo: redirect)
        let callback: URL
        do {
            callback = try await presentWebAuth(url: oauthURL, callbackScheme: scheme)
        } catch let error as AuthError {
            // Don't surface user-cancellation as an error.
            if case .userCanceled = error { return }
            lastError = error
            throw error
        }
        try await client.auth.session(from: callback)
        // session itself is published via authStateChanges → apply(change:)
    }

    // MARK: - Apple (kept for future re-enable; see project memory)

    func signInWithApple(idToken: String, nonce: String) async throws {
        try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    // MARK: - Sign out

    func signOut() async throws {
        try await client.auth.signOut()
        // session goes nil via authStateChanges
    }

    // MARK: - ASWebAuthenticationSession bridge

    private func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            var didResume = false
            let resumeOnce: (Result<URL, Error>) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let u): cont.resume(returning: u)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            let webSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let nsErr = error as NSError
                    if nsErr.domain == ASWebAuthenticationSessionErrorDomain,
                       nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        resumeOnce(.failure(AuthError.userCanceled))
                    } else {
                        resumeOnce(.failure(AuthError.browserError(error)))
                    }
                    return
                }
                guard let callbackURL else {
                    resumeOnce(.failure(AuthError.invalidCallback))
                    return
                }
                resumeOnce(.success(callbackURL))
            }
            let provider = PresentationContextProvider()
            self.presentationProvider = provider
            webSession.presentationContextProvider = provider
            webSession.prefersEphemeralWebBrowserSession = false
            if !webSession.start() {
                resumeOnce(.failure(AuthError.invalidCallback))
            }
        }
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case invalidCallback
    case userCanceled
    case browserError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return "Sign-in was interrupted before completing."
        case .userCanceled:
            return "Sign-in was canceled."
        case .browserError(let err):
            return "Sign-in failed: \(err.localizedDescription)"
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Pick the foreground-active scene's key window; fall back to any
        // window if the key hasn't been set yet.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let key = active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
        return key ?? ASPresentationAnchor()
    }
}
