import SwiftUI

/// Phase 19. First screen of the v2 onboarding flow.
///
/// Three jobs:
///   1. Say what the app does in one line (microcopy decided in spec).
///   2. Hint at the celebrity-coach voice as a unique feature without
///      naming a specific coach (intentional curiosity hook).
///   3. Provide one primary CTA + a secondary "Sign in" link for
///      returning users who already have an account.
///
/// Layout uses the bundled `LandingHero` image as the visual anchor —
/// the same asset the v1 LandingView used. New tokens (Phase 14):
/// `display1` for the headline, `bodyV2` for the supporting paragraph,
/// `caption` for the secondary link.
struct OnboardingHeroView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var vm: OnboardingViewModel
    /// Shared CTA namespace from `OnboardingFlow`. When the user advances
    /// from hero → archetype the "Get started" pill matched-geometry
    /// morphs into the "Continue" pill on the next screen. Optional so
    /// previews still build with a stand-alone namespace.
    var ctaNamespace: Namespace.ID? = nil

    /// Stable id used by both this view's primary CTA and
    /// `OnboardingArchetypeView`'s Continue button. One per logical
    /// button — adding a second match here would tear the morph.
    static let ctaMatchedID = "onboardingPrimaryCTA"

    var body: some View {
        GeometryReader { proxy in
            let heroHeight = proxy.size.height * 0.45

            ScrollView {
                VStack(spacing: 0) {
                    heroImage(height: heroHeight)
                    content
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.bgCanvas.ignoresSafeArea())
        }
    }

    private func heroImage(height: CGFloat) -> some View {
        Image("LandingHero")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.25)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("Snap a meal,\nknow what's in it.")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Foodie uses AI to break down nutrition from a photo. Coached by people who knew a thing or two about life.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppSpacing.sm) {
                PrimaryButton(title: "Get started",
                              leadingSystemImage: "sparkles") {
                    vm.startFromHero(isSignedIn: auth.isSignedIn)
                }
                .matchedCTA(Self.ctaMatchedID, in: ctaNamespace)

                if !auth.isSignedIn {
                    Button {
                        Haptics.tap()
                        vm.step = .signIn
                    } label: {
                        HStack(spacing: 4) {
                            Text("Already have an account?")
                                .appFont(.caption)
                                .foregroundStyle(Color.inkLight)
                            Text("Sign in")
                                .appFont(.caption)
                                .foregroundStyle(Color.brandDeep)
                                .underline()
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Already have an account? Sign in")
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.xl2)
    }
}

// MARK: - Matched-CTA helper

/// Applies `matchedGeometryEffect` only when a namespace is provided.
/// Optional so previews and any non-flow caller can drop the
/// `ctaNamespace` arg without restructuring the call site.
extension View {
    @ViewBuilder
    func matchedCTA(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}

#if DEBUG
#Preview("Hero — pre-auth") {
    OnboardingHeroView(vm: OnboardingViewModel())
        .environmentObject(AuthService())
}
#endif
