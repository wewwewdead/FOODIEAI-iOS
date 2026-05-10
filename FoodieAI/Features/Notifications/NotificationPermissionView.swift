import SwiftUI
import UIKit

/// Phase 17. Pre-prompt sheet that explains the value before the system
/// permission dialog appears. Apple's HIG: justify *why* before the
/// system prompt, never after.
///
/// Lifecycle owned by `NotificationGate`:
///   - Caller inspects `NotificationGate.shouldPresentPermissionSheet()`
///     and presents this if true.
///   - "Yes" → `NotificationScheduler.requestAuthorization()` (which
///     surfaces the system prompt). On grant we kick a reschedule via
///     the closure.
///   - "Not now" → `NotificationGate.defer30Days()`.
///
/// No analytics, no ABCs of dark patterns — the explanation matches
/// what the app actually does.
struct NotificationPermissionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isRequesting = false
    @State private var lastError: Error? = nil

    /// Called after the user grants permission. Caller should kick a
    /// `NotificationScheduler.reschedule(...)` here.
    var onGranted: () -> Void = {}
    /// Called whenever the sheet dismisses (granted, denied, or
    /// deferred). Lets the parent flip its presentation flag back.
    var onClosed: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            heroIcon
            title
            body_
            buttons
            disclaimer
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl2)
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.bgCanvas)
        .onAppear {
            NotificationGate.markPromptShown()
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
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Want gentle nudges?")
                .appFont(.display1)
                .foregroundStyle(Color.ink)
        }
    }

    private var body_: some View {
        Text("We'll only nudge you at the times you usually eat. No streak shame, no daily pressure. Two taps to disable forever in Profile.")
            .appFont(.bodyV2)
            .foregroundStyle(Color.inkMute)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        VStack(spacing: AppSpacing.sm) {
            PrimaryButton(
                title: isRequesting ? "Asking iOS…" : "Yes, send nudges",
                leadingSystemImage: isRequesting ? nil : "bell.fill",
                isLoading: isRequesting
            ) {
                Task { await accept() }
            }

            Button {
                Haptics.tap()
                NotificationGate.defer30Days()
                dismiss()
                onClosed()
            } label: {
                Text("Not now")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)

            if let lastError {
                Text(lastError.localizedDescription)
                    .appFont(.caption)
                    .foregroundStyle(Color.error)
            }
        }
    }

    private var disclaimer: some View {
        Text("We'll never share these with anyone. Notifications are scheduled on your device, not on our servers.")
            .appFont(.caption)
            .foregroundStyle(Color.inkLight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accept() async {
        isRequesting = true
        defer { isRequesting = false }
        let granted = await NotificationScheduler.shared.requestAuthorization()
        if granted {
            Haptics.success()
            NotificationGate.markPromptShown()
            dismiss()
            onGranted()
            onClosed()
        } else {
            // System prompt was shown and user tapped "Don't allow",
            // OR the OS surfaced an error. Treat both as "deferred"
            // so we don't pester them; the settings UI's
            // open-Settings.app fallback can re-engage later.
            Haptics.warning()
            NotificationGate.defer30Days()
            dismiss()
            onClosed()
        }
    }
}

/// Phase 17. Smaller "Notifications are off — open Settings" sheet.
/// Shown from `NotificationSettingsView` when the user toggles a
/// reminder on while the system status is `.denied`.
struct NotificationDeniedView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 72, height: 72)
                Image(systemName: "bell.slash")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Notifications are off for Foodie")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                Text("Open Settings to turn them on. We only schedule on your device — nothing leaves Foodie.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppSpacing.sm) {
                PrimaryButton(title: "Open Settings",
                              leadingSystemImage: "gearshape.fill") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    dismiss()
                }
                Button {
                    dismiss()
                } label: {
                    Text("Maybe later")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl2)
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.bgCanvas)
    }
}

#if DEBUG
#Preview("Permission") {
    NotificationPermissionView()
}
#Preview("Denied") {
    NotificationDeniedView()
}
#endif
