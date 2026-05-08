import SwiftUI

/// Two-step onboarding: landing page → sign-in screen. Step state is local
/// (no global router) and gated by a single `Step` enum.
struct OnboardingFlow: View {
    enum Step { case landing, signIn }

    @State private var step: Step = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LAUNCH_SIGNIN_DIRECT"] != nil {
            return .signIn
        }
        #endif
        return .landing
    }()

    var body: some View {
        switch step {
        case .landing:
            LandingView { step = .signIn }
                .transition(.opacity)
        case .signIn:
            SignInView { step = .landing }
                .transition(.opacity)
        }
    }
}

#Preview("OnboardingFlow") {
    OnboardingFlow()
        .environmentObject(AuthService())
}
