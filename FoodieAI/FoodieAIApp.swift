import SwiftUI
import UIKit
import os

@main
struct FoodieAIApp: App {
    @StateObject private var auth = AuthService()
    /// Phase 19: lifted to app-level so RootView can read
    /// `profile.onboardingCompletedAt` to gate OnboardingFlow vs
    /// MainTabView. Previously owned at MainTabView level; the move
    /// also lets the onboarding flow seed the store directly so the
    /// freshly-personalized goals don't require a re-fetch in
    /// MainTabView's first render.
    @StateObject private var profileStore = ProfileStore()

    init() {
        // Phase 17: register the UNUserNotificationCenter delegate before
        // anything can fire. Must happen synchronously at launch (Apple
        // requirement) — done here in app init.
        NotificationRouter.shared.register()

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

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            rootScene
                .preferredColorScheme(.light) // Phase 0 Q3: locked light mode for v1
                .environmentObject(auth)
                .environmentObject(profileStore)
                .environmentObject(NotificationRouter.shared)
                .task { await auth.bootstrap() }
                .onChange(of: auth.isSignedIn) { _, signedIn in
                    // Phase 17: kick the foreground orchestrator the
                    // first time we observe a signed-in user. Subsequent
                    // foregrounds are picked up by the scenePhase
                    // observer below.
                    if signedIn {
                        Task {
                            // Phase 19: load the profile so RootView can
                            // gate on `onboardingCompletedAt`. The store
                            // is idempotent — repeated calls no-op once
                            // hydrated.
                            await profileStore.loadIfNeeded()
                            await AppForegroundOrchestrator.shared
                                .runOnForeground(caller: "auth.isSignedIn→true")
                        }
                    } else {
                        // Phase 19: lifting ProfileStore to App-level
                        // means it survives sign-out. Clear it here so
                        // the next sign-in re-hydrates from the right
                        // user.
                        profileStore.clear()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, auth.isSignedIn else { return }
                    Task {
                        await AppForegroundOrchestrator.shared
                            .runOnForeground(caller: "scenePhase→active")
                    }
                }
        }
    }

    #if DEBUG
    /// AX5 helper: pick a target screen by name. Used by `LAUNCH_AX5=<mode>`.
    /// Phase 19: profileStore is already injected at the rootScene level,
    /// so probes pick it up via `@EnvironmentObject` automatically — no
    /// need for a separate debug store.
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
            Color.bgCanvas
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
/// (unauthenticated OR signed-in but onboarding incomplete), and
/// MainTabView (signed in + onboarding complete).
///
/// Phase 19 added the onboarding gate. Three signals drive routing:
///   1. `auth.isLoading` — bootstrapping, show splash.
///   2. `auth.isSignedIn` — distinguishes pre-auth from post-auth.
///   3. `profileStore.profile?.onboardingCompletedAt` — flips when the
///      user finishes onboarding (or, on a returning device, was set
///      on a previous session).
///
/// While signed in but profile not yet hydrated, we show LaunchView
/// rather than guessing — the gate would otherwise flicker between
/// onboarding and MainTabView during the initial fetch.
struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        Group {
            if auth.isLoading {
                LaunchView()
            } else if !auth.isSignedIn {
                OnboardingFlow()
            } else if let profile = profileStore.profile {
                if profile.onboardingCompletedAt != nil
                    || OnboardingViewModel.hasLocalFallbackGate() {
                    MainTabView()
                } else {
                    OnboardingFlow()
                }
            } else if profileStore.loadError != nil {
                // Profile fetch failed (e.g., offline). Don't trap the
                // user on the splash — drop them on MainTabView and let
                // the next foreground orchestrator retry. Onboarding
                // status will materialize on the retry; legacy users
                // (NULL gate) will still see onboarding next launch.
                MainTabView()
            } else {
                // Profile is loading. Stay on the splash — beats
                // flickering through OnboardingFlow for a tenth of a
                // second before switching to MainTabView.
                LaunchView()
            }
        }
        // Smooth cross-fade when auth state flips, so we don't pop hard from
        // the launch screen into a tab bar.
        .animation(.appEntrance, value: auth.isLoading)
        .animation(.appEntrance, value: auth.isSignedIn)
        .animation(.appEntrance, value: profileStore.profile?.onboardingCompletedAt)
    }
}

/// Brand-cream splash with the wordmark and a small spinner. Shown only
/// while AuthService is waiting for its first authStateChanges event.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
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

/// Three-tab host. Phase 13 customizes the tab bar appearance via
/// `UITabBarAppearance` (the UIKit appearance proxy bridges into
/// SwiftUI's `TabView`) and fires a tap haptic on selection change.
///
/// Icon choices (decisions log):
///   - Home    = `camera.fill` (kept; it's the literal action the tab
///               opens). `camera.viewfinder` was considered but reads
///               as "viewfinder UI", not "take a photo of food."
///   - Tracker = `list.bullet.rectangle` (kept; conventionally a list).
///   - Profile = `person.crop.circle` (kept; standard profile glyph).
struct MainTabView: View {
    @State private var selection: Int = 0
    /// Phase 19: ProfileStore was lifted to App-level (FoodieAIApp) so
    /// RootView can read `onboardingCompletedAt` for routing. We pull
    /// the same instance via `@EnvironmentObject`. Tracker / Profile /
    /// Capture see the same shared store as before.
    @EnvironmentObject private var profileStore: ProfileStore
    /// Phase 17: observe notification taps so we can switch tabs and
    /// open the recap on the user's behalf.
    @EnvironmentObject private var notifRouter: NotificationRouter

    init() {
        TabBarAppearance.configure()
    }

    var body: some View {
        TabView(selection: $selection) {
            CaptureView()
                .tag(0)
                .tabItem { Label("Home", systemImage: "camera.fill") }
            TrackerView()
                .tag(1)
                .tabItem { Label("Tracker", systemImage: "list.bullet.rectangle") }
            ProfileView()
                .tag(2)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        // brandDeep, not brand: SwiftUI's `.tint` cascades into system
        // controls (confirmation dialogs, alerts, default Buttons) where
        // brand (#B8CA38, lime) is too light to read on the translucent
        // material backdrop. brandDeep (#4A5713, dark olive) keeps brand
        // identity while passing WCAG AAA contrast against white.
        // The tab bar's selected color is set independently by
        // `TabBarAppearance.configure()` (UITabBarAppearance) so this
        // change doesn't dim the tab bar icons.
        .tint(Color.brandDeep)
        .task {
            // Pre-warm goals before the user navigates to Tracker, so the
            // ring/bar denominators reflect the latest profile on first paint.
            // No-op if RootView already triggered the load.
            await profileStore.loadIfNeeded()
        }
        .onChange(of: notifRouter.requestedTab) { _, requested in
            // Phase 17 — react to a reminder/recap tap by switching
            // tabs. Recap presentation is owned by the Tracker view
            // via `requestedRecap`; here we just route the tab.
            if let requested {
                selection = requested
                notifRouter.clearTabRequest()
            }
        }
        .onChange(of: selection) { _, _ in
            Haptics.tap()
        }
    }
}

/// Configures the global `UITabBar` appearance to brand colors. Called
/// once from `MainTabView.init()` so the tab bar reflects the correct
/// styling on first appearance.
///
/// `.configureWithDefaultBackground()` keeps the system blur material
/// (`.systemChromeMaterial` style under the hood), which gives the
/// translucent feel that an opaque brandCream fill wouldn't match.
private enum TabBarAppearance {
    static func configure() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()

        let brand = UIColor(Color.brand)
        let unselected = UIColor(Color.textMeta)

        for itemAppearance in [appearance.stackedLayoutAppearance,
                               appearance.inlineLayoutAppearance,
                               appearance.compactInlineLayoutAppearance] {
            itemAppearance.selected.iconColor = brand
            itemAppearance.normal.iconColor   = unselected
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: brand]
            itemAppearance.normal.titleTextAttributes   = [.foregroundColor: unselected]
        }

        UITabBar.appearance().standardAppearance   = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

/// Empty placeholder screen for the not-yet-built tabs.
struct PlaceholderScreen: View {
    let title: String
    let subtitle: String
    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
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
            Color.bgCanvas.ignoresSafeArea()
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
