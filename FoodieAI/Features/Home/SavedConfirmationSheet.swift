import SwiftUI

/// Phase 13: success choreography upgrade.
///
/// Animation timeline (approx):
///   t=0   ms: sheet appears, everything offscreen/invisible.
///   t=80  ms: checkmark scale-spring begins (`.appPop` — under-damped).
///             Concurrently a brand-colored ring expands outward
///             (radial burst) from the checkmark center.
///   t=550 ms: checkmark hits its full scale; `Haptics.success()` fires
///             so the tactile feedback lands with the visual.
///   t=600 ms: title text fades in (`.appEntrance`).
///   t=900 ms: Close PillButton fades in.
///
/// Web equivalent: `SavedMealModal.jsx` (HomePage). The web uses a
/// centered full-screen modal; iOS keeps the existing `.sheet(.medium)`
/// presentation, which is the idiomatic equivalent on iOS.
/// Lightweight payload describing a next-step suggestion shown below
/// the saved confirmation. Determined by the caller from cached state
/// (no fetches inside this sheet). `actionLabel` is optional — when nil
/// only the title line is shown.
struct NextStepHint: Equatable {
    let message: String
    let actionLabel: String?
    /// Action kind so the parent can route to the right tab. `nil` when
    /// `actionLabel == nil`.
    let action: Action?

    enum Action: Equatable {
        /// Switch to the Tracker tab.
        case viewTracker
        /// Stay on Home, dismiss and return to idle for another scan.
        case scanAnother
    }
}

struct SavedConfirmationSheet: View {
    let onClose: () -> Void
    /// Optional next-step suggestion. Computed by the caller from the
    /// freshest cached state at the moment of presentation so the sheet
    /// itself stays network-free. `nil` falls back to the existing
    /// title-only layout.
    var nextStep: NextStepHint? = nil
    /// Invoked when the user taps the inline next-step action. The
    /// parent is responsible for dismissing this sheet (via `onClose`)
    /// and routing to the requested destination.
    var onNextStepAction: ((NextStepHint.Action) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var checkmarkScale: CGFloat = 0
    @State private var checkmarkOpacity: Double = 0
    @State private var burstScale: CGFloat = 0.5
    @State private var burstOpacity: Double = 1
    @State private var titleVisible: Bool = false
    @State private var buttonVisible: Bool = false
    /// Phase 14 delight: confetti burst fires as the checkmark lands.
    @State private var confettiActive: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.bgSurface.ignoresSafeArea()
            VStack(spacing: AppSpacing.xl) {
                checkmarkBlock

                Text("This food item was saved in your daily tracker successfully!")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.lg)
                    .opacity(titleVisible ? 1 : 0)
                    .offset(y: titleVisible ? 0 : 8)
                    .animation(.appEntrance, value: titleVisible)

                if let hint = nextStep {
                    NextStepInline(
                        hint: hint,
                        onAction: { action in
                            onNextStepAction?(action)
                            dismiss()
                        }
                    )
                    .padding(.horizontal, AppSpacing.lg)
                    .opacity(titleVisible ? 1 : 0)
                    .offset(y: titleVisible ? 0 : 6)
                    .animation(.appEntrance, value: titleVisible)
                }

                PillButton(title: "Close", variant: .primary) {
                    onClose()
                    dismiss()
                }
                .padding(.horizontal, AppSpacing.lg)
                .opacity(buttonVisible ? 1 : 0)
                .scaleEffect(buttonVisible ? 1 : 0.95)
                .animation(.appEntrance, value: buttonVisible)
            }
            .padding(.vertical, AppSpacing.xl)
            .frame(maxWidth: .infinity)
        }
        .task {
            await runEntrance()
        }
    }

    /// Checkmark + radial burst + confetti, all centered in the same
    /// frame so every effect radiates from the checkmark.
    private var checkmarkBlock: some View {
        ZStack {
            // Phase 14 delight: confetti burst behind the checkmark.
            ConfettiBurst(active: confettiActive, count: 22, spread: 130)

            // Radial burst — a hollow brand ring that scales out and fades.
            Circle()
                .strokeBorder(Color.brand, lineWidth: 4)
                .frame(width: 72, height: 72)
                .scaleEffect(burstScale)
                .opacity(burstOpacity)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(Color.brand)
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)
        }
        .frame(height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved")
    }

    private func runEntrance() async {
        if reduceMotion {
            // Quiet path: opacity-only fade, no overshoot, no radial
            // burst, no confetti. Haptic still fires so the user has
            // tactile confirmation; title and button reveal together
            // so the user can act immediately.
            withAnimation(.appReduced) {
                checkmarkScale = 1
                checkmarkOpacity = 1
                burstScale = 1.0
                burstOpacity = 0
                titleVisible = true
                buttonVisible = true
            }
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 120)
            Haptics.success()
            return
        }

        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 80)

        // Checkmark scale-pop and opacity-fade in the same frame so the
        // glyph appears with confidence rather than dissolving.
        // Phase 14 delight: bouncier overshoot so the checkmark stamps in.
        withAnimation(.appBouncy) {
            checkmarkScale = 1
        }
        withAnimation(.appEntrance) {
            checkmarkOpacity = 1
        }
        // Radial burst: expand and fade simultaneously over 0.8s.
        withAnimation(.easeOut(duration: 0.8)) {
            burstScale = 2.0
            burstOpacity = 0
        }
        // Phase 14 delight: confetti burst fires alongside the checkmark.
        confettiActive = true

        // The bouncy spring stabilizes at roughly t≈+470ms; fire the
        // success haptic when the visual lands.
        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 470)
        Haptics.success()

        // Title appears just after the checkmark settles.
        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 50)
        titleVisible = true

        // Button appears 0.3s after the title — gives the eye time to
        // read the headline before the action is offered.
        try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
        buttonVisible = true
    }
}

/// Small inline message + optional action link rendered below the
/// saved-confirmation title. Kept visually quiet so it reads as guidance,
/// not a competing CTA against the Close pill below it.
private struct NextStepInline: View {
    let hint: NextStepHint
    let onAction: (NextStepHint.Action) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(hint.message)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let label = hint.actionLabel, let action = hint.action {
                Button {
                    Haptics.tap()
                    onAction(action)
                } label: {
                    HStack(spacing: 6) {
                        Text(label)
                            .appFont(.captionStrong)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundStyle(Color.brandDeep)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("SavedConfirmationSheet") {
    Color.brandCream.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            SavedConfirmationSheet(onClose: {})
                .presentationDetents([.medium])
        }
}
#endif
