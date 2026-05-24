import SwiftUI

/// Premium-polish wave: shared sheet chrome.
///
/// Every sheet in the app gets:
///   - A larger 28pt corner radius (matches `AppRadius.xl2`, the
///     hero-card radius elsewhere — visual cohesion between cards
///     and the modals that grow from them)
///   - The canvas color as the sheet background (so the sheet feels
///     like a continuation of the surface beneath, not a system gray
///     drawer)
///   - Visible drag indicator
///
/// Pass `tint: .brand` for a brand-washed accent (used by celebratory
/// sheets like SavedConfirmationSheet); default is the neutral canvas.
extension View {
    /// Apply the app's premium sheet chrome. Behavior-safe — only
    /// touches presentation modifiers, never content.
    func premiumSheet(
        tint: Color? = nil,
        cornerRadius: CGFloat = AppRadius.xl2
    ) -> some View {
        self
            .presentationCornerRadius(cornerRadius)
            .presentationBackground {
                ZStack {
                    Color.bgCanvas
                    if let tint {
                        LinearGradient(
                            colors: [tint.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
            }
            .presentationDragIndicator(.visible)
    }
}
