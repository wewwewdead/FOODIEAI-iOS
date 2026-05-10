import CoreGraphics

/// Border radius scale.
///
/// Phase 14 redesign re-bound the existing tokens to larger values, per
/// REDESIGN_DESIGN_SYSTEM.md §Radius ("Radii are larger throughout than
/// the old system. Premium iOS apps use generous corners — 20–28pt for
/// cards, full pill for buttons.").
///
///   md: 10 → 16   (+6)
///   lg: 15 → 20   (+5)
///   xl: 16 → 24   (+8)
///   xl2: 20 → 28  (+8)
///   sm: 12        (new)
///   pill: 9999    (unchanged)
///
/// v1 components inherit the larger corners as a free polish bump in
/// Tier 1; Tier 3 redesigns introduce v2 components that consume these
/// values explicitly.
enum AppRadius {
    static let sm:   CGFloat = 12     // Phase 14 (new) — macro chips, small inline pills
    static let md:   CGFloat = 16     // Meal card thumbnails (within cards)
    static let lg:   CGFloat = 20     // Cards, accordion rows, sheet pills
    static let xl:   CGFloat = 24     // Photo cards, hero containers
    static let xl2:  CGFloat = 28     // Drop zone, large feature surfaces
    static let pill: CGFloat = 9999   // Buttons, segmented control thumb, status chips
}

struct AppRadiusToken: Identifiable {
    let label: String
    let value: CGFloat
    var id: String { label }

    static let all: [AppRadiusToken] = [
        .init(label: "sm",   value: AppRadius.sm),
        .init(label: "md",   value: AppRadius.md),
        .init(label: "lg",   value: AppRadius.lg),
        .init(label: "xl",   value: AppRadius.xl),
        .init(label: "xl2",  value: AppRadius.xl2),
        .init(label: "pill", value: AppRadius.pill),
    ]
}
