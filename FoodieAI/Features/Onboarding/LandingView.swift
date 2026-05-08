import SwiftUI

/// Web equivalent: `pages/LandingPage/LandingPage.jsx` + `landingPage.css`.
/// Hero (~60% of height) is the bundled `LandingHero` image at JPEG 80%
/// (re-exported per DESIGN_SYSTEM.md §Asset bundling), darkened with a
/// 40% black overlay. Below the hero: wordmark, slogan, footer.
struct LandingView: View {
    /// Tapping "Try for FREE" advances OnboardingFlow into the sign-in step.
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let heroHeight = proxy.size.height * 0.60

            VStack(spacing: 0) {
                hero(height: heroHeight)
                belowHero
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.brandCream.ignoresSafeArea())
        }
    }

    private func hero(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Image("LandingHero")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
                // 40% black overlay via .multiply blend; matches the web's
                // `landing__background::before { background: rgba(0,0,0,.4) }`.
                .overlay(
                    Color.black.opacity(0.4).blendMode(.multiply)
                )

            // Wordmark anchored top-leading inside the hero
            VStack {
                HStack {
                    Text("Foodie Ai.")
                        .font(.custom(AppFont.PS.mplusMedium, size: 40))
                        .foregroundStyle(.white)
                        // Wordmark is the brand logo — cap at xLarge so AX text
                        // settings don't blow it up past the hero card edge.
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .padding(.leading, AppSpacing.lg)
                        .padding(.top, AppSpacing.md)
                    Spacer()
                }
                Spacer()
                // CTA at bottom of hero
                PillButton(title: "Try for FREE", variant: .ghost, action: onContinue)
                    .padding(.bottom, AppSpacing.xl)
            }
            .frame(height: height)
        }
        .frame(height: height)
    }

    private var belowHero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Curious about your meal? Foodie uses a little AI magic to break down what you're eating.")
                .font(.custom(AppFont.PS.mplusMedium, size: 24))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.leading)
                // Phase 8 polish: AX text-size pushes the slogan past the
                // belowHero band's fixed height. Cap dynamic-type scaling
                // to xxLarge and let the renderer downscale within that.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)

            Spacer(minLength: 0)

            Text(footerCopy)
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footerCopy: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Foodie. All rights reserved."
    }
}

#Preview("LandingView") {
    LandingView(onContinue: {})
}
