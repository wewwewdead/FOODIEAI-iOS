import SwiftUI

/// Phase 18 — post-save mood pulse.
///
/// Appears immediately after `SavedConfirmationSheet` dismisses on the
/// analyze→save path. Asks one question with three emoji options:
/// loved / fine / tough. Skip is a quiet text button below; drag-to-
/// dismiss has the same effect (no mood persisted).
///
/// The sheet is intentionally short (280pt) so it doesn't dominate.
/// Choreography:
///   - On tap of an emoji: light haptic, the chosen emoji bumps to 1.10
///     for 0.2s as a confirmation, then the sheet dismisses (writing the
///     mood happens in parallel — UI does not wait on the network).
///   - On Skip: dismiss without writing.
///
/// The view itself does NOT mutate persistence. Both `onPick` and
/// `onSkip` route through `CaptureViewModel.recordMood` /
/// `skipMoodPulse`, which keep the state-machine transition (saved →
/// idle) honest and centralize the haptics.
struct MoodPulseSheet: View {
    let onPick: (FoodLog.Mood) -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmedSelection: FoodLog.Mood? = nil

    var body: some View {
        ZStack {
            Color.brandIvory.ignoresSafeArea()

            VStack(spacing: AppSpacing.xl) {
                Text("Did this hit the spot?")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, AppSpacing.lg)

                HStack(spacing: AppSpacing.lg) {
                    ForEach(FoodLog.Mood.allCases, id: \.self) { mood in
                        MoodButton(
                            mood: mood,
                            isConfirmed: confirmedSelection == mood,
                            isDimmed: confirmedSelection != nil
                                   && confirmedSelection != mood,
                            onTap: { handleTap(mood) }
                        )
                    }
                }

                Button {
                    Haptics.tap()
                    onSkip()
                    dismiss()
                } label: {
                    Text("Skip")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.inkLight)
                        .padding(.vertical, AppSpacing.sm)
                        .padding(.horizontal, AppSpacing.lg)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip — don't record a mood")
                .padding(.bottom, AppSpacing.md)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Two-step tap: record the visual confirmation locally, fire the
    /// callback (which writes async via the view model), then dismiss
    /// after the brief bump-back so the user sees their pick land.
    private func handleTap(_ mood: FoodLog.Mood) {
        guard confirmedSelection == nil else { return }
        Haptics.tap()
        confirmedSelection = mood
        onPick(mood)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 220)
            dismiss()
        }
    }
}

// MARK: - Mood button

/// 80×80 tap target with a 60pt emoji and a small label below. Press
/// state animates a 0.95 scale; the confirm-state briefly bumps to 1.10
/// before the parent sheet dismisses.
private struct MoodButton: View {
    let mood: FoodLog.Mood
    let isConfirmed: Bool
    let isDimmed: Bool
    let onTap: () -> Void

    @State private var isPressed: Bool = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(isPressed || isConfirmed
                              ? Color.bgSurfaceSoft
                              : Color.clear)
                        .frame(width: 80, height: 80)

                    Text(mood.emoji)
                        .font(.system(size: 56))
                        .scaleEffect(isConfirmed ? 1.10 : (isPressed ? 0.95 : 1.0))
                }
                Text(mood.label)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .opacity(isDimmed ? 0.35 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed { isPressed = true }
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.65),
                   value: isConfirmed)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .accessibilityLabel(mood.label)
        .accessibilityHint("Record this mood for the meal you just saved")
    }
}

#if DEBUG
#Preview("MoodPulseSheet") {
    Color.bgCanvas.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            MoodPulseSheet(onPick: { _ in }, onSkip: {})
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
}
#endif
