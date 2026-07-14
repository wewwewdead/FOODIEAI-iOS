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
    /// Owned by `RootView` (not a local `@StateObject`) so the model — and the
    /// user's goal + physiology answers — survives `RootView` swapping this
    /// flow out and back in when `auth.isSignedIn` flips mid-onboarding.
    /// Otherwise a fresh instance would reset the flow to the very start.
    @ObservedObject var vm: OnboardingViewModel
    /// Shared namespace so the primary CTA can morph (matched geometry)
    /// between hero ("Get started") and archetype ("Continue"). One id
    /// per logical button is enough — see `OnboardingHeroView.ctaMatchedID`.
    @Namespace private var ctaNamespace

    var body: some View {
        ZStack {
            switch vm.step {
            case .hero:
                OnboardingHeroView(vm: vm, ctaNamespace: ctaNamespace)
                    // Outgoing hero fades a touch faster than the
                    // incoming archetype fades in. Letting the morphing
                    // CTA stay opaque a beat longer than its surrounding
                    // content reads as the pill "flying" between screens.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
            case .signIn:
                // Reached via the quiz (goal picked) → "save your plan";
                // reached via the hero's "Already have an account?" shortcut
                // (no goal yet) → "welcome / returning".
                SignInView(context: vm.archetype != nil ? .savePlan : .returning)
                    .transition(.opacity)
            case .archetype:
                OnboardingArchetypeView(vm: vm, ctaNamespace: ctaNamespace,
                                        isSignedIn: auth.isSignedIn)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
            case .barriers:
                OnboardingBarriersStepView(vm: vm, ctaNamespace: ctaNamespace)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
            case .physiology:
                OnboardingPhysiologyStepView(vm: vm, ctaNamespace: ctaNamespace)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
            case .subscription:
                // Phase 24 — the offer step IS the real paywall now: prices,
                // trial timeline, plan selector and buy CTA are visible with no
                // extra tap (the old comparison screen hid all of that behind a
                // "Try Pro" tap only ~29% took). A completed purchase, the close
                // control, and the secondary "Continue with Free" all call
                // `onFinish` to advance, so it still never hard-blocks. Rendered
                // inline (not a sheet) so it inherits the environment, and
                // `analyticsContext:"onboarding"` keeps this paywall_viewed
                // separable from in-app upsells.
                PaywallView(onFinish: { vm.advance() },
                            analyticsContext: "onboarding",
                            planCallback: planCallback)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
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
        // `.appMorph` is the fluid-spring curve specifically tuned for
        // cross-screen `matchedGeometryEffect` traversals (slightly slower
        // than `.appEntrance`, near-critically damped — see AppAnimation).
        .animation(.appMorph, value: vm.step)
        .onAppear {
            bootstrap()
            // If we (re)mounted already signed in but parked at the sign-in
            // interrupt — e.g. RootView swapped the flow out during the brief
            // post-sign-in profile load — advance past it instead of stalling.
            if vm.step == .signIn && auth.isSignedIn { vm.signInDidComplete() }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { vm.signInDidComplete() }
        }
        .onChange(of: vm.step) { _, step in
            // Legacy already-signed-in account reaching the sign-in interrupt
            // (after the goal + physiology steps) — skip straight past it to
            // completion, since `auth.isSignedIn` won't change to re-trigger
            // the handler above.
            if step == .signIn && auth.isSignedIn { vm.signInDidComplete() }
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

    // MARK: - Plan callback

    /// Carries the plan the user just saw on the reveal into the paywall header
    /// so the offer reads as the next step toward THEIR goal. Prefers the
    /// weight projection (goal + a concrete date, the strongest hook); falls
    /// back to the daily calorie target; nil when physiology was skipped, in
    /// which case the paywall keeps its generic header. Unit-agnostic on
    /// purpose (no kg/lb) since the display unit isn't carried out of the form.
    private var planCallback: String? {
        guard let phys = vm.physiology else { return nil }
        if let target = vm.targetWeightKg,
           let proj = CalorieGoalCalculator.projectWeight(
                currentKg: phys.weightKg, targetKg: target, goal: phys.goal) {
            return "On track to hit your goal weight by \(Self.monthYear.string(from: proj.goalDate))"
        }
        return "Your plan is set: \(CalorieGoalCalculator.compute(phys).calories) calories a day"
    }

    private static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}

// MARK: - Subscription offer step
//
// Phase 24 — the onboarding offer step is now `PaywallView` itself, rendered
// inline with `onFinish: { vm.advance() }` (see the `.subscription` case in
// `OnboardingFlow.body`). The old soft Free-vs-Pro comparison screen
// (`OnboardingSubscriptionStepView`) that hid prices behind an extra "Try Pro"
// tap has been removed: only ~29% of completers took that tap, so the real
// paywall now shows to everyone who reaches the step.

// MARK: - Barriers (empathy / commitment) step

/// Phase 23. A low-friction, multi-select "what's gotten in the way before?"
/// step between the goal and physiology. It's a commitment device: naming the
/// obstacles deepens investment and makes the coming plan feel personal, while
/// staying kind (skippable, "no judgment"). Selections live in the view model
/// (session-only) and are reported as a count in the completion analytics.
///
/// Inline in OnboardingFlow.swift (not its own file) to avoid a pbxproj add,
/// the manual-file-management convention this project uses (see project memory).
private struct OnboardingBarriersStepView: View {
    @ObservedObject var vm: OnboardingViewModel
    var ctaNamespace: Namespace.ID? = nil

    private struct Option: Identifiable {
        let id: String
        let label: String
        let icon: String
    }

    private static let options: [Option] = [
        .init(id: "evening_drift",   label: "Losing track by the evening", icon: "moon.stars"),
        .init(id: "late_snacking",   label: "Late-night snacking",         icon: "fork.knife"),
        .init(id: "eating_out",      label: "Eating out or takeout",       icon: "takeoutbag.and.cup.and.straw"),
        .init(id: "portions",        label: "Portion sizes",               icon: "circle.grid.2x2"),
        .init(id: "stress_eating",   label: "Stress or emotional eating",  icon: "heart"),
        .init(id: "slip_ups",        label: "Giving up after a slip",      icon: "arrow.uturn.down"),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    Text("What's gotten in the way before?")
                        .appFont(.display1)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AppSpacing.xl3)
                    Text("Pick any that feel familiar, we'll keep them in mind. No judgment.")
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: AppSpacing.xs) {
                        ForEach(Self.options) { option in
                            row(option)
                        }
                    }

                    Spacer(minLength: AppSpacing.lg)

                    PrimaryButton(title: vm.barriers.isEmpty ? "Skip" : "Continue") {
                        Haptics.tap()
                        vm.advance()
                    }
                    .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            BackChevron(action: { Haptics.tap(); vm.back() })
        }
        .animation(.appReveal, value: vm.barriers)
    }

    private func row(_ option: Option) -> some View {
        let isSelected = vm.barriers.contains(option.id)
        return Button {
            Haptics.selection()
            if isSelected { vm.barriers.remove(option.id) }
            else { vm.barriers.insert(option.id) }
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: option.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.brandDeep : Color.inkMute)
                    .frame(width: 26)
                Text(option.label)
                    .appFont(.body)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.brand : Color.borderHairline)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(isSelected ? Color.brandSoft : Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(isSelected ? Color.brand : Color.borderHairline,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("OnboardingFlow") {
    OnboardingFlow(vm: OnboardingViewModel())
        .environmentObject(AuthService())
        .environmentObject(ProfileStore())
        .environmentObject(SubscriptionManager.shared)
}

#Preview("Onboarding paywall") {
    PaywallView(onFinish: {}, analyticsContext: "onboarding")
        .environmentObject(SubscriptionManager.shared)
}
#endif
