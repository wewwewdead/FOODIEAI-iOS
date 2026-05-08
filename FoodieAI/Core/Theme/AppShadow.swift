import SwiftUI

/// Shadow scale per DESIGN_SYSTEM.md §Shadows.
///
/// Web uses CSS `filter: drop-shadow(...)` and `box-shadow:` with up to two
/// layered shadows. SwiftUI represents this as one or more `.shadow(...)`
/// modifiers stacked on the same view; they composite the same way.
struct AppShadowLayer: Hashable {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum AppShadow: String, CaseIterable, Identifiable {
    case nav, card, cardHover, image, upload

    var id: String { rawValue }

    var layers: [AppShadowLayer] {
        switch self {
        case .nav:
            // 1px 1px 0 rgba(66, 70, 24, 0.094)
            [.init(color: Color(red: 66/255, green: 70/255, blue: 24/255).opacity(0.094),
                   radius: 0, x: 1, y: 1)]
        case .card:
            // rgba(50,50,93,0.25) 0 2 5 -1, rgba(0,0,0,0.3) 0 1 3 -1
            [.init(color: Color(red: 50/255, green: 50/255, blue: 93/255).opacity(0.25),
                   radius: 5, x: 0, y: 2),
             .init(color: .black.opacity(0.30),
                   radius: 3, x: 0, y: 1)]
        case .cardHover:
            // rgba(50,50,93,0.35) 0 4 10 -2, rgba(0,0,0,0.4) 0 2 6 -2
            [.init(color: Color(red: 50/255, green: 50/255, blue: 93/255).opacity(0.35),
                   radius: 10, x: 0, y: 4),
             .init(color: .black.opacity(0.40),
                   radius: 6,  x: 0, y: 2)]
        case .image:
            // 2 2 2 rgba(34, 0, 0, 0.413)
            [.init(color: Color(red: 34/255, green: 0, blue: 0).opacity(0.413),
                   radius: 2, x: 2, y: 2)]
        case .upload:
            // rgba(50,50,93,0.25) 0 13 27 -5, rgba(0,0,0,0.3) 0 8 16 -8
            [.init(color: Color(red: 50/255, green: 50/255, blue: 93/255).opacity(0.25),
                   radius: 27, x: 0, y: 13),
             .init(color: .black.opacity(0.30),
                   radius: 16, x: 0, y: 8)]
        }
    }
}

extension View {
    /// Applies one or more shadow layers in declaration order. Stacked
    /// `.shadow` modifiers composite so subsequent shadows render *above*
    /// the earlier shadows of the underlying view — same order as CSS
    /// `box-shadow: A, B` (A is outer, B is closer to the surface).
    func appShadow(_ token: AppShadow) -> some View {
        token.layers.reduce(AnyView(self)) { acc, layer in
            AnyView(acc.shadow(color: layer.color,
                               radius: layer.radius,
                               x: layer.x,
                               y: layer.y))
        }
    }
}
