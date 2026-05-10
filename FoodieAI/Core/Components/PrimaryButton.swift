import SwiftUI

/// Phase 14: the redesign primary CTA.
///
/// 60pt tall, full width minus screen padding. `radius-pill`. Brand fill.
/// Ink text — yes, dark text on lime — verified WCAG-AA compliant for
/// large text (above 14pt bold the threshold is 3:1; ink #181715 over
/// brand #B8CA38 yields ~7:1 contrast, well past AA). 17pt ExtraBold.
/// Optional leading SF Symbol. `shadow-cta` carries the brand-colored
/// shadow so the button reads as the focal action even on a quiet canvas.
///
/// Press state: `scale 0.97` under `.appPress`. We do NOT add a vertical
/// lift — the colored shadow already gives depth, and a lift on top of
/// the shadow reads heavy.
///
/// Light tap haptic fires on press; loading and disabled states bypass
/// both haptic and action.
struct PrimaryButton: View {
    let title: String
    var leadingSystemImage: String? = nil
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            label
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isLoading || isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .animation(.appPress, value: isDisabled)
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView().tint(Color.ink)
        } else {
            HStack(spacing: 10) {
                if let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.ink)
                }
                Text(title)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
            }
        }
    }
}

/// Phase 14 delight: press uses the calm `.appPress` (no overshoot —
/// the user is still touching the button); release uses `.appBouncy`
/// so it springs back with a small overshoot for personality. The
/// effective animation is selected by `isPressed`.
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                Capsule().fill(Color.brand)
            )
            .appShadow(.shadowCta)
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(
                configuration.isPressed ? .appPress : .appBouncy,
                value: configuration.isPressed
            )
    }
}

#if DEBUG
#Preview("PrimaryButton — variants") {
    VStack(spacing: AppSpacing.md) {
        PrimaryButton(title: "Take a photo",
                      leadingSystemImage: "camera.fill") {}
        PrimaryButton(title: "Save to today") {}
        PrimaryButton(title: "Saving…", isLoading: true) {}
        PrimaryButton(title: "Disabled", isDisabled: true) {}
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
