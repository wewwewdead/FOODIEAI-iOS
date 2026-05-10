import SwiftUI

/// Phase 13 motion vocabulary. Every named token maps to a single
/// concrete animation; call sites should reference these by name and
/// never inline `.spring(response:…)` or `.easeOut(duration:…)` with
/// magic numbers — `grep` for those should turn up only this file.
///
/// Brand tone: warm, confident, slightly playful. Springs preferred
/// over linear eases for state changes; eases are acceptable only for
/// entrances and fades. Reference apps for tone: Apple Fitness, Things 3,
/// Streaks. Anti-references: Linear, Notion (too clinical).
///
/// Deliberate exceptions to the "no inline timings" rule:
///   - `TypewriterController.perCharSeconds` — content-driven (20 ms/char
///     per spec), not motion design.
///   - `BouncingBadge` uses its own duration parameter so each style
///     (free/reminder) can tune independently; the underlying curve is
///     conceptually `.appAmbient`.
extension Animation {

    /// Press states: `PillButton` lift, `BrandCard` translate-Y,
    /// `CircleActionButton` scale, `DashedDropZone` overlay fade,
    /// `CalendarCellButtonStyle` scale.
    static let appPress: Animation = .spring(response: 0.3, dampingFraction: 0.7)

    /// First-paint entrances: result-screen sections fading in, sheet
    /// content appearing, day-detail meal stagger. Springy enough to feel
    /// alive, damped enough not to overshoot visibly.
    static let appEntrance: Animation = .spring(response: 0.5, dampingFraction: 0.85)

    /// Confident bounce for completion / success accents: saved-confirmation
    /// checkmark draw-on, panel-fully-typed flourish. Slightly under-damped
    /// so it lands with character.
    static let appPop: Animation = .spring(response: 0.4, dampingFraction: 0.65)

    /// Numeric counter tick. Used by `AnimatedNumber` and any surface that
    /// interpolates a Double. `.easeOut` so the value lands gently rather
    /// than springing past and back.
    static let appNumberTick: Animation = .easeOut(duration: 0.6)

    /// Tracker segment cross-fade and directional slide.
    static let appSegmentSwitch: Animation = .spring(response: 0.4, dampingFraction: 0.85)

    /// Inline expansion: `MealRow` expanded state, day-sheet meal entrance,
    /// `FullImageViewer` overlay grow. The dampingFraction is a touch
    /// looser than `.appEntrance` so reveals feel weighted.
    static let appReveal: Animation = .spring(response: 0.4, dampingFraction: 0.8)

    /// Slow continuous decorative motion. `BouncingBadge` is the canonical
    /// user; empty-state icons reuse this for a subtle bob.
    static let appAmbient: Animation = .easeInOut(duration: 1.6).repeatForever(autoreverses: true)

    // MARK: - v2 (Phase 14 — REDESIGN_DESIGN_SYSTEM.md §Motion)
    //
    // The v2 vocabulary is intentionally smaller than v1's. The previous
    // tokens (`.appPress`/`.appEntrance`/etc.) stay valid for components
    // that haven't migrated; new components reach for these instead.

    /// Tab switches, segment changes, small UI swaps. 0.2s easeOut.
    static let motionQuick: Animation = .easeOut(duration: 0.2)

    /// Sheet presentations, fades, common transitions. 0.3s easeOut.
    static let motionBase: Animation = .easeOut(duration: 0.3)

    /// Content appearances, expansions (accordions, photo entrance).
    /// 0.5s spring with 0.8 damping.
    static let motionReveal: Animation = .spring(response: 0.5, dampingFraction: 0.8)

    /// Hero number reveal on Result screen — count-up from 0 to value.
    /// 0.8s easeOut so the number "lands" with confidence.
    static let motionHero: Animation = .easeOut(duration: 0.8)

    /// Save success choreography — checkmark + radial pulse. 1.2s spring
    /// with 0.65 damping for slight overshoot.
    static let motionCelebration: Animation = .spring(response: 1.2, dampingFraction: 0.65)

    /// "Duolingo-feel" bounce: visibly overshoots its target before settling.
    /// Use for state changes that benefit from a moment of personality —
    /// progress fills, accordion expansions, hero number landings, button
    /// release. Loose damping (0.55) and medium response (0.55s) tuned so
    /// the overshoot is felt but never feels jittery.
    static let appBouncy: Animation = .spring(response: 0.55, dampingFraction: 0.55)

    /// Quick stamp/pop for moments where an element should land with weight —
    /// e.g., hero number scaling 1.0 → 1.06 → 1.0 at the end of its count-up,
    /// or a chip/badge appearing in the user's awareness. Faster than
    /// `.appBouncy`, slightly more under-damped.
    static let appStamp: Animation = .spring(response: 0.35, dampingFraction: 0.5)

    /// Slow, sinusoidal idle motion for "alive" elements — capture-screen
    /// photo placeholder breathing, primary-button gentle attention pulse.
    /// 2.4s period autoreversing easeInOut.
    static let appBreathing: Animation = .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
}
