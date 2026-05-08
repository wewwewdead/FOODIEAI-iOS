import CoreGraphics

/// Border radius scale per DESIGN_SYSTEM.md §Border radius.
enum AppRadius {
    static let md:   CGFloat = 10     // Reminder pill, free pop-up, image preview
    static let lg:   CGFloat = 15     // Modal, food-data card, save/cancel
    static let xl:   CGFloat = 16     // .card style — about / education / login
    static let xl2:  CGFloat = 20     // Photo upload zone
    static let pill: CGFloat = 9999   // Sign-up, analyze, "Try for FREE"
}

struct AppRadiusToken: Identifiable {
    let label: String
    let value: CGFloat
    var id: String { label }

    static let all: [AppRadiusToken] = [
        .init(label: "md",   value: AppRadius.md),
        .init(label: "lg",   value: AppRadius.lg),
        .init(label: "xl",   value: AppRadius.xl),
        .init(label: "xl2",  value: AppRadius.xl2),
        .init(label: "pill", value: AppRadius.pill),
    ]
}
