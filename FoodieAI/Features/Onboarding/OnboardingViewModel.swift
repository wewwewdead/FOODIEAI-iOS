import Foundation
import SwiftUI

/// Phase 19. Drives the four-screen onboarding flow.
///
/// One view model spans hero → sign-in interrupt → archetype → coaches →
/// notifications → complete. Keeping state in a single object lets the
/// user navigate back without losing answers, and lets `complete()`
/// batch every answer into one Profile UPDATE.
///
/// Lifecycle expectations:
///   - Created when `OnboardingFlow` first appears.
///   - Survives the sign-in step (since the SignInView is a child of
///     `OnboardingFlow`).
///   - Discarded after `step == .finished` triggers `RootView` to swap
///     to MainTabView.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Hashable {
        case hero          = 0
        case signIn        = 1
        case archetype     = 2
        /// Phase 20. Optional "About you" step — physiology inputs for
        /// the calorie/macro calculator. Always rendered; the user can
        /// skip it (physiology stays NULL, archetype defaults apply).
        case physiology    = 3
        case coaches       = 4
        case notifications = 5
        case completing    = 6
        /// Sentinel that tells `OnboardingFlow` it should yield — the
        /// gate values are persisted; RootView will route to MainTabView
        /// on its next render.
        case finished      = 7
    }

    @Published var step: Step {
        didSet {
            #if DEBUG
            if step != oldValue {
                NSLog("[Onboarding] step → %@", String(describing: step))
            }
            #endif
        }
    }
    @Published var archetype: Profile.Archetype? = nil

    /// Set membership for fast row rendering on the coach picker.
    @Published var preferredCoaches: Set<String> = []
    /// Persisted ordering — first-starred wins as the user's top
    /// preference. Mirrors `CoachPreferencesViewModel.orderedStarred`.
    @Published private(set) var orderedCoaches: [String] = []

    /// `nil` until the user has answered the notification screen.
    /// `true` after they tapped "Yes, send nudges" (regardless of
    /// whether the system prompt itself was granted — both resolutions
    /// answer the in-app question). `false` after "Not now".
    @Published var notificationsAccepted: Bool? = nil

    /// Phase 20. Physiology answers, populated by
    /// `OnboardingPhysiologyStepView` if the user chooses to
    /// personalize. `nil` after a skip; `complete()` then leaves the
    /// physiology columns and archetype-derived goals untouched.
    @Published var physiology: CalorieGoalCalculator.Physiology? = nil

    @Published private(set) var isCompleting: Bool = false
    @Published var completionError: String? = nil

    private let service: ProfileService

    /// UserDefaults fallback set when the network UPDATE fails during
    /// `complete()` so the user isn't trapped in onboarding. The next
    /// foreground sync retries the profile write.
    static let completedAtFallbackKey = "phase19.onboardingCompletedAtFallback"
    static let archetypeFallbackKey   = "phase19.onboardingArchetypeFallback"

    init(initialStep: Step = .hero,
         service: ProfileService = ProfileService()) {
        self.step = initialStep
        self.service = service
    }

    // MARK: - Navigation

    /// Linear advance — special-cases the sign-in step because hero
    /// chooses .signIn vs .archetype based on auth state, and the
    /// sign-in interrupt resolves itself via `signInDidComplete()`.
    func advance() {
        switch step {
        case .hero:           step = .archetype
        case .signIn:         step = .archetype
        case .archetype:      step = .physiology
        case .physiology:     step = .coaches
        case .coaches:        step = .notifications
        case .notifications:  step = .completing
        case .completing:     step = .finished
        case .finished:       break
        }
    }

    func back() {
        switch step {
        case .hero, .signIn, .completing, .finished: break
        case .archetype:      step = .hero
        case .physiology:     step = .archetype
        case .coaches:        step = .physiology
        case .notifications:  step = .coaches
        }
    }

    /// Called when the user taps "Get started" on the hero. If signed
    /// in already (e.g., a legacy account whose `onboarding_completed_at`
    /// is NULL), skip the sign-in interrupt and go straight to archetype.
    func startFromHero(isSignedIn: Bool) {
        step = isSignedIn ? .archetype : .signIn
    }

    /// Called by the OnboardingFlow when it observes `auth.isSignedIn`
    /// flip to true while we're parked at `.signIn`. Returning users
    /// (`onboarding_completed_at != nil`) are routed past onboarding
    /// by `RootView` directly; this hook only fires for fresh signups.
    func signInDidComplete() {
        guard step == .signIn else { return }
        step = .archetype
    }

    // MARK: - Selection

    func selectArchetype(_ archetype: Profile.Archetype) {
        self.archetype = archetype
    }

    /// Skip path on archetype screen — seeds `aware` (most generic
    /// defaults) so users who skip aren't penalized but also don't get
    /// macro goals tuned to a goal they haven't expressed.
    func skipArchetype() {
        if archetype == nil { archetype = .aware }
        advance()
    }

    func toggleCoach(_ name: String) {
        if preferredCoaches.contains(name) {
            preferredCoaches.remove(name)
            orderedCoaches.removeAll { $0 == name }
        } else {
            preferredCoaches.insert(name)
            orderedCoaches.append(name)
        }
    }

    // MARK: - Completion

    /// Persists every answer in one UPDATE, then optionally requests
    /// notification permission and triggers the foreground orchestrator
    /// so reminders land in the system right away.
    ///
    /// Failure handling: if the UPDATE fails, write the
    /// `onboardingCompletedAt` to UserDefaults as a fallback gate so
    /// the user isn't trapped in onboarding. The next successful
    /// `currentProfile()` will reflect the server's NULL until the next
    /// retry, but the in-memory `Profile` we apply locally will carry
    /// the values, and a follow-up foreground sync can re-attempt.
    func complete(profileStore: ProfileStore) async {
        guard !isCompleting else {
            #if DEBUG
            NSLog("[Onboarding] complete: re-entry blocked (already in flight)")
            #endif
            return
        }
        isCompleting = true
        completionError = nil
        defer { isCompleting = false }

        #if DEBUG
        NSLog("[Onboarding] complete: starting")
        #endif

        let resolvedArchetype = archetype ?? .aware
        // Phase 20: if the user filled in physiology, recompute every
        // goal field from it and persist the inputs alongside. Otherwise
        // fall back to the archetype defaults so users who skip the
        // personalization step still get sensible numbers.
        let computedGoals: CalorieGoalCalculator.Goals? = physiology.map {
            CalorieGoalCalculator.compute($0)
        }
        let archetypeDefaults = resolvedArchetype.defaultGoals
        let calorieGoal:  Int = computedGoals?.calories  ?? archetypeDefaults.calories
        let carbGoal:     Int = computedGoals?.carbsG    ?? archetypeDefaults.carbs
        let sugarGoal:    Int = computedGoals?.sugarG    ?? archetypeDefaults.sugar
        let proteinGoal:  Int? = computedGoals?.proteinG
        let fatGoal:      Int? = computedGoals?.fatG
        let fiberGoal:    Int? = computedGoals?.fiberG
        let now = Date()

        // The notification preference fields piggyback the master gate.
        // If the user hasn't been asked yet (somehow reached completion
        // without visiting the notifications step), pass nil so the
        // schema defaults / existing values stay untouched.
        let masterEnabled: Bool? = notificationsAccepted
        let mealReminders: Bool? = notificationsAccepted

        // Coaches: persist whatever the user starred, in selection order.
        // An empty array is meaningful (user explicitly skipped — the
        // rotation falls back to uniform random over the canonical pool),
        // so always send the field.
        let coachesPayload: [String]? = orderedCoaches

        do {
            let updated = try await service.completeOnboarding(
                archetype:            resolvedArchetype,
                dailyCalorieGoal:     calorieGoal,
                dailyCarbGoalG:       carbGoal,
                dailySugarGoalG:      sugarGoal,
                dailyProteinGoalG:    proteinGoal,
                dailyFatGoalG:        fatGoal,
                dailyFiberGoalG:      fiberGoal,
                preferredCoaches:     coachesPayload,
                notificationsEnabled: masterEnabled,
                reminderBreakfast:    mealReminders,
                reminderLunch:        mealReminders,
                reminderDinner:       mealReminders,
                physiology:           physiology,
                completedAt:          now
            )
            #if DEBUG
            NSLog("[Onboarding] complete: profile UPDATE finished (returned onboarding_completed_at=%@)",
                  updated.onboardingCompletedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "<nil>")
            #endif
            profileStore.apply(updated)
        } catch {
            #if DEBUG
            NSLog("[Onboarding] complete FAILED: %@", "\(error)")
            #endif
            // Fallback gate: the user moves on; a later foreground sync
            // can re-write the profile. This avoids trapping them in
            // onboarding when the network is briefly down.
            UserDefaults.standard.set(now, forKey: Self.completedAtFallbackKey)
            UserDefaults.standard.set(resolvedArchetype.rawValue,
                                      forKey: Self.archetypeFallbackKey)
            completionError = error.localizedDescription
        }

        // Notification scheduling: only when the user opted in. Permission
        // request is wrapped here so the system prompt fires in onboarding's
        // context rather than later. If the OS prompt is denied, treat it
        // as deferred — the user already answered the in-app question, and
        // we don't want to re-pester them.
        if notificationsAccepted == true {
            let granted = await NotificationScheduler.shared.requestAuthorization()
            #if DEBUG
            NSLog("[Onboarding] complete: notifications scheduled (granted=%@)",
                  granted ? "true" : "false")
            #endif
            if granted {
                await AppForegroundOrchestrator.shared
                    .runOnForeground(caller: "onboardingComplete")
            }
        } else {
            #if DEBUG
            NSLog("[Onboarding] complete: notifications skipped (user declined)")
            #endif
        }

        #if DEBUG
        NSLog("[Onboarding] complete: setting step to .finished")
        #endif
        advance() // .completing → .finished
    }

    /// Read by `RootView` to decide whether the local fallback gate
    /// should override a stale `profile.onboardingCompletedAt == nil`.
    /// This lets a user who hit a network error during `complete()`
    /// proceed to MainTabView on the same launch.
    static func hasLocalFallbackGate() -> Bool {
        UserDefaults.standard.object(forKey: completedAtFallbackKey) != nil
    }

    /// Called after the next successful profile sync confirms the
    /// server has the gate. Cleans up the local fallback so we don't
    /// leak it across accounts (sign-out + sign-in different user).
    static func clearLocalFallbackGate() {
        UserDefaults.standard.removeObject(forKey: completedAtFallbackKey)
        UserDefaults.standard.removeObject(forKey: archetypeFallbackKey)
    }
}
