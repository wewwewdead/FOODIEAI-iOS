import SwiftUI

/// Web equivalent: `.navbar` + `.nav` + `.navlinks` (NavBar component).
/// Translucent top bar via `.ultraThinMaterial`. Navigation routing isn't
/// wired in Phase 3 — this is a reusable bar for whichever screens choose
/// to mount it (Onboarding / Home in Phase 4+).
struct BlurredNavBar<Trailing: View>: View {
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image("FoodieLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                Text("Foodie AI.")
                    .appFont(.nav)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: 56)
        .padding(.horizontal, AppSpacing.lg)
        .background(.ultraThinMaterial)
        .appShadow(.nav)
    }
}

extension BlurredNavBar where Trailing == EmptyView {
    init() { self.init(trailing: { EmptyView() }) }
}

#Preview("BlurredNavBar over content") {
    BlurredNavBarPreview()
}

private struct BlurredNavBarPreview: View {
    private let palette: [Color] = [.brand, .brandBright, .brandCream, .panelBenefits]

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(palette[i % palette.count])
                            .frame(height: 120)
                            .overlay(
                                Text(verbatim: "Scroll content #\(i)")
                                    .appFont(.displayMD)
                                    .foregroundStyle(Color.textPrimary.opacity(0.6))
                            )
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, 80) // clear the nav bar
            }
            BlurredNavBar {
                PillButton(title: "Sign Up!", variant: .primary) {}
                    .scaleEffect(0.6)
                    .frame(height: 40)
            }
        }
        .background(Color.brandIvory)
    }
}
