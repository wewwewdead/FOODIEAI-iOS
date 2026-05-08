import SwiftUI

/// Web equivalent: `.save-bttn` and `.cancel-bttn` (HomePage analyze result).
/// 100×40, radius lg-equivalent (20pt — half of 40h for capsule feel),
/// scale 1.06 on press. greenSave + check or orangeCancel + xmark.
struct CircleActionButton: View {
    enum Kind {
        case save, cancel

        var icon: String {
            switch self {
            case .save:   "checkmark"
            case .cancel: "xmark"
            }
        }

        var fill: Color {
            switch self {
            case .save:   .greenSave
            case .cancel: .orangeCancel
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .save:   "Save meal"
            case .cancel: "Cancel"
            }
        }
    }

    let kind: Kind
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: kind.icon)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 100, height: 40)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl2).fill(kind.fill)
            )
        }
        .buttonStyle(CircleActionButtonStyle())
        .disabled(isLoading)
        .accessibilityLabel(kind.accessibilityLabel)
    }
}

private struct CircleActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.06 : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

#Preview("CircleActionButton") {
    VStack(spacing: AppSpacing.lg) {
        Text("Default").appFont(.meta).foregroundStyle(Color.textMeta)
        HStack(spacing: AppSpacing.lg) {
            CircleActionButton(kind: .cancel) {}
            CircleActionButton(kind: .save) {}
        }
        Text("Loading").appFont(.meta).foregroundStyle(Color.textMeta)
        HStack(spacing: AppSpacing.lg) {
            CircleActionButton(kind: .cancel, isLoading: true) {}
            CircleActionButton(kind: .save, isLoading: true) {}
        }
    }
    .padding(AppSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.brandIvory)
}
