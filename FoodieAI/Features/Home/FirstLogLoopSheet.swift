import SwiftUI

/// Once-only flag for the first-save loop hook.
enum FirstLogLoopHook {
    private static let key = "loop.firstLog.shown.v1"
    static var didShow: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markShown() { UserDefaults.standard.set(true, forKey: key) }
}

/// The loop-building moment shown right after a user's FIRST saved meal. It
/// closes the Hook loop in onboarding: the log just delivered the reward, so we
/// (1) celebrate it as "day 1 of your streak" — endowed progress + a first win
/// that wires the habit — and (2) offer to turn on meal-time reminders, loading
/// the external trigger the instant the user has felt the value (not cold up
/// front). Fires exactly once, from the first save.
struct FirstLogLoopSheet: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var confettiActive = false
    @State private var isWorking = false

    private let service = ProfileService.shared

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer(minLength: AppSpacing.lg)

            ZStack {
                BrandConfetti(active: confettiActive)
                ZStack {
                    Circle().fill(Color.brandSoft).frame(width: 96, height: 96)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(Color.brand)
                }
            }

            VStack(spacing: AppSpacing.sm) {
                Text("Day 1, you're on the board")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("That's day one of your streak. Snap a meal each day to keep it going, the first 7 days are where the habit sticks.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.lg)

            Spacer(minLength: 0)

            VStack(spacing: AppSpacing.sm) {
                PrimaryButton(title: isWorking ? "Turning on…" : "Turn on meal-time nudges",
                              leadingSystemImage: "bell.badge.fill",
                              isLoading: isWorking,
                              isDisabled: isWorking) {
                    Task { await enableReminders() }
                }
                Button {
                    Haptics.tap()
                    // Don't re-ask at the old 3rd-save gate right after a decline.
                    NotificationGate.markPromptShown()
                    dismiss()
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
                .disabled(isWorking)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgCanvas.ignoresSafeArea())
        .onAppear {
            Haptics.success()
            withAnimation(.easeOut(duration: 0.3)) { confettiActive = true }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private func enableReminders() async {
        isWorking = true
        defer { isWorking = false }
        let granted = await NotificationScheduler.shared.requestAuthorization()
        if granted {
            // Set the master + meal flags ourselves — a system grant alone
            // leaves `notificationsEnabled` false, so reschedule wouldn't
            // actually schedule anything (the onboarding step that used to set
            // it is now deferred in scan-first).
            if let updated = try? await service.setNotificationPreferences(
                notificationsEnabled: true,
                reminderBreakfast: true,
                reminderLunch: true,
                reminderDinner: true
            ) {
                profileStore.apply(updated)
            }
            NotificationGate.markPromptShown()
            await AppForegroundOrchestrator.shared.runOnForeground(caller: "firstLogLoop")
            Haptics.success()
        } else {
            NotificationGate.defer30Days()
            Haptics.warning()
        }
        dismiss()
    }
}
