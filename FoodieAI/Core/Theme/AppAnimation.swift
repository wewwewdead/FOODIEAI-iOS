import SwiftUI

/// Animation tokens shared across press states in Core/Components.
extension Animation {
    /// Standard press response — used for PillButton lift, BrandCard
    /// translateY, CircleActionButton scale, DashedDropZone overlay fade.
    static let appPress: Animation = .spring(response: 0.3, dampingFraction: 0.7)
}
