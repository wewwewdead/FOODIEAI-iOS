import SwiftUI
import AuthenticationServices
import CryptoKit

/// Sign-in surface. Three vertical zones: wordmark + hero copy, the two
/// provider buttons, and reassurance microcopy with legal links.
///
/// Ships Google OAuth + Sign in with Apple. SIWA is required by App Store
/// Review Guideline 4.8 because Google sign-in is offered. Legal links are
/// required on or accessible from the sign-in screen.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    /// Raw nonce kept for the duration of the SIWA round-trip — Apple sees
    /// the SHA256 hash via `request.nonce`; Supabase needs the raw value to
    /// verify the identity token.
    @State private var currentNonce: String?

    private static let termsURL   = URL(string: "https://thefoodieai.com/terms")!
    private static let privacyURL = URL(string: "https://thefoodieai.com/privacy")!

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer().frame(height: geo.size.height * 0.08)
                heroZone
                Spacer().frame(height: AppSpacing.xl2)
                buttonsZone
                Spacer(minLength: AppSpacing.xl)
                reassuranceZone
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.bgCanvas.ignoresSafeArea())
    }

    // MARK: - Zones

    private var heroZone: some View {
        VStack(spacing: AppSpacing.xl) {
            Text("foodie.")
                .appFont(.display1)
                .foregroundStyle(Color.brand)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: AppSpacing.md) {
                HStack(spacing: AppSpacing.sm) {
                    Text("Welcome")
                        .appFont(.display2)
                        .foregroundStyle(Color.ink)
                    BouncingBadge(text: "free!", style: .free)
                }

                Text("Track meals from a photo.\nGet coached by people who knew a thing or two about life.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.lg)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var buttonsZone: some View {
        VStack(spacing: AppSpacing.md) {
            if let errorMessage {
                Text(errorMessage)
                    .appFont(.caption)
                    .foregroundStyle(Color.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            googleButton
            appleButton
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    private var reassuranceZone: some View {
        VStack(spacing: AppSpacing.sm) {
            Text("Free to start. Always private.")
                .appFont(.captionStrong)
                .foregroundStyle(Color.inkMute)

            legalLinks
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.xl)
    }

    // MARK: - Buttons

    private var googleButton: some View {
        Button(action: handleGoogleTap) {
            HStack(spacing: AppSpacing.sm) {
                if isSigningIn {
                    // Brand mark IS the loader (Threads pattern):
                    // continuous rotation + soft breath pulse stands
                    // in for the generic system ProgressView.
                    FoodieLogoLoader(size: 28)
                    Text("Signing in…")
                        .appFont(.pillTitle)
                        .foregroundStyle(Color.ink)
                } else {
                    Image("google_g")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                    Text("Continue with Google")
                        .appFont(.pillTitle)
                        .foregroundStyle(Color.ink)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(Color.white))
            .overlay(
                Capsule().strokeBorder(Color.brand.opacity(0.4), lineWidth: 1.5)
            )
            .appShadow(.card)
        }
        .disabled(isSigningIn)
        .opacity(isSigningIn ? 0.85 : 1.0)
        .accessibilityLabel(isSigningIn ? "Signing in" : "Continue with Google")
    }

    /// Apple's official `SignInWithAppleButton` — required by Guideline 4.8
    /// when third-party sign-ins are offered. Stays stock per Apple HIG.
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
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .clipShape(Capsule())
        .disabled(isSigningIn)
        .opacity(isSigningIn ? 0.7 : 1.0)
        .accessibilityLabel("Continue with Apple")
    }

    // MARK: - Legal links

    private var legalLinks: some View {
        HStack(spacing: 4) {
            Text("By continuing, you agree to our")
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
            Link("Terms", destination: Self.termsURL)
                .font(AppFont.font(.caption))
                .foregroundStyle(Color.brandDeep)
            Text("and")
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
            Link("Privacy", destination: Self.privacyURL)
                .font(AppFont.font(.caption))
                .foregroundStyle(Color.brandDeep)
        }
        .multilineTextAlignment(.center)
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
    SignInView()
        .environmentObject(AuthService())
}

// MARK: - Brand-mark loader

/// Threads-style auth loader. While the OAuth round-trip is in
/// flight, the FoodieAI brand mark replaces the system spinner:
///   - A slow, continuous rotation reads as "still working."
///   - A soft 0.94 ↔ 1.06 breath pulse keeps the mark feeling
///     alive instead of robotic.
/// Reduce Motion drops the rotation and shrinks the pulse so the
/// element still registers without inducing motion sickness.
private struct FoodieLogoLoader: View {
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0
    @State private var breathing: Bool = false

    var body: some View {
        Image("FoodieLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(breathing ? 1.06 : 0.94)
            .accessibilityHidden(true)
            .onAppear { startAnimating() }
    }

    private func startAnimating() {
        if reduceMotion {
            // Calm fallback: gentle breath only, no spin.
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
            return
        }
        // 1.4s linear full revolution. Linear (not easeInOut) so the
        // rotation looks like a steady spinner and not a "swing."
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            rotation = 360
        }
        // 0.9s breath, autoreverses — slightly faster than the spin
        // so the two cycles drift in and out of phase, avoiding a
        // lock-step "metronome" feel.
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}
