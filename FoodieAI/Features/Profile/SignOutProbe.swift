#if DEBUG
import SwiftUI

/// `LAUNCH_SIGN_OUT_PROBE=1` entry point. On appear, calls
/// `AuthService.signOut()` once, then defers to `RootView` so the
/// auth-routed UI re-renders the post-sign-out state (Onboarding /
/// LandingView). Used to capture the sign-out flow without UI taps.
struct SignOutProbeView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var didTrigger = false
    @State private var signedOutAt: Date?

    var body: some View {
        ZStack {
            // Once auth flips to signed-out, RootView would naturally
            // route to Onboarding. We render it directly so the bypass
            // doesn't need to climb back through the env scope.
            RootView()
        }
        .task {
            guard !didTrigger else { return }
            didTrigger = true
            NSLog("[SignOutProbe] calling AuthService.signOut()")
            do {
                try await auth.signOut()
                signedOutAt = Date()
                NSLog("[SignOutProbe] signOut() returned cleanly; session=%@",
                      auth.session == nil ? "nil" : "still-set")
            } catch {
                NSLog("[SignOutProbe] signOut FAILED: %@", "\(error)")
            }
        }
    }
}

#endif
