import CoreGraphics

/// Spacing scale per DESIGN_SYSTEM.md §Spacing.
/// Swift identifiers can't start with a digit, so the web "2xl/3xl/..." tokens
/// become `xl2/xl3/...`. Map is one-to-one.
enum AppSpacing {
    static let xs:  CGFloat = 4    // 0.25rem
    static let sm:  CGFloat = 8    // 0.5rem
    static let md:  CGFloat = 16   // 1rem
    static let lg:  CGFloat = 24   // 1.5rem
    static let xl:  CGFloat = 32   // 2rem
    static let xl2: CGFloat = 48   // 3rem
    static let xl3: CGFloat = 64   // 4rem
    static let xl4: CGFloat = 96   // 6rem
    static let xl5: CGFloat = 112  // 7rem (page padding)
    static let xl6: CGFloat = 160  // 10rem (home top padding)

    /// `.card` padding on About / Education / Login. Lives between md (16) and
    /// xl (32) — the web uses 28pt literally, so we expose it as its own
    /// token rather than approximating to the nearest scale step.
    static let cardPad: CGFloat = 28
}

/// Token catalog for ThemePreview.
struct AppSpacingToken: Identifiable {
    let label: String
    let value: CGFloat
    var id: String { label }

    static let all: [AppSpacingToken] = [
        .init(label: "xs",  value: AppSpacing.xs),
        .init(label: "sm",  value: AppSpacing.sm),
        .init(label: "md",  value: AppSpacing.md),
        .init(label: "lg",  value: AppSpacing.lg),
        .init(label: "xl",  value: AppSpacing.xl),
        .init(label: "xl2", value: AppSpacing.xl2),
        .init(label: "xl3", value: AppSpacing.xl3),
        .init(label: "xl4", value: AppSpacing.xl4),
        .init(label: "xl5", value: AppSpacing.xl5),
        .init(label: "xl6", value: AppSpacing.xl6),
    ]
}
