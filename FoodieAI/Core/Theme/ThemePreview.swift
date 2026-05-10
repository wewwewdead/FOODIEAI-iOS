import SwiftUI

/// Visual regression check for the design system. Every token is rendered
/// in isolation with its label so we can catch palette drift, font
/// fallbacks, or shadow anomalies at a glance. Reachable via the
/// `FoodieAI-ThemePreview` Xcode scheme.
struct ThemePreview: View {
    /// Anchors so the screenshot harness can programmatically scroll to a
    /// specific section via the LAUNCH_THEME_PREVIEW_SECTION env var.
    private enum Anchor: String {
        case colors, type, spacing, radius, shadows
        case v2  // Phase 14 — jumps straight to the redesign section
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                    header
                    v2Section.id(Anchor.v2.rawValue)
                    Divider().background(Color.borderHairline)
                    Text("v1 (legacy — Phase 0 design system)")
                        .appFont(.title1)
                        .foregroundStyle(Color.inkMute)
                    colorsSection.id(Anchor.colors.rawValue)
                    typeSection.id(Anchor.type.rawValue)
                    spacingSection.id(Anchor.spacing.rawValue)
                    radiusSection.id(Anchor.radius.rawValue)
                    shadowSection.id(Anchor.shadows.rawValue)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.xl)
            }
            .background(Color.bgCanvas.ignoresSafeArea())
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

    // MARK: - v2 (Phase 14 redesign)

    /// Renders the v2 design tokens above the legacy v1 dump so a single
    /// screenshot captures the new system at a glance:
    ///   - color groups (canvas / ink / brand / accent / category)
    ///   - the type scale, with the 88pt hero number showcased
    ///   - radii (now larger), shadows (now softer), motion specs
    private var v2Section: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            HStack(spacing: AppSpacing.sm) {
                Text("v2")
                    .appFont(.title1)
                    .foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm).fill(Color.brandSoft)
                    )
                Text("redesign tokens")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
            }

            v2Colors
            v2Type
            v2Spacing
            v2Radius
            v2Shadows
            v2Motion
        }
    }

    private var v2Colors: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Color")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            ForEach(AppColorTokenV2.Group.allCases) { group in
                Text(group.rawValue).eyebrow()
                    .foregroundStyle(Color.inkMute)
                    .padding(.top, AppSpacing.xs)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: AppSpacing.md)],
                    alignment: .leading,
                    spacing: AppSpacing.md
                ) {
                    ForEach(group.members) { token in
                        v2ColorSwatch(token: token)
                    }
                }
            }
        }
    }

    private func v2ColorSwatch(token: AppColorTokenV2) -> some View {
        VStack(alignment: .center, spacing: AppSpacing.xs) {
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(token.color)
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .strokeBorder(Color.borderHairline, lineWidth: 1)
                )
            Text(token.rawValue)
                .appFont(.captionStrong)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(token.hexLabel)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var v2Type: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Type")
                .appFont(.title1)
                .foregroundStyle(Color.ink)

            // Showcase row: hero number with eyebrow, the headline scale check.
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("CALORIES").eyebrow()
                    .foregroundStyle(Color.inkMute)
                Text.number(1247)
                    .appFont(.heroNumber)
                    .foregroundStyle(Color.ink)
                Text("of 2,000")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .padding(.bottom, AppSpacing.md)

            // Then the rest of the v2 type scale, label-tagged.
            ForEach(AppFont.Style.allCases.filter { $0.isV2 }, id: \.id) { style in
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    if style == .labelEyebrow {
                        Text("eyebrow label").eyebrow()
                            .foregroundStyle(Color.ink)
                    } else if style == .heroNumber {
                        // covered by the showcase above; show a smaller sample
                        // here with the kerning visible
                        Text.number(285)
                            .appFont(.heroNumber)
                            .foregroundStyle(Color.ink)
                    } else {
                        Text("The quick brown fox")
                            .appFont(style)
                            .foregroundStyle(Color.ink)
                    }
                    HStack(spacing: AppSpacing.sm) {
                        Text(style.label)
                            .appFont(.caption)
                            .foregroundStyle(Color.ink)
                        Text(String(format: "%.0f pt", AppFont.resolvedSize(style)))
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                        if AppFont.kerning(style) != 0 {
                            Text(String(format: "kern %.1f", AppFont.kerning(style)))
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                        }
                    }
                }
            }
        }
    }

    private var v2Spacing: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Spacing")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(AppSpacingToken.v2) { token in
                    HStack(spacing: AppSpacing.md) {
                        Rectangle()
                            .fill(Color.brand)
                            .frame(width: token.value, height: 16)
                        Text("\(token.label) — \(Int(token.value)) pt")
                            .appFont(.caption)
                            .foregroundStyle(Color.ink)
                    }
                }
            }
        }
    }

    private var v2Radius: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Radius")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: AppSpacing.md)],
                alignment: .leading,
                spacing: AppSpacing.md
            ) {
                ForEach(AppRadiusToken.all) { token in
                    VStack(spacing: AppSpacing.xs) {
                        RoundedRectangle(cornerRadius: min(token.value, 50))
                            .fill(Color.bgSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: min(token.value, 50))
                                    .strokeBorder(Color.borderHairline, lineWidth: 1)
                            )
                            .frame(width: 100, height: 100)
                        Text("\(token.label) — \(token.value > 999 ? "pill" : "\(Int(token.value)) pt")")
                            .appFont(.caption)
                            .foregroundStyle(Color.ink)
                    }
                }
            }
        }
    }

    private var v2Shadows: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Shadow")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: AppSpacing.lg)],
                alignment: .leading,
                spacing: AppSpacing.lg
            ) {
                ForEach([AppShadow.shadowCard, .shadowCta, .shadowFloating]) { token in
                    VStack(spacing: AppSpacing.sm) {
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(Color.bgSurface)
                            .frame(width: 80, height: 80)
                            .appShadow(token)
                        Text(token.rawValue)
                            .appFont(.caption)
                            .foregroundStyle(Color.ink)
                    }
                    .padding(AppSpacing.md)
                }
            }
        }
    }

    private var v2Motion: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Motion")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            v2MotionRow(name: "motionQuick",       spec: "0.2s easeOut")
            v2MotionRow(name: "motionBase",        spec: "0.3s easeOut")
            v2MotionRow(name: "motionReveal",      spec: "0.5s spring(0.8)")
            v2MotionRow(name: "motionHero",        spec: "0.8s easeOut")
            v2MotionRow(name: "motionCelebration", spec: "1.2s spring(0.65)")
        }
    }

    private func v2MotionRow(name: String, spec: String) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text(name)
                .appFont(.captionStrong)
                .foregroundStyle(Color.ink)
                .frame(width: 160, alignment: .leading)
            Text(spec)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
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
