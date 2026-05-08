import SwiftUI

/// Small "About" sheet linked from the Profile tab. Shows app version
/// and acknowledgments. Satisfies the App Store expectation that users
/// can find version info; required for production, optional for TestFlight.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        ZStack {
            Color.brandIvory.ignoresSafeArea()
            VStack(spacing: AppSpacing.xl2) {
                Spacer(minLength: AppSpacing.xl)

                VStack(spacing: AppSpacing.sm) {
                    Text("Foodie Ai.")
                        .font(.custom(AppFont.PS.mplusMedium, size: 40))
                        .foregroundStyle(Color.textPrimary)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    Text("v\(version) (\(build))")
                        .appFont(.body)
                        .foregroundStyle(Color.textBody)
                        .monospacedDigit()
                }

                VStack(spacing: AppSpacing.sm) {
                    Text("FoodieAI v1 by Loren")
                        .appFont(.body)
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Powered by Google Gemini and Supabase.")
                        .appFont(.meta)
                        .foregroundStyle(Color.textMeta)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, AppSpacing.lg)

                Spacer()

                PillButton(title: "Close", variant: .primary) {
                    dismiss()
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
#Preview("AboutSheet") {
    Color.brandCream.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            AboutSheet()
                .presentationDetents([.medium])
        }
}
#endif
