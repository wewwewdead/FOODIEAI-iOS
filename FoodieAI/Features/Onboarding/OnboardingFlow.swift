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
                SignInView()
                    .transition(.opacity)
            case .archetype:
                OnboardingArchetypeView(vm: vm, ctaNamespace: ctaNamespace,
                                        isSignedIn: auth.isSignedIn)
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
            case .coaches:
                OnboardingCoachStepView(vm: vm, ctaNamespace: ctaNamespace)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
            case .notifications:
                OnboardingNotificationStepView(vm: vm, ctaNamespace: ctaNamespace)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.38)),
                        removal:   .opacity.animation(.easeIn(duration: 0.22))
                    ))
            case .subscription:
                OnboardingSubscriptionStepView(vm: vm, ctaNamespace: ctaNamespace)
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
}

// MARK: - Subscription comparison step

/// Phase 22 — informational Pro vs Free comparison shown after the
/// notification opt-in and before the completing screen. Never blocks
/// onboarding: both CTAs advance the flow. "Try Pro" presents the
/// existing `PaywallView` sheet (which handles purchase/restore/Apple
/// disclosure); regardless of purchase outcome the flow continues so
/// the user is never trapped here by a cancel or a StoreKit error.
///
/// Free-tier copy makes the server's 4-then-2 policy explicit so
/// users aren't surprised on day 8 when their cap drops. Mirrors the
/// language used in `SubscriptionInfoView` so the two surfaces stay
/// in lockstep.
///
/// Lives inline in OnboardingFlow.swift rather than its own file so
/// new files don't need a pbxproj add (project uses manual file
/// management — see project memory).
private struct OnboardingSubscriptionStepView: View {
    @ObservedObject var vm: OnboardingViewModel
    var ctaNamespace: Namespace.ID? = nil

    @EnvironmentObject private var subscriptions: SubscriptionManager
    @State private var showingPaywall = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    heroIcon
                    headline
                    bodyParagraph
                    comparisonCard
                    bonusWeekNote
                    Spacer(minLength: AppSpacing.lg)
                    buttons
                    disclaimer
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                .padding(.bottom, AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            BackChevron(action: { Haptics.tap(); vm.back() })
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .environmentObject(subscriptions)
        }
    }

    // MARK: - Header

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [ProGold.cream, ProGold.warm],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)
                .shadow(color: ProGold.warm.opacity(0.45), radius: 12, x: 0, y: 4)
            Image(systemName: "crown.fill")
                .font(.system(size: 38, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: ProGold.deep.opacity(0.5), radius: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.lg)
    }

    private var headline: some View {
        Text("Free is generous.\nPro is for everyday.")
            .appFont(.display1)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bodyParagraph: some View {
        Text("Most days you'll never hit the free limit. Pro is for the people who snap every meal — same insights, more scans.")
            .appFont(.bodyV2)
            .foregroundStyle(Color.inkMute)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Comparison card

    private var comparisonCard: some View {
        VStack(spacing: 0) {
            comparisonHeaderRow
            comparisonRow(
                label: "Photo scans / day",
                free: "4, then 2",
                pro: "10"
            )
            comparisonRow(
                label: "Manual logging",
                free: "Unlimited",
                pro: "Unlimited"
            )
            comparisonRow(
                label: "FoodOS, recap, story",
                free: "Included",
                pro: "Included"
            )
            comparisonRow(
                label: "Cancel anytime",
                free: "—",
                pro: "Yes"
            )
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("FREE")
                .appFont(.labelEyebrow)
                .foregroundStyle(Color.inkMute)
                .frame(width: 100, alignment: .center)
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10, weight: .heavy))
                Text("PRO")
                    .appFont(.labelEyebrow)
            }
            .foregroundStyle(ProGold.deep)
            .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
    }

    private func comparisonRow(label: String, free: String, pro: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(free)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .frame(width: 100, alignment: .center)
            Text(pro)
                .appFont(.captionStrong)
                .foregroundStyle(ProGold.deep)
                .multilineTextAlignment(.center)
                .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.borderHairline)
                .frame(height: 1)
        }
    }

    // Spells out the bonus-week policy so day-8 users aren't surprised
    // when their cap drops from 4 to 2. Bonus framing — "to help you
    // get the hang of it" — keeps it generous rather than bait-and-
    // switch.
    private var bonusWeekNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gift.fill")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.brandDeep)
                .padding(.top, 2)
            (
                Text("Free starts with 4 scans/day for your first week ")
                    .appFont(.caption)
                + Text("to help you build the habit, ")
                    .appFont(.caption)
                + Text("then settles at 2/day.")
                    .appFont(.captionStrong)
            )
            .foregroundStyle(Color.inkMute)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(Color.brandSoft.opacity(0.7))
        )
    }

    // MARK: - CTAs

    private var buttons: some View {
        VStack(spacing: AppSpacing.sm) {
            // Primary CTA depends on current tier. A user who already
            // upgraded in the paywall sheet sees "Continue" instead of
            // a redundant "Try Pro" prompt.
            if subscriptions.tier == .pro {
                PrimaryButton(title: "Continue",
                              leadingSystemImage: "checkmark") {
                    vm.advance()
                }
                .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
            } else {
                Button {
                    Haptics.tap()
                    showingPaywall = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 16, weight: .heavy))
                        Text("Try Pro")
                            .appFont(.title2)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [ProGold.warm, ProGold.edgeDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(ProGold.cream.opacity(0.6), lineWidth: 0.8)
                    )
                    .shadow(color: ProGold.warm.opacity(0.45), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
            }

            // Secondary always available. Free users see this as a
            // soft opt-out; pro users see it as a way to bypass the
            // "Continue" tap if they want to keep moving.
            Button {
                Haptics.tap()
                vm.advance()
            } label: {
                Text(subscriptions.tier == .pro
                     ? "Skip"
                     : "Continue with Free")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        Capsule().strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var disclaimer: some View {
        Text("Upgrade or cancel anytime in Profile.")
            .appFont(.caption)
            .foregroundStyle(Color.inkLight)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, AppSpacing.xs)
    }
}

#if DEBUG
#Preview("OnboardingFlow") {
    OnboardingFlow(vm: OnboardingViewModel())
        .environmentObject(AuthService())
        .environmentObject(ProfileStore())
        .environmentObject(SubscriptionManager.shared)
}

#Preview("Subscription step") {
    OnboardingSubscriptionStepView(vm: OnboardingViewModel(initialStep: .subscription))
        .environmentObject(SubscriptionManager.shared)
}
#endif
