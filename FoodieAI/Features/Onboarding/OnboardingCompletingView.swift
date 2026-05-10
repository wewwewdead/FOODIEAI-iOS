import SwiftUI

/// Phase 19. Brief loading moment between the notifications step and
/// the handoff to MainTabView. The view kicks off `vm.complete(...)`
/// on appear; once `vm.step == .finished`, `OnboardingFlow` yields and
/// `RootView` routes to MainTabView.
///
/// Intentionally minimal — a centered spinner over the canvas color so
/// the transition feels like a calm hand-off rather than a flash.
struct OnboardingCompletingView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()

            VStack(spacing: AppSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.brand)
                Text("Personalizing Foodie…")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .task {
            await vm.complete(profileStore: profileStore)
        }
    }
}
