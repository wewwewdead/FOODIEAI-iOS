import SwiftUI

/// Phase 19. Step 4 — opt-in to smart reminders.
///
/// Adapts `NotificationPermissionView` into the onboarding flow:
///   - Doesn't request system permission inline; defers that to
///     `OnboardingViewModel.complete()` so the system prompt lands
///     after the user has answered the in-app question (HIG: justify
///     before prompting).
///   - Both buttons resolve the in-app question, so there's no
///     separate "Skip this" link — the buttons are the resolutions.
struct OnboardingNotificationStepView: View {
    @ObservedObject var vm: OnboardingViewModel
    /// Shared CTA namespace from `OnboardingFlow`. The primary pill
    /// morphs in from the coaches step into "Yes, send nudges" here.
    var ctaNamespace: Namespace.ID? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    heroIcon
                    headline
                    bodyParagraph
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
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(Color.brandSoft)
                .frame(width: 88, height: 88)
            Image(systemName: "bell.badge")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.lg)
    }

    private var headline: some View {
        Text("Want gentle nudges?")
            .appFont(.display1)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bodyParagraph: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("We'll only nudge you at the times you usually eat. No streak shame, no daily pressure.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
            Text("Two taps to disable forever in Profile.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        VStack(spacing: AppSpacing.sm) {
            PrimaryButton(title: "Yes, send nudges",
                          leadingSystemImage: "bell.fill") {
                vm.notificationsAccepted = true
                vm.advance()
            }
            .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)

            Button {
                Haptics.tap()
                vm.notificationsAccepted = false
                vm.advance()
            } label: {
                Text("Not now")
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
        Text("Notifications stay on your device. We never share them.")
            .appFont(.caption)
            .foregroundStyle(Color.inkLight)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, AppSpacing.xs)
    }
}

#if DEBUG
#Preview("Notifications") {
    OnboardingNotificationStepView(vm: OnboardingViewModel(initialStep: .notifications))
}
#endif
