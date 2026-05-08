import SwiftUI

/// Mobile-adapted version of `pages/Login/Login.jsx`. The desktop layout
/// has three benefit cards; on iPhone we collapse to a single concise
/// paragraph so it fits without scroll.
///
/// Phase 4 ships **Google OAuth only** — Sign in with Apple is gated on
/// the paid Apple Developer Program (see project memory `personal_team_no_siwa`).
struct SignInView: View {
    @EnvironmentObject private var auth: AuthService
    let onBack: () -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.brandCream.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    titleRow
                    googleButton
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
                .background(Circle().fill(Color.brandCreamSoft))
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
}

#Preview("SignInView") {
    SignInView(onBack: {})
        .environmentObject(AuthService())
}
