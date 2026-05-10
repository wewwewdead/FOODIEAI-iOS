import SwiftUI

/// Phase 13: shared empty-state composition. Used by `TodayView`'s
/// "no meals logged today" branch and by `DayDetailSheet`'s "no meals
/// logged this day" branch.
///
/// Design: muted SF Symbol at 64pt in `.brand @ 30%`, message text below
/// in body weight semibold + `textMeta`. The icon bobs gently under
/// `.appAmbient` so the screen feels alive instead of static —
/// intentionally subtle, never demanding attention.
struct AmbientEmptyState: View {
    let iconSystemName: String
    let message: String

    @State private var bobbing: Bool = false

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: iconSystemName)
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.brand.opacity(0.3))
                .offset(y: bobbing ? -3 : 0)
                .onAppear {
                    withAnimation(.appAmbient) {
                        bobbing = true
                    }
                }
            Text(message)
                .appFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.textMeta)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("AmbientEmptyState") {
    VStack(spacing: AppSpacing.xl3) {
        AmbientEmptyState(iconSystemName: "tray",
                          message: "No meals logged today yet")
        AmbientEmptyState(iconSystemName: "fork.knife.circle",
                          message: "No meals logged this day")
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.brandCream)
}
#endif
