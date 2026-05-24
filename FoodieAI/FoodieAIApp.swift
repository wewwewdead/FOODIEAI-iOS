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
    /// Phase 22 — StoreKit 2 manager + server-mirrored entitlement.
    /// App-scope so the count survives tab changes and a single launch
    /// bootstrap covers product loading + Transaction.updates listening
    /// for the whole session.
    @StateObject private var subscriptions = SubscriptionManager.shared

    init() {
        // Phase 17: register the UNUserNotificationCenter delegate before
        // anything can fire. Must happen synchronously at launch (Apple
        // requirement) — done here in app init.
        NotificationRouter.shared.register()

        // Config diagnostics are useful while developing (visible in Xcode
        // console, `xcrun simctl spawn ... log stream`, Console.app) but
        // include host names and the anon-key *length* — not secrets, but
        // not signal we want in shipped logs either. Gate on DEBUG.
        #if DEBUG
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
                .environmentObject(FavoritesStore.shared)
                .environmentObject(subscriptions)
                .task { await auth.bootstrap() }
                .task { await subscriptions.bootstrap() }
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
                            // Phase 22 — pull the user's tier + today's
                            // scan count from the server now that we
                            // have a JWT. Idempotent.
                            await subscriptions.refreshStatusFromServer()
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
                        // Phase 22 — re-sync entitlement on every
                        // foreground so a server-side state change
                        // (renewal, lapse, scan delta from another
                        // device) shows up before the next /analyze.
                        await subscriptions.refreshStatusFromServer()
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
    /// Minimum splash duration. Even when auth + profile resolve in a
    /// few hundred ms, we keep the launch screen up long enough for the
    /// breathing animation to play through. Without this, fast cold
    /// starts feel like a flicker.
    @State private var minSplashElapsed = false

    /// 1.8s lands between "noticeable" and "annoying" — about one and a
    /// half breath cycles of the logo animation.
    private static let minSplashDuration: UInt64 = 1_800_000_000

    var body: some View {
        Group {
            if shouldShowSplash {
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
        .task {
            try? await Task.sleep(nanoseconds: Self.minSplashDuration)
            minSplashElapsed = true
        }
        // Smooth cross-fade when auth state flips, so we don't pop hard from
        // the launch screen into a tab bar.
        .animation(.appEntrance, value: auth.isLoading)
        .animation(.appEntrance, value: auth.isSignedIn)
        .animation(.appEntrance, value: profileStore.profile?.onboardingCompletedAt)
        .animation(.appEntrance, value: minSplashElapsed)
    }

    /// Splash is visible whenever auth is still bootstrapping OR the
    /// minimum duration hasn't elapsed yet. The existing branches below
    /// still own the signed-in-but-profile-loading fallback.
    private var shouldShowSplash: Bool {
        auth.isLoading || !minSplashElapsed
    }
}

/// Brand-cream splash with the FoodieAI logo doing a three-part
/// performance: a soft brand-colored halo glow behind the mark, a
/// bouncy spring entrance, and a continuous "breath" that scales +
/// fades in lockstep. Threads/IG-style splash idiom, but tuned to
/// feel a touch more alive than a flat pulse.
///
/// Shown while AuthService is bootstrapping AND for a minimum
/// duration thereafter (see `RootView.minSplashDuration`) so even on
/// instant cold starts the animation gets to breathe.
struct LaunchView: View {
    /// Drives the entrance: scale-up from 0.5 + fade-in, controlled by
    /// a single spring so the bounce reads as the logo "landing."
    @State private var hasEntered = false
    /// Drives the continuous breath. Started shortly after the
    /// entrance settles so the two motions don't fight.
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// FoodieLogo is now a vector SVG (with Preserve Vector Data on),
    /// so scaling during the breath animation rasterizes crisply at
    /// any size — no PNG resampling artifacts.
    private static let logoSize: CGFloat = 120

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
            halo
            logoMark
        }
        .onAppear {
            withAnimation(.interpolatingSpring(stiffness: 180, damping: 14)) {
                hasEntered = true
            }
            // Reduce Motion: hold the breathing loop. The entrance still
            // fires (the logo needs to land) but we don't pulse forever.
            guard !reduceMotion else { return }
            Task {
                // Let the entrance settle (~250ms feels right with the
                // spring above) before kicking off the breathing loop.
                try? await Task.sleep(nanoseconds: 250_000_000)
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
        }
        .accessibilityLabel("Loading FoodieAI")
    }

    /// Soft brand-colored radial behind the logo. Blurred + low alpha
    /// so it reads as "glow" rather than "spotlight." Breathes a beat
    /// wider than the logo for a parallax-ish effect.
    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.brand.opacity(0.32), Color.brand.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: Self.logoSize
                )
            )
            .frame(width: Self.logoSize * 2.4, height: Self.logoSize * 2.4)
            .blur(radius: 14)
            .scaleEffect(breathing ? 1.08 : 0.9)
            .opacity(hasEntered ? (breathing ? 0.95 : 0.55) : 0)
    }

    private var logoMark: some View {
        Image("FoodieLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.logoSize, height: Self.logoSize)
            .scaleEffect(logoScale)
            .opacity(hasEntered ? 1.0 : 0.0)
    }

    /// Pre-entrance: shrunken to 0.5 so the spring has somewhere to
    /// bounce from. Post-entrance: oscillates between 0.96 and 1.04 on
    /// the breath loop.
    private var logoScale: CGFloat {
        guard hasEntered else { return 0.5 }
        return breathing ? 1.04 : 0.96
    }
}

enum AppTab: Int, CaseIterable, Hashable {
    case home = 0
    case tracker
    case mirror
    case profile

    var title: String {
        switch self {
        case .home:    return "Home"
        case .tracker: return "Tracker"
        case .mirror:  return "Mirror"
        case .profile: return "Profile"
        }
    }
}

struct PersistentTabLoadState: Equatable {
    private(set) var loadedTabs: Set<AppTab> = [.home]

    mutating func markLoaded(_ tab: AppTab) {
        loadedTabs.insert(tab)
    }

    func isLoaded(_ tab: AppTab) -> Bool {
        loadedTabs.contains(tab)
    }
}

enum RefreshReason: Equatable {
    case initialAppear
    case tabBecameActive
    case foodLogChanged
    case pullToRefresh
    case retry

    var isUserInitiated: Bool {
        switch self {
        case .pullToRefresh, .retry: return true
        case .initialAppear, .tabBecameActive, .foodLogChanged: return false
        }
    }
}

private struct ActiveTabKey: EnvironmentKey {
    static let defaultValue: AppTab = .home
}

extension EnvironmentValues {
    var activeTab: AppTab {
        get { self[ActiveTabKey.self] }
        set { self[ActiveTabKey.self] = newValue }
    }
}

enum TabPerformanceProbe {
    @MainActor
    static func tap(from old: AppTab, to new: AppTab) {
        #if DEBUG
        samples[new] = Sample(from: old, to: new, tapAt: Date())
        NSLog("[TabPerf] tap %@ -> %@", old.title, new.title)
        #endif
    }

    @MainActor
    static func selectionChanged(from old: AppTab, to new: AppTab) {
        #if DEBUG
        let now = Date()
        if samples[new] == nil {
            samples[new] = Sample(from: old, to: new, tapAt: now)
        }
        samples[new]?.selectionAt = now
        NSLog("[TabPerf] selection changed %@ -> %@ in %.0fms",
              old.title, new.title, elapsedMS(from: samples[new]?.tapAt, to: now))
        NSLog("[TabPerf] %@ visible/active", new.title)
        #endif
    }

    @MainActor
    static func appeared(_ tab: AppTab) {
        #if DEBUG
        let now = Date()
        ensureSample(for: tab, at: now)
        samples[tab]?.appearedAt = now
        NSLog("[TabPerf] %@ appeared in %.0fms",
              tab.title, elapsedMS(from: samples[tab]?.tapAt, to: now))
        #endif
    }

    @MainActor
    static func firstFrameYielded(_ tab: AppTab) {
        #if DEBUG
        let now = Date()
        ensureSample(for: tab, at: now)
        samples[tab]?.firstFrameAt = now
        NSLog("[TabPerf] %@ first frame yielded in %.0fms",
              tab.title, elapsedMS(from: samples[tab]?.tapAt, to: now))
        #endif
    }

    @MainActor
    static func refreshStarted(_ tab: AppTab) {
        #if DEBUG
        let now = Date()
        ensureSample(for: tab, at: now)
        samples[tab]?.refreshStartAt = now
        let ordering = samples[tab]?.firstFrameAt == nil ? "before first frame" : "after first frame"
        NSLog("[TabPerf] %@ refresh started %@", tab.title, ordering)
        #endif
    }

    @MainActor
    static func refreshEnded(_ tab: AppTab) {
        #if DEBUG
        let now = Date()
        guard var sample = samples[tab] else { return }
        let refreshMS = elapsedMS(from: sample.refreshStartAt, to: now)
        let totalMS = elapsedMS(from: sample.tapAt, to: now)
        sample.refreshEndAt = now
        samples[tab] = sample
        NSLog("[TabPerf] %@ refresh finished in %.0fms; tap -> refresh completed %.0fms",
              tab.title, refreshMS, totalMS)
        #endif
    }

    #if DEBUG
    private struct Sample {
        let from: AppTab
        let to: AppTab
        let tapAt: Date
        var selectionAt: Date?
        var appearedAt: Date?
        var firstFrameAt: Date?
        var refreshStartAt: Date?
        var refreshEndAt: Date?
    }

    @MainActor private static var samples: [AppTab: Sample] = [:]

    @MainActor
    private static func ensureSample(for tab: AppTab, at now: Date) {
        if samples[tab] == nil {
            samples[tab] = Sample(from: tab, to: tab, tapAt: now)
        }
    }

    private static func elapsedMS(from start: Date?, to end: Date) -> Double {
        guard let start else { return 0 }
        return end.timeIntervalSince(start) * 1000
    }
    #endif
}

/// Four-tab host. The tab roots are hosted persistently in a ZStack so
/// switching tabs only changes layer visibility instead of asking
/// SwiftUI's TabView host to swap heavyweight root views.
///
/// Icon choices (decisions log):
///   - Home    = `camera.fill` (kept; it's the literal action the tab
///               opens). `camera.viewfinder` was considered but reads
///               as "viewfinder UI", not "take a photo of food."
///   - Tracker = `list.bullet.rectangle` (kept; conventionally a list).
///   - Profile = `person.crop.circle` (kept; standard profile glyph).
struct MainTabView: View {
    @State private var selection: Int = 0
    @State private var tabLoadState = PersistentTabLoadState()
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

    /// Premium-polish wave: tab specs for the floating glass tab bar
    /// that overlays the persistent content host below.
    private var floatingTabSpecs: [FloatingTabBar.TabSpec] {
        [
            .init(title: "Home", systemImage: "camera", selectedSystemImage: "camera.fill"),
            .init(title: "Tracker", systemImage: "list.bullet.rectangle", selectedSystemImage: "list.bullet.rectangle.fill"),
            .init(title: "Mirror", systemImage: "sparkles"),
            .init(title: "Profile", systemImage: "person.crop.circle", selectedSystemImage: "person.crop.circle.fill")
        ]
    }

    private var selectedTab: AppTab {
        AppTab(rawValue: selection) ?? .home
    }

    private var selectionBinding: Binding<Int> {
        Binding(
            get: { selection },
            set: { newValue in selectTab(newValue) }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if tabLoadState.isLoaded(.home) {
                    CaptureView(isActive: selectedTab == .home)
                        .persistentTabLayer(.home, selected: selectedTab)
                        .hideSystemTabBar()
                }
                if tabLoadState.isLoaded(.tracker) {
                    TrackerView(isActive: selectedTab == .tracker)
                        .persistentTabLayer(.tracker, selected: selectedTab)
                        .hideSystemTabBar()
                }
                if tabLoadState.isLoaded(.mirror) {
                    FoodMirrorView(isActive: selectedTab == .mirror)
                        .persistentTabLayer(.mirror, selected: selectedTab)
                        .hideSystemTabBar()
                }
                if tabLoadState.isLoaded(.profile) {
                    ProfileView(isActive: selectedTab == .profile)
                        .persistentTabLayer(.profile, selected: selectedTab)
                        .hideSystemTabBar()
                }
            }
            // brandDeep, not brand: SwiftUI's `.tint` cascades into system
            // controls (confirmation dialogs, alerts, default Buttons) where
            // brand (#B8CA38, lime) is too light to read on the translucent
            // material backdrop. brandDeep (#4A5713, dark olive) keeps brand
            // identity while passing WCAG AAA contrast against white.
            // The tab bar's selected color is set independently by
            // `FloatingTabBar` itself so this change doesn't dim the tab
            // bar icons.
            .tint(Color.brandDeep)
            .animation(nil, value: selection)
            .environment(\.activeTab, selectedTab)

            // Floating glass tab bar — visual overlay only. Space
            // reservation happens per-tab inside `.hideSystemTabBar()`
            // via safeAreaInset, since `.toolbar(.hidden, for: .tabBar)`
            // doesn't reliably release the system bar's allocated space
            // when safeAreaInset is applied only at the host level.
            FloatingTabBar(
                selection: selectionBinding,
                tabs: floatingTabSpecs,
                onTabTap: { old, new in
                    guard let oldTab = AppTab(rawValue: old),
                          let newTab = AppTab(rawValue: new) else { return }
                    TabPerformanceProbe.tap(from: oldTab, to: newTab)
                }
            )
        }
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
                selectTab(requested)
                notifRouter.clearTabRequest()
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            if let oldTab = AppTab(rawValue: oldValue),
               let newTab = AppTab(rawValue: newValue) {
                TabPerformanceProbe.selectionChanged(from: oldTab, to: newTab)
            }
            Haptics.tap()
        }
    }

    private func selectTab(_ rawValue: Int) {
        guard let tab = AppTab(rawValue: rawValue) else { return }
        tabLoadState.markLoaded(tab)
        selection = rawValue
    }
}

private extension View {
    func persistentTabLayer(_ tab: AppTab, selected: AppTab) -> some View {
        let isSelected = tab == selected
        return self
            .opacity(isSelected ? 1 : 0)
            .zIndex(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
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
