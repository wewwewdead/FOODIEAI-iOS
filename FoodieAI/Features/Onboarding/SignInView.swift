import SwiftUI
import AuthenticationServices
import CryptoKit

/// Mobile-adapted version of `pages/Login/Login.jsx`. The desktop layout
/// has three benefit cards; on iPhone we collapse to a single concise
/// paragraph so it fits without scroll.
///
/// Ships Google OAuth + Sign in with Apple. SIWA is required by App Store
/// Review Guideline 4.8 because Google sign-in is offered.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthService
    let onBack: () -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    /// Raw nonce kept for the duration of the SIWA round-trip — Apple sees
    /// the SHA256 hash via `request.nonce`; Supabase needs the raw value to
    /// verify the identity token.
    @State private var currentNonce: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    titleRow
                    googleButton
                    appleButton
                    if let errorMessage {
                        Text(errorMessage)
                            .appFont(.meta)
                            .foregroundStyle(Color.redError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    benefitsParagraph
                    Spacer(minLength: AppSpacing.xl2)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl4)
                .padding(.bottom, AppSpacing.xl)
            }

            backButton
        }
    }

    // MARK: - Subviews

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text("Become a member!")
                .appFont(.displayMD)
                .foregroundStyle(Color.textPrimary)
            BouncingBadge(text: "free!", style: .free)
            Spacer(minLength: 0)
        }
    }

    private var googleButton: some View {
        Button(action: handleGoogleTap) {
            HStack(spacing: AppSpacing.sm) {
                if isSigningIn {
                    ProgressView().tint(Color.textPrimary)
                } else {
                    // Phase 4 deviation: SF Symbol substitute for the
                    // official Google "G" mark — the web client doesn't
                    // bundle the official asset, and re-creating it would
                    // violate Google's brand guidelines. Swap to the official
                    // PNG before pre-release.
                    Image(systemName: "globe")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Continue with Google")
                        .appFont(.pillTitle)
                        .foregroundStyle(Color.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                Capsule().fill(Color.white)
            )
            .overlay(
                Capsule().strokeBorder(Color.brand, lineWidth: 2)
            )
        }
        .disabled(isSigningIn)
        .opacity(isSigningIn ? 0.7 : 1.0)
        .accessibilityLabel("Continue with Google")
    }

    /// Apple's official `SignInWithAppleButton` — required by Guideline 4.8
    /// when third-party sign-ins are offered. Frame matches the Google
    /// button (capsule, 56pt min height, full width) for equal prominence.
    private var appleButton: some View {
        SignInWithAppleButton(
            .continue,
            onRequest: { request in
                let nonce = Self.randomNonceString()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            },
            onCompletion: { result in
                Task { await handleAppleResult(result) }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .frame(maxWidth: .infinity, minHeight: 56)
        .clipShape(Capsule())
        .disabled(isSigningIn)
        .opacity(isSigningIn ? 0.7 : 1.0)
        .accessibilityLabel("Continue with Apple")
    }

    private var benefitsParagraph: some View {
        Text("Track calories, sugar, and carbs from a single photo. Save meals to your daily log. Get insights from your AI nutrition coach.")
            .appFont(.body)
            .foregroundStyle(Color.textBody)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.bgSurfaceSoft))
        }
        .padding(.top, AppSpacing.md)
        .padding(.leading, AppSpacing.lg)
        .accessibilityLabel("Back")
    }

    // MARK: - Actions

    private func handleGoogleTap() {
        errorMessage = nil
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                try await auth.signInWithGoogle()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    @MainActor
    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                #if DEBUG
                NSLog("[SIWA] Unable to extract identity token / nonce from credential")
                #endif
                errorMessage = "Couldn't sign in with Apple. Try again."
                return
            }
            errorMessage = nil
            isSigningIn = true
            defer { isSigningIn = false; currentNonce = nil }
            do {
                try await auth.signInWithApple(idToken: identityToken, nonce: nonce)
            } catch {
                #if DEBUG
                NSLog("[SIWA] Sign-in failed: \(error)")
                #endif
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't sign in with Apple. Try again."
            }

        case .failure(let error):
            currentNonce = nil
            if let authError = error as? ASAuthorizationError,
               authError.code == .canceled {
                return
            }
            #if DEBUG
            NSLog("[SIWA] Authorization failed: \(error)")
            #endif
            errorMessage = "Couldn't sign in with Apple. Try again."
        }
    }

    // MARK: - Nonce helpers (per Apple's SIWA + Supabase guidance)

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
            for random in randoms where remaining > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

#Preview("SignInView") {
    SignInView(onBack: {})
        .environmentObject(AuthService())
}
