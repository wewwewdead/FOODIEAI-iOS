import SwiftUI

/// Premium-polish wave: the unified tactile press style.
///
/// One ButtonStyle that orchestrates three signals on press:
///   1. Subtle scale-down (default 0.97, tunable per call site)
///   2. Brand-soft tint wash on the pressed surface
///   3. A short, soft haptic on the press *down* edge (gives the
///      gesture a felt moment before the action resolves)
///
/// The combination reads as "the surface receives the touch" — closer
/// to how iOS 26 system controls feel than a plain scale animation.
///
/// Use this on any tappable surface that doesn't already have its own
/// press choreography: EditorialQuote, CategoryAccordion header,
/// SpeechBubble, MealCard thumbnail, profile nav rows.
///
/// Respects Reduce Motion: drops the scale animation and shortens the
/// haptic; the tint wash still fires so the user gets visual confirmation.
struct MorphingPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var tintsOnPress: Bool = true
    var hapticsOnPress: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scaleValue(pressed: configuration.isPressed))
            .overlay(
                tintsOnPress && configuration.isPressed
                    ? Color.brand.opacity(0.08)
                    : Color.clear
            )
            .animation(reduceMotion ? .appReduced : .appPress, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard hapticsOnPress, pressed else { return }
                Haptics.soft()
            }
    }

    private func scaleValue(pressed: Bool) -> CGFloat {
        guard pressed else { return 1.0 }
        return reduceMotion ? 0.995 : scale
    }
}

extension ButtonStyle where Self == MorphingPressStyle {
    /// Default tactile press. Equivalent to `MorphingPressStyle()`.
    static var morphing: MorphingPressStyle { MorphingPressStyle() }

    /// Tighter press — for small targets like icon chips or pill rows
    /// where a 0.97 scale reads as too much travel.
    static var morphingTight: MorphingPressStyle {
        MorphingPressStyle(scale: 0.985, tintsOnPress: false)
    }

    /// Quiet press — no tint wash, no haptic; just the scale. For
    /// surfaces that already own a tap haptic via `Haptics.tap()` in
    /// the action closure (avoids double-firing).
    static var morphingQuiet: MorphingPressStyle {
        MorphingPressStyle(scale: 0.97, tintsOnPress: false, hapticsOnPress: false)
    }
}
