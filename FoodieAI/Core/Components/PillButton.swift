import SwiftUI

/// Web equivalent: `.signup-btn` / `.signup-btn--mobile` (NavBar),
/// `.form__analyze` (UploadForm), `.shiny-button` (LandingPage hero).
/// One iOS shape unifies all three; press-state behavior diverges per variant.
struct PillButton: View {
    enum Variant { case primary, outline, ghost }

    let title: String
    var variant: Variant = .primary
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            // Phase 13: light tap haptic on press release. Only fires when
            // the button is actually actionable; loading/disabled states
            // skip the haptic and the action.
            Haptics.tap()
            action()
        } label: {
            label
        }
        .buttonStyle(PillButtonStyleImpl(variant: variant, isLoading: isLoading))
        .disabled(isLoading || isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .animation(.appPress, value: isDisabled)
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView().tint(progressTint)
        } else {
            Text(title).appFont(.pillTitle)
        }
    }

    private var progressTint: Color {
        switch variant {
        case .primary, .ghost: .white
        case .outline:         .brand
        }
    }
}

/// Internal style — handles per-variant fill/stroke/text-color swaps and the
/// press lift via `.spring(response: 0.3, dampingFraction: 0.7)`.
private struct PillButtonStyleImpl: ButtonStyle {
    let variant: PillButton.Variant
    let isLoading: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && !isLoading
        configuration.label
            .foregroundStyle(textColor(pressed: pressed))
            .padding(.horizontal, AppSpacing.xl3)
            .padding(.vertical, AppSpacing.md)
            .frame(minHeight: 56)
            .background(
                Capsule().fill(fill(pressed: pressed))
            )
            .overlay(
                Capsule()
                    .strokeBorder(stroke(pressed: pressed), lineWidth: borderWidth)
            )
            .background(
                // Backdrop fill for ghost when pressed — uses .ultraThinMaterial
                // (deviation from web's flat rgba(230,245,179,0.145)). See
                // ComponentGallery deviations note.
                Group {
                    if variant == .ghost && pressed {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
            )
            .scaleEffect(pressed && variant == .ghost ? 1.05 : 1.0)
            .offset(y: pressed && variant == .outline ? -2 : 0)
            .modifier(PressShadow(active: pressed && variant == .outline))
            .animation(.appPress, value: pressed)
    }

    // MARK: - Per-variant tokens

    private var borderWidth: CGFloat {
        switch variant {
        case .primary, .outline: 2
        case .ghost:             1
        }
    }

    private func fill(pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? .brand : .brandCreamSoft
        case .outline: pressed ? .brand : .clear
        case .ghost:   .clear
        }
    }

    private func stroke(pressed: Bool) -> Color {
        switch variant {
        case .primary, .outline: .brand
        case .ghost:             .white.opacity(pressed ? 0.6 : 1.0)
        }
    }

    private func textColor(pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? .white : .greenAnalysis
        case .outline: pressed ? .white : .brand
        case .ghost:   .white
        }
    }
}

/// Lift shadow applied only on the outline variant's pressed state.
private struct PressShadow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.appShadow(.card)
        } else {
            content
        }
    }
}

#Preview("PillButton states") {
    VStack(spacing: AppSpacing.lg) {
        Group {
            PillButton(title: "Sign Up!", variant: .primary) {}
            PillButton(title: "Loading", variant: .primary, isLoading: true) {}
            PillButton(title: "Disabled", variant: .primary, isDisabled: true) {}
        }
        Divider()
        Group {
            PillButton(title: "Analyze", variant: .outline) {}
            PillButton(title: "Analyzing…", variant: .outline, isLoading: true) {}
            PillButton(title: "Disabled", variant: .outline, isDisabled: true) {}
        }
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.brandIvory)
}

#Preview("PillButton ghost on dark") {
    VStack(spacing: AppSpacing.lg) {
        PillButton(title: "Try for FREE", variant: .ghost) {}
        PillButton(title: "Loading", variant: .ghost, isLoading: true) {}
    }
    .padding(AppSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
        LinearGradient(
            colors: [.greenCalorie, .greenAnalysis],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    )
}
