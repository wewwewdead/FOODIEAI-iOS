import SwiftUI

/// Web equivalent: `SavedMealModal.jsx` (HomePage). The web uses a centered
/// full-screen modal; iOS uses a `.sheet(.medium)` presentation, which is
/// the idiomatic equivalent for a brief confirmation. The visual content
/// matches DESIGN_SYSTEM.md §HomePage save modal:
///
///   - brandIvory background
///   - Title in displayMD weight 800, textPrimary, centered
///   - Single primary `PillButton` "Close" below the title
///
/// Hand-off: presented from `CaptureView` while
/// `CaptureViewModel.state == .saved(...)`. The Close button calls
/// `onClose` which the caller wires to `viewModel.discardSaved()`.
struct SavedConfirmationSheet: View {
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.brandIvory.ignoresSafeArea()
            VStack(spacing: AppSpacing.xl2) {
                Text("This food item was saved in your daily tracker successfully!")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.lg)

                PillButton(title: "Close", variant: .primary) {
                    onClose()
                    dismiss()
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .padding(.vertical, AppSpacing.xl2)
            .frame(maxWidth: .infinity)
        }
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
