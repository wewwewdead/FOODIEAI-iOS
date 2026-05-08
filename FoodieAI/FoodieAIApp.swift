import SwiftUI
import os

@main
struct FoodieAIApp: App {
    @StateObject private var auth = AuthService()

    init() {
        // Print to stdout AND NSLog to the unified log so the diagnostic is
        // visible from Xcode console, `xcrun simctl spawn ... log stream`,
        // and Console.app — whichever you're watching.
        print("=== AppConfig ===")
        print("supabaseURL:", AppConfig.supabaseURL.absoluteString)
        print("supabaseURL.host:", AppConfig.supabaseURL.host ?? "nil")
        print("anonKey length:", AppConfig.supabaseAnonKey.count)
        print("analyzeBaseURL:", AppConfig.analyzeBaseURL.absoluteString)
        print("=================")

        NSLog("=== AppConfig ===")
        NSLog("supabaseURL: %@", AppConfig.supabaseURL.absoluteString)
        NSLog("supabaseURL.host: %@", AppConfig.supabaseURL.host ?? "nil")
        NSLog("anonKey length: %d", AppConfig.supabaseAnonKey.count)
        NSLog("analyzeBaseURL: %@", AppConfig.analyzeBaseURL.absoluteString)
        NSLog("=================")

        #if DEBUG
        FontDebug.logRegisteredFamilies()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootScene
                .preferredColorScheme(.light) // Phase 0 Q3: locked light mode for v1
                .environmentObject(auth)
                .task { await auth.bootstrap() }
        }
    }

    #if DEBUG
    /// AX5 helper: pick a target screen by name. Used by `LAUNCH_AX5=<mode>`.
    @ViewBuilder
    private func ax5View(mode: String) -> some View {
        switch mode {
        case "landing":  LandingView(onContinue: {})
        case "tracker":  TrackerView()
        case "profile":  ProfileView().environmentObject(auth)
        case "capture":  CaptureView()
        default:         CaptureView()
        }
    }
    #endif

    /// In DEBUG builds:
    ///   LAUNCH_THEME_PREVIEW=1 → ThemePreview (bypasses auth)
    ///   LAUNCH_COMPONENT_GALLERY=1 → ComponentGallery (bypasses auth)
    ///   LAUNCH_CAPTURE_DIRECT=1 → CaptureView in isolation (bypasses auth) — Phase 5 verification
    ///   otherwise → normal auth-routed UI.
    @ViewBuilder
    private var rootScene: some View {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["LAUNCH_THEME_PREVIEW"] != nil {
            ThemePreview()
        } else if env["LAUNCH_COMPONENT_GALLERY"] != nil {
            ComponentGallery()
        } else if let sample = env["LAUNCH_CAPTURE_SAMPLE"] {
            // Phase 5 verification helper: pre-populate CaptureViewModel with
            // a sample image + sample analyze response so each non-idle
            // state is screenshottable without a running Express server.
            CapturePreview.view(forSample: sample)
                .preferredColorScheme(.light)
        } else if env["LAUNCH_CAPTURE_LIVE"] != nil {
            // Phase 5 verification helper: load the bundled `LandingHero` food
            // photo into a real CaptureViewModel and trigger analyze() on
            // appear. Drives a real multipart POST to ANALYZE_BASE_URL — used
            // to capture the live network log + result screenshot without
            // needing UI taps.
            LiveAnalyzeProbeView()
                .preferredColorScheme(.light)
        } else if env["LAUNCH_CAPTURE_DIRECT"] != nil {
            CaptureView()
                .preferredColorScheme(.light)
        } else if env["LAUNCH_TRACKER_DIRECT"] != nil {
            // Phase 6 verification helper: render the Tracker tab in
            // isolation, signed in or not. The view's `.task` runs
            // `viewModel.refresh()` on appear; without an auth session,
            // the query will return zero rows or an auth error.
            TrackerView()
                .preferredColorScheme(.light)
        } else if env["LAUNCH_TRACKER_FAILED"] != nil {
            // Phase 8 verification helper: render the Tracker failed
            // state with a synthetic offline-style error so we can
            // screenshot the failed-view affordance without disabling
            // the simulator's actual networking.
            TrackerFailedSample()
                .preferredColorScheme(.light)
        } else if env["LAUNCH_PROFILE_DIRECT"] != nil {
            // Phase 7 verification helper: render the Profile tab in
            // isolation. Requires a signed-in session for the
            // `currentProfile()` SELECT to return a row.
            ProfileView()
                .environmentObject(auth)
                .preferredColorScheme(.light)
        } else if env["LAUNCH_PROFILE_UPDATE_PROBE"] != nil {
            // Phase 7 verification helper: drive a programmatic UPDATE
            // round-trip — load profile, mutate drafts, save. Used to
            // capture the live UPDATE network log + result without
            // simulator UI taps.
            ProfileUpdateProbeView()
                .environmentObject(auth)
                .preferredColorScheme(.light)
        } else if env["LAUNCH_SIGN_OUT_PROBE"] != nil {
            // Phase 7 verification helper: programmatically call
            // AuthService.signOut on appear, then render the post-state
            // (which routes through RootView → OnboardingFlow.landing
            // because session goes nil).
            SignOutProbeView()
                .environmentObject(auth)
                .preferredColorScheme(.light)
        } else if env["LAUNCH_ABOUT_SHEET"] != nil {
            // Phase 8 verification helper: present AboutSheet on a
            // brandCream background for screenshot capture.
            Color.brandCream
                .ignoresSafeArea()
                .sheet(isPresented: .constant(true)) {
                    AboutSheet()
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
                .preferredColorScheme(.light)
        } else if let mode = env["LAUNCH_AX5"] {
            // Phase 8 verification helper: render the screen named by
            // `mode` with `.dynamicTypeSize(.accessibility5)` applied to
            // the root, exercising AX text-size scaling.
            ax5View(mode: mode)
                .environment(\.dynamicTypeSize, .accessibility5)
                .preferredColorScheme(.light)
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}

/// Routes between LaunchView (initial bootstrap), OnboardingFlow
/// (unauthenticated), and MainTabView (authenticated).
struct RootView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        Group {
            if auth.isLoading {
                LaunchView()
            } else if auth.isSignedIn {
                MainTabView()
            } else {
                OnboardingFlow()
            }
        }
        // Smooth cross-fade when auth state flips, so we don't pop hard from
        // the launch screen into a tab bar.
        .animation(.easeInOut(duration: 0.25), value: auth.isLoading)
        .animation(.easeInOut(duration: 0.25), value: auth.isSignedIn)
    }
}

/// Brand-cream splash with the wordmark and a small spinner. Shown only
/// while AuthService is waiting for its first authStateChanges event.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()
            VStack(spacing: AppSpacing.lg) {
                Text("Foodie Ai.")
                    .font(.custom(AppFont.PS.mplusMedium, size: 48))
                    .foregroundStyle(Color.textPrimary)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge) // brand wordmark — capped
                ProgressView()
                    .controlSize(.regular)
                    .tint(Color.brand)
            }
        }
    }
}

/// Phase 4 placeholder. Real Home / Tracker / Profile screens land in
/// Phases 5–7. The Profile tab carries the sign-out PillButton today so
/// the auth round-trip can be exercised end-to-end.
struct MainTabView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Home", systemImage: "camera.fill") }
            TrackerView()
                .tabItem { Label("Tracker", systemImage: "list.bullet.rectangle") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}

/// Empty placeholder screen for the not-yet-built tabs.
struct PlaceholderScreen: View {
    let title: String
    let subtitle: String
    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()
            VStack(spacing: AppSpacing.sm) {
                Text(title)
                    .appFont(.displayMD)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .appFont(.meta)
                    .foregroundStyle(Color.textMeta)
            }
        }
    }
}

/// Profile tab stub for Phase 4 — exposes only the sign-out flow so we can
/// verify the auth round-trip. Phase 7 replaces this with the full screen.
struct ProfileStub: View {
    @EnvironmentObject private var auth: AuthService
    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()
            VStack(spacing: AppSpacing.xl) {
                VStack(spacing: AppSpacing.sm) {
                    Text("Profile")
                        .appFont(.displayMD)
                        .foregroundStyle(Color.textPrimary)
                    if let email = auth.session?.user.email {
                        Text(email)
                            .appFont(.body)
                            .foregroundStyle(Color.textBody)
                    }
                    Text("Phase 7")
                        .appFont(.meta)
                        .foregroundStyle(Color.textMeta)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .appFont(.meta)
                        .foregroundStyle(Color.redError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.lg)
                }

                PillButton(title: "Sign out", variant: .outline, isLoading: isSigningOut) {
                    handleSignOut()
                }
                .padding(.horizontal, AppSpacing.lg)
            }
        }
    }

    private func handleSignOut() {
        errorMessage = nil
        isSigningOut = true
        Task {
            defer { isSigningOut = false }
            do {
                try await auth.signOut()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#if DEBUG
enum FontDebug {
    static func logRegisteredFamilies() {
        // The marketed name "M PLUS Rounded 1c" doesn't match the .ttf's
        // internal Family Name, which is "Rounded Mplus 1c" (and per-weight:
        // "Rounded Mplus 1c Bold", etc.). Probe both spellings.
        let probes = ["M PLUS Rounded 1c", "Rounded Mplus 1c", "Nunito"]
        for family in probes {
            let names = UIFont.fontNames(forFamilyName: family)
            print("[FontDebug] '\(family)': \(names.isEmpty ? "(empty)" : names.joined(separator: ", "))")
        }
        // Catch-all: any registered family that starts with our prefixes.
        let related = UIFont.familyNames
            .filter { $0.lowercased().contains("mplus") || $0.lowercased().contains("rounded mplus") || $0.lowercased().contains("nunito") }
            .sorted()
        print("[FontDebug] related families: \(related.joined(separator: " | "))")
        for fam in related {
            let names = UIFont.fontNames(forFamilyName: fam).sorted()
            print("[FontDebug]   \(fam) -> \(names.joined(separator: ", "))")
        }
    }
}
#endif
