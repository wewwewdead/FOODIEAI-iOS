import SwiftUI

/// Web equivalent: `.form__upload` / `.form__upload--empty` (UploadForm).
/// 320×320 with two states. Picker integration is Phase 5; here we only
/// render the visual + invoke `onTap`.
struct DashedDropZone: View {
    let image: UIImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) { EmptyView() }
            .buttonStyle(DropZoneButtonStyle(image: image))
            .accessibilityLabel(image == nil ? "Take or pick a meal photo" : "Change meal photo")
    }
}

private struct DropZoneButtonStyle: ButtonStyle {
    let image: UIImage?
    func makeBody(configuration: Configuration) -> some View {
        DashedDropZoneSurface(image: image, isPressed: configuration.isPressed)
    }
}

/// The visual surface — exposed so previews can force `isPressed: true`
/// without simulating a touch.
struct DashedDropZoneSurface: View {
    let image: UIImage?
    var isPressed: Bool = false

    private static let side: CGFloat = 320

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
                    .appShadow(.upload)
                if isPressed {
                    overlay
                        .transition(.opacity)
                }
            } else {
                emptyState
            }
        }
        .frame(width: Self.side, height: Self.side)
        .animation(.appPress, value: isPressed)
        .animation(.appPress, value: image == nil)
    }

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xl2)
                .fill(Color.black.opacity(0.055))
            RoundedRectangle(cornerRadius: AppRadius.xl2)
                .strokeBorder(
                    Color.dropZoneStroke,
                    style: StrokeStyle(lineWidth: 6, dash: [6, 14])
                )
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Color.dropZoneStroke)
                Text("Meal Snap!")
                    .appFont(.bodyLG)
                    .foregroundStyle(Color.dropZoneStroke)
            }
        }
    }

    private var overlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xl2)
                .fill(Color.black.opacity(0.3))
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white)
                Text("Change Photo")
                    .appFont(.body)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
        }
    }
}

#Preview("DashedDropZone — empty") {
    DashedDropZone(image: nil) {}
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandIvory)
}

#Preview("DashedDropZone — filled") {
    let placeholder = UIImage(systemName: "fork.knife.circle.fill")?
        .withTintColor(.systemBrown, renderingMode: .alwaysOriginal)
    return DashedDropZone(image: placeholder) {}
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandIvory)
}

#Preview("DashedDropZone — filled, overlay forced") {
    let placeholder = UIImage(systemName: "fork.knife.circle.fill")?
        .withTintColor(.systemBrown, renderingMode: .alwaysOriginal)
    return DashedDropZoneSurface(image: placeholder, isPressed: true)
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandIvory)
}
