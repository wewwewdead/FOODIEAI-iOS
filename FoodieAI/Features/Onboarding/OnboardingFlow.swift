import SwiftUI

/// Phase 19. The v2 onboarding flow.
///
/// Drives a single `OnboardingViewModel` through five user-visible
/// screens: hero → optional sign-in → archetype → coaches →
/// notifications, with a brief completing state before yielding to
/// `RootView` (which routes the user into MainTabView once the gate
/// has flipped).
///
/// Sign-in is treated as an interrupt rather than a separate flow: if
/// the user reaches `.signIn` and authenticates, the view model
/// auto-advances to `.archetype` (unless the user is a returning
/// account, in which case `RootView`'s gate routes around onboarding
/// and the rest of these screens are never seen).
struct OnboardingFlow: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var vm: OnboardingViewModel

    init() {
        // The view model decides its initial step lazily — see
        // `bootstrap()`. We can't read environment objects from here.
        let initial: OnboardingViewModel.Step = {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LAUNCH_SIGNIN_DIRECT"] != nil {
                return .signIn
            }
            #endif
            return .hero
        }()
        _vm = StateObject(wrappedValue: OnboardingViewModel(initialStep: initial))
    }

    var body: some View {
        ZStack {
            switch vm.step {
            case .hero:
                OnboardingHeroView(vm: vm)
                    .transition(.opacity)
            case .signIn:
                SignInView(onBack: { vm.step = .hero })
                    .transition(.opacity)
            case .archetype:
                OnboardingArchetypeView(vm: vm)
                    .transition(.opacity)
            case .physiology:
                OnboardingPhysiologyStepView(vm: vm)
                    .transition(.opacity)
            case .coaches:
                OnboardingCoachStepView(vm: vm)
                    .transition(.opacity)
            case .notifications:
                OnboardingNotificationStepView(vm: vm)
                    .transition(.opacity)
            case .completing:
                OnboardingCompletingView(vm: vm)
                    .transition(.opacity)
            case .finished:
                // Brief blank canvas — RootView will swap us out for
                // MainTabView on the next render once the profile sync
                // reflects the gate.
                Color.bgCanvas.ignoresSafeArea()
            }
        }
        .animation(.appEntrance, value: vm.step)
        .onAppear { bootstrap() }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { vm.signInDidComplete() }
        }
    }

    /// Picks the right starting step based on auth state at first
    /// render. A user who's already signed in but hasn't completed
    /// onboarding (legacy account) lands on the hero; tapping "Get
    /// started" jumps past the sign-in interrupt automatically.
    private func bootstrap() {
        // No reposition needed for fresh launches; the StateObject
        // already initialized to .hero (or .signIn under the debug
        // env var). This is a hook for future Phase 21's guest-mode
        // resumption to plug into without touching the bootstrap
        // contract here.
    }
}

#if DEBUG
#Preview("OnboardingFlow") {
    OnboardingFlow()
        .environmentObject(AuthService())
        .environmentObject(ProfileStore())
}
#endif
