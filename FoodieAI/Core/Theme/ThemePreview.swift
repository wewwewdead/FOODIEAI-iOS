import SwiftUI

/// Visual regression check for the design system. Every token is rendered
/// in isolation with its label so we can catch palette drift, font
/// fallbacks, or shadow anomalies at a glance. Reachable via the
/// `FoodieAI-ThemePreview` Xcode scheme.
struct ThemePreview: View {
    /// Anchors so the screenshot harness can programmatically scroll to a
    /// specific section via the LAUNCH_THEME_PREVIEW_SECTION env var.
    private enum Anchor: String { case colors, type, spacing, radius, shadows }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                    header
                    colorsSection.id(Anchor.colors.rawValue)
                    typeSection.id(Anchor.type.rawValue)
                    spacingSection.id(Anchor.spacing.rawValue)
                    radiusSection.id(Anchor.radius.rawValue)
                    shadowSection.id(Anchor.shadows.rawValue)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.xl)
            }
            .background(Color.brandIvory.ignoresSafeArea())
            .onAppear {
                if let section = ProcessInfo.processInfo.environment["LAUNCH_THEME_PREVIEW_SECTION"],
                   let anchor = Anchor(rawValue: section) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(nil) { proxy.scrollTo(anchor.rawValue, anchor: .top) }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Theme Preview")
                .appFont(.displayMD)
                .foregroundStyle(Color.textPrimary)
            Text("Every token from DESIGN_SYSTEM.md, rendered. If anything looks wrong here it'll look wrong in the app.")
                .appFont(.body)
                .foregroundStyle(Color.textBody)
        }
    }

    // MARK: - Colors

    private var colorsSection: some View {
        SectionHeader(title: "Colors") {
            ForEach(AppColorToken.Group.allCases) { group in
                Text(group.rawValue)
                    .appFont(.bodyLG)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.top, AppSpacing.sm)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: AppSpacing.md)],
                          alignment: .leading,
                          spacing: AppSpacing.md) {
                    ForEach(group.members) { token in
                        ColorSwatch(token: token)
                    }
                }
            }
        }
    }

    private struct ColorSwatch: View {
        let token: AppColorToken
        var body: some View {
            VStack(alignment: .center, spacing: AppSpacing.xs) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(token.color)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.textMeta.opacity(0.25), lineWidth: 0.5)
                    )
                Text(token.rawValue)
                    .appFont(.meta)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(token.hexLabel)
                    .appFont(.meta)
                    .foregroundStyle(Color.textMeta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Type

    private var typeSection: some View {
        SectionHeader(title: "Type") {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                ForEach(AppFont.Style.allCases) { style in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("The quick brown fox jumps over the lazy dog")
                            .appFont(style)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                        HStack(spacing: AppSpacing.sm) {
                            Text(style.label)
                                .appFont(.meta)
                                .foregroundStyle(Color.textPrimary)
                            Text(String(format: "%.1f pt", AppFont.resolvedSize(style)))
                                .appFont(.meta)
                                .foregroundStyle(Color.textMeta)
                            if AppFont.kerning(style) != 0 {
                                Text(String(format: "kern %.0f", AppFont.kerning(style)))
                                    .appFont(.meta)
                                    .foregroundStyle(Color.textMeta)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Spacing

    private var spacingSection: some View {
        SectionHeader(title: "Spacing") {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(AppSpacingToken.all) { token in
                    HStack(spacing: AppSpacing.md) {
                        Rectangle()
                            .fill(Color.brand)
                            .frame(width: token.value, height: 16)
                        Text("\(token.label) — \(Int(token.value)) pt")
                            .appFont(.meta)
                            .foregroundStyle(Color.textBody)
                    }
                }
            }
        }
    }

    // MARK: - Radius

    private var radiusSection: some View {
        SectionHeader(title: "Radius") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: AppSpacing.md)],
                      alignment: .leading,
                      spacing: AppSpacing.md) {
                ForEach(AppRadiusToken.all) { token in
                    VStack(spacing: AppSpacing.xs) {
                        RoundedRectangle(cornerRadius: min(token.value, 50))
                            .fill(Color.brandCream)
                            .overlay(
                                RoundedRectangle(cornerRadius: min(token.value, 50))
                                    .strokeBorder(Color.textMeta.opacity(0.4), lineWidth: 0.5)
                            )
                            .frame(width: 100, height: 100)
                        Text("\(token.label) — \(token.value > 999 ? "pill" : "\(Int(token.value)) pt")")
                            .appFont(.meta)
                            .foregroundStyle(Color.textPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Shadows

    private var shadowSection: some View {
        SectionHeader(title: "Shadows") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: AppSpacing.lg)],
                      alignment: .leading,
                      spacing: AppSpacing.lg) {
                ForEach(AppShadow.allCases) { token in
                    VStack(spacing: AppSpacing.sm) {
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(Color.white)
                            .frame(width: 80, height: 80)
                            .appShadow(token)
                        Text(token.rawValue)
                            .appFont(.meta)
                            .foregroundStyle(Color.textPrimary)
                    }
                    .padding(AppSpacing.md)
                }
            }
        }
    }

    // MARK: - Section wrapper

    private struct SectionHeader<Content: View>: View {
        let title: String
        @ViewBuilder var content: () -> Content
        var body: some View {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(title)
                    .appFont(.displayMD)
                    .foregroundStyle(Color.textPrimary)
                content()
            }
        }
    }
}

#Preview {
    ThemePreview()
}
