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
        // Raw values 4 (coaches) and 5 (notifications) retired 2026-07 — those
        // steps were unreachable in the live flow. Gap left intentionally; no
        // code reconstructs Step from a raw value.
        /// Phase 22 — informational comparison of Free vs Pro. Always
        /// rendered; both CTAs advance to `.completing` so onboarding
        /// is never blocked by a purchase decision. Tapping "Try Pro"
        /// presents the existing `PaywallView` sheet; the user can
        /// buy or dismiss either way and we still proceed.
        case subscription  = 6
        case completing    = 7
        /// Sentinel that tells `OnboardingFlow` it should yield — the
        /// gate values are persisted; RootView will route to MainTabView
        /// on its next render.
        case finished      = 8
        /// Phase 23. Empathy/commitment step ("what's slowed you down
        /// before?"). Logically sits between the goal (archetype) and
        /// physiology in the live flow — see `advance()`. New rawValue
        /// appended so the existing ones are undisturbed; flow is
        /// switch-driven, not rawValue-ordered.
        case barriers      = 9
    }

    @Published var step: Step {
        didSet {
            guard step != oldValue else { return }
            recordReached(step)
            #if DEBUG
            NSLog("[Onboarding] step → %@", String(describing: step))
            #endif
        }
    }

    /// Local funnel buffer — the ordered, de-duplicated steps reached this run.
    /// Flushed to analytics only AFTER auth (analytics_events is auth-scoped):
    /// once when sign-in completes (`onboarding_signed_in`, path-so-far) and
    /// again with the full path at completion (`onboarding_completed`). The
    /// delta between the two = users who signed in but bailed at the paywall.
    /// Pre-auth droppers aren't attributable without anonymous analytics
    /// (deferred by design — see the low-egress tradeoff).
    @Published private(set) var reachedSteps: [String] = []

    private func recordReached(_ step: Step) {
        let key = String(describing: step)
        if reachedSteps.last != key, !reachedSteps.contains(key) {
            reachedSteps.append(key)
        }
    }
    @Published var archetype: Profile.Archetype? = nil

    /// Phase 23. Empathy/commitment answers — the obstacles the user has hit
    /// before ("late-night snacking", "eating out", …). Raw keys from
    /// `OnboardingBarriersStepView`. Kept in session and reported in the
    /// completion analytics (count only); not persisted to the profile (no
    /// migration this phase). Empty = skipped.
    @Published var barriers: Set<String> = []

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

    /// Phase 23. Optional target weight (kg) captured alongside physiology
    /// for lose/gain goals. Drives ONLY the onboarding plan-reveal
    /// projection chart — a one-time motivational moment — so it's kept in
    /// session and not persisted in this phase (no migration). `nil` for
    /// maintain/curious goals or when the user leaves it blank.
    @Published var targetWeightKg: Double? = nil

    /// Set true when the plan-reveal (physiology preview) is shown. Because
    /// sign-in now comes AFTER the reveal, we can't write an analytics row at
    /// reveal time (no `auth.uid()` yet → RLS rejects it). Instead we stash the
    /// flag and report it in the first post-auth event (`onboarding_signed_in`).
    @Published var didRevealPlan: Bool = false

    @Published private(set) var isCompleting: Bool = false
    @Published var completionError: String? = nil

    private let service: ProfileService

    /// UserDefaults fallback set when the network UPDATE fails during
    /// `complete()` so the user isn't trapped in onboarding. The next
    /// foreground sync retries the profile write.
    static let completedAtFallbackKey = "phase19.onboardingCompletedAtFallback"
    static let archetypeFallbackKey   = "phase19.onboardingArchetypeFallback"

    init(initialStep: Step = .hero,
         service: ProfileService = ProfileService.shared) {
        self.step = initialStep
        self.service = service
        // Seed the funnel (init assignment doesn't trigger `step.didSet`).
        self.reachedSteps = [String(describing: initialStep)]
    }

    // MARK: - Navigation

    /// Linear advance — special-cases the sign-in step because hero
    /// chooses .signIn vs .archetype based on auth state, and the
    /// sign-in interrupt resolves itself via `signInDidComplete()`.
    func advance() {
        switch step {
        case .hero:           step = .archetype
        // Sign-in moved to the END (Phase 23): the user completes the quiz and
        // sees their personalized plan BEFORE the sign-in wall, then signs in
        // and hits the offer. Advancing from .signIn lands on the paywall
        // (normally reached via signInDidComplete once auth flips).
        case .signIn:         step = .subscription
        case .archetype:      step = .barriers
        case .barriers:       step = .physiology
        // Phase 23. Plan reveal (physiology) → sign-in → the (previously
        // orphaned) subscription offer → completing. Showing the aha before
        // asking to sign in is the core conversion move; the offer follows
        // sign-in so a purchase has an auth token to validate against.
        case .physiology:     step = .signIn
        case .subscription:   step = .completing
        case .completing:     step = .finished
        case .finished:       break
        }
    }

    func back() {
        switch step {
        case .hero, .signIn, .completing, .finished: break
        case .archetype:      step = .hero
        case .barriers:       step = .archetype
        case .physiology:     step = .barriers
        // Mirrors the advance() reroute: the offer now follows physiology.
        case .subscription:   step = .physiology
        }
    }

    /// "Get started" on the hero. Phase 23: the quiz comes first for everyone —
    /// goal → physiology → plan reveal — and sign-in is deferred to the end, so
    /// the user experiences value before the sign-in wall. `isSignedIn` is
    /// retained for the call site but no longer branches (a legacy signed-in
    /// account simply auto-skips the later sign-in step).
    func startFromHero(isSignedIn: Bool) {
        step = .archetype
    }

    /// Reset to a clean first-run state. Called by `RootView` on sign-out so a
    /// new account starts onboarding from the hero rather than inheriting the
    /// previous user's answers (the model is now owned by RootView and
    /// persists across sign-in/out).
    func reset() {
        step = .hero
        archetype = nil
        barriers = []
        physiology = nil
        targetWeightKg = nil
        didRevealPlan = false
        preferredCoaches = []
        orderedCoaches = []
        notificationsAccepted = nil
        completionError = nil
        reachedSteps = [String(describing: Step.hero)]
    }

    /// Continue from the goal screen. Phase 23: the empathy/commitment
    /// (barriers) step comes next, then physiology. `isSignedIn` is unused
    /// here (kept for the call site; sign-in is deferred to the end).
    func continueFromGoal(isSignedIn: Bool) {
        step = .barriers
    }

    /// Called by `OnboardingFlow` when `auth.isSignedIn` flips to true (or on a
    /// remount) while parked at `.signIn`. Phase 23: sign-in is now the LAST
    /// interactive step (after the plan reveal), so completing it leads into
    /// the subscription offer, then completion. Returning accounts
    /// (`onboarding_completed_at != nil`) are routed past onboarding by
    /// `RootView` and never reach here.
    func signInDidComplete() {
        guard step == .signIn else { return }
        // First moment we can attribute the funnel to a user — flush the
        // path so far. Completers also emit `onboarding_completed`; the gap
        // between the two is the paywall drop-off.
        AnalyticsService.shared.track(
            AnalyticsService.Event.onboardingSignedIn,
            ["path": reachedSteps.joined(separator: ">"),
             "personalized": physiology != nil ? "true" : "false",
             "plan_revealed": didRevealPlan ? "true" : "false"])
        step = .subscription
    }

    // MARK: - Selection

    func selectArchetype(_ archetype: Profile.Archetype) {
        self.archetype = archetype
    }

    /// Skip path on archetype screen — seeds `aware` (most generic
    /// defaults) so users who skip aren't penalized but also don't get
    /// macro goals tuned to a goal they haven't expressed.
    func skipArchetype(isSignedIn: Bool) {
        if archetype == nil { archetype = .aware }
        continueFromGoal(isSignedIn: isSignedIn)
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
        // Map the up-front goal commitment to a weight-goal direction so the
        // loop features (step goal, burn-off, eat-to-goal framing) are
        // personalized from day one — even before full physiology. A completed
        // physiology step wins when present.
        let goalDirection: CalorieGoalCalculator.GoalDirection? = physiology?.goal ?? {
            switch resolvedArchetype {
            case .loseWeight:  return .lose
            case .buildMuscle: return .gain
            case .aware:       return .maintain
            case .curious:     return nil
            }
        }()
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
                weightGoalDirection:  goalDirection,
                completedAt:          now
            )
            #if DEBUG
            NSLog("[Onboarding] complete: profile UPDATE finished (returned onboarding_completed_at=%@)",
                  updated.onboardingCompletedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "<nil>")
            #endif
            profileStore.apply(updated)
            // Scan-first activation: `personalized=false` is the common path now
            // (survey deferred); a later goals_personalized event closes the loop.
            AnalyticsService.shared.track(
                AnalyticsService.Event.onboardingCompleted,
                ["personalized": physiology != nil ? "true" : "false",
                 "barriers": "\(barriers.count)",
                 "path": reachedSteps.joined(separator: ">")])
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
