import SwiftUI

/// Premium-polish wave: shared glass surface helper.
///
/// Wraps iOS 26's `glassEffect(_:in:)` and falls back gracefully to
/// `ultraThinMaterial` on iOS 17–25. The two paths produce visually
/// compatible surfaces — both render a translucent, content-aware
/// material with a hairline border — so a single call-site (e.g.
/// `.liquidGlass(in: Capsule())`) reads consistently across SDK
/// versions without #available pollution at every use.
///
/// Usage:
///   ```swift
///   tabBar
///       .liquidGlass(in: Capsule(), tint: .brand)
///   ```
///
/// The optional `tint` washes the surface with a brand color at low
/// opacity, giving the glass a subtle character without darkening the
/// content it floats above. Pass `.clear` (or omit) for a neutral pane.
extension View {
    /// Applies a Liquid-Glass surface (iOS 26+) or ultraThinMaterial
    /// fallback (iOS 17–25) clipped to `shape`.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(
        in shape: S,
        tint: Color = .clear,
        strokeOpacity: Double = 0.18
    ) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background {
                    shape
                        .fill(tint.opacity(0.10))
                        .glassEffect(in: shape)
                }
                .overlay(shape.strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 0.6))
        } else {
            self
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(tint.opacity(0.10)))
                }
                .overlay(shape.strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 0.6))
        }
    }

    /// Variant that returns the glass as the entire `.background` —
    /// useful when the caller wants to layer additional foreground
    /// elements (e.g., an indicator) atop the same shape.
    @ViewBuilder
    func liquidGlassBackground<S: InsettableShape>(
        _ shape: S,
        tint: Color = .clear
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.background {
                shape
                    .fill(tint.opacity(0.10))
                    .glassEffect(in: shape)
            }
        } else {
            self.background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(tint.opacity(0.10)))
            }
        }
    }
}
