import CoreGraphics

/// Spacing scale per DESIGN_SYSTEM.md §Spacing.
/// Swift identifiers can't start with a digit, so the web "2xl/3xl/..." tokens
/// become `xl2/xl3/...`. Map is one-to-one.
enum AppSpacing {
    // v1 names (kept; do not break call sites)
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

    // v2 step-numbered aliases (Phase 14 — REDESIGN_DESIGN_SYSTEM.md §Spacing).
    // Numbered names make rhythm reasoning easier ("section-to-section is space7").
    // The new `space3` (12pt) is genuinely new; everything else aliases.
    static let space1: CGFloat = 4    // = xs
    static let space2: CGFloat = 8    // = sm
    static let space3: CGFloat = 12   // (new step — between sm and md)
    static let space4: CGFloat = 16   // = md
    static let space5: CGFloat = 24   // = lg
    static let space6: CGFloat = 32   // = xl
    static let space7: CGFloat = 48   // = xl2 — section-to-section breathing room
    static let space8: CGFloat = 64   // = xl3
    static let space9: CGFloat = 96   // = xl4
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

    /// Phase 14: v2 step-numbered tokens for ThemePreview's redesign section.
    static let v2: [AppSpacingToken] = [
        .init(label: "space1", value: AppSpacing.space1),
        .init(label: "space2", value: AppSpacing.space2),
        .init(label: "space3", value: AppSpacing.space3),
        .init(label: "space4", value: AppSpacing.space4),
        .init(label: "space5", value: AppSpacing.space5),
        .init(label: "space6", value: AppSpacing.space6),
        .init(label: "space7", value: AppSpacing.space7),
        .init(label: "space8", value: AppSpacing.space8),
        .init(label: "space9", value: AppSpacing.space9),
    ]
}
