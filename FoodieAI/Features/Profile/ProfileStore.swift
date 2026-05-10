import Foundation
import Combine

/// Shared, observable source of truth for the signed-in user's `Profile`.
///
/// Created once at the `MainTabView` level and injected via
/// `@EnvironmentObject`, so any feature that needs the user's daily goals
/// (currently TodayView; Week/Month soon) can subscribe to the same
/// `Profile` instance Profile.swift's editor mutates. Without this, each
/// screen would own its own copy and goal changes wouldn't propagate.
///
/// `ProfileViewModel` calls `apply(_:)` after every successful load/save,
/// which republishes to all observers — so when the user changes a
/// stepper on Profile and taps Save, the Tracker progress ring/bars
/// recompute their denominators on the next render.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadError: Error?

    private let service: ProfileService
    private var didStartInitialLoad = false

    init(service: ProfileService = ProfileService()) {
        self.service = service
    }

    /// First-launch hydration. Idempotent: repeated calls (e.g., from
    /// `.task` in MainTabView) won't re-fetch once a profile is loaded.
    func loadIfNeeded() async {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true
        await refresh()
    }

    func refresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await service.currentProfile()
            profile = fetched
            #if DEBUG
            NSLog("[ProfileStore] refresh: onboardingCompletedAt=%@",
                  fetched.onboardingCompletedAt
                      .map { ISO8601DateFormatter().string(from: $0) } ?? "nil")
            #endif
        } catch {
            loadError = error
            #if DEBUG
            NSLog("[ProfileStore] refresh FAILED: %@", "\(error)")
            #endif
        }
    }

    /// Push an updated profile from another owner (e.g. ProfileViewModel
    /// after a successful UPDATE). All subscribers re-render.
    func apply(_ profile: Profile) {
        self.profile = profile
        #if DEBUG
        NSLog("[ProfileStore] apply: onboardingCompletedAt=%@",
              profile.onboardingCompletedAt
                  .map { ISO8601DateFormatter().string(from: $0) } ?? "nil")
        #endif
    }

    func clear() {
        profile = nil
        didStartInitialLoad = false
        loadError = nil
    }

    // MARK: - Goal accessors (with design-system fallbacks)
    //
    // Fallbacks match the column defaults in
    // migrations/003_profiles_macro_goals.sql, so the UI denominators
    // line up with what a freshly-defaulted profile would persist.

    var calorieGoal: Double { Double(profile?.dailyCalorieGoal   ?? 2_000) }
    var carbGoal:    Double { Double(profile?.dailyCarbGoalG     ?? 250) }
    var sugarGoal:   Double { Double(profile?.dailySugarGoalG    ?? 50) }
    var proteinGoal: Double { Double(profile?.dailyProteinGoalG  ?? 90) }
    var fatGoal:     Double { Double(profile?.dailyFatGoalG      ?? 70) }
    var fiberGoal:   Double { Double(profile?.dailyFiberGoalG    ?? 28) }
}
