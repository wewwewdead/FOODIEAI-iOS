import UIKit

/// Centralized haptic feedback. Phase 13 motion vocabulary maps each
/// premium-feeling interaction onto a single named call so the cadence
/// is consistent across the app — never `UIImpactFeedbackGenerator()`
/// inline at a call site.
///
/// Generators are kept as static properties (instances live for the
/// process) so the haptic engine doesn't have to allocate one on every
/// tap. `prepare()` may be called speculatively before a known
/// interaction (e.g., when `.ready` is reached, prepare for the eventual
/// save tap) to warm the engine.
///
/// On the simulator there is no Taptic Engine, so the methods do nothing
/// at runtime — the DEBUG `NSLog` line is the only indication a call
/// fired. Test on a real device when validating cadence.
enum Haptics {
    private static let lightImpact  = UIImpactFeedbackGenerator(style: .light)
    private static let softImpact   = UIImpactFeedbackGenerator(style: .soft)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Light tactile tap. Use for: row tap, photo pick, button press,
    /// thumbnail-to-viewer tap.
    static func tap() {
        #if DEBUG
        NSLog("[Haptics] tap")
        #endif
        lightImpact.impactOccurred()
    }

    /// Selection change. Use for: segment switch, calendar day cell,
    /// stepper increment.
    static func selection() {
        #if DEBUG
        NSLog("[Haptics] selection")
        #endif
        selectionGen.selectionChanged()
    }

    /// Soft impact. Use for: section expand/collapse, sheet present.
    static func soft() {
        #if DEBUG
        NSLog("[Haptics] soft")
        #endif
        softImpact.impactOccurred()
    }

    /// Success notification (di-doo). Use for: meal saved,
    /// profile updated, sign-in success.
    static func success() {
        #if DEBUG
        NSLog("[Haptics] success")
        #endif
        notification.notificationOccurred(.success)
    }

    /// Warning notification. Use for: no-food state arrival, validation.
    static func warning() {
        #if DEBUG
        NSLog("[Haptics] warning")
        #endif
        notification.notificationOccurred(.warning)
    }

    /// Error notification. Use for: save failure, network failure.
    static func error() {
        #if DEBUG
        NSLog("[Haptics] error")
        #endif
        notification.notificationOccurred(.error)
    }

    /// Pre-warm the haptic engine. Cheap; safe to call multiple times.
    /// Optional optimization — most call sites don't need it.
    static func prepare() {
        lightImpact.prepare()
        softImpact.prepare()
        mediumImpact.prepare()
        selectionGen.prepare()
        notification.prepare()
    }
}
