import Foundation

/// Phase 21 — stub for the future subscription system. The actual
/// paywall / IAP / tier-gating ships in a later phase; this file just
/// provides the call sites that need a "scans remaining today" value
/// with a hardcoded answer so the manual-log success banner has
/// something to render.
///
/// When Phase 22 (or later) introduces a real subscription state, this
/// enum's accessors become the single replacement point — every other
/// call site reads through here. Do not inline the literal "2" elsewhere.
enum FreeTierLimits {
    /// Daily AI-scan quota for free-tier users. The number itself is
    /// the contract this phase ships against; the *real* per-day
    /// counter and reset logic land with the subscription system.
    static let scansPerDayFree: Int = 2

    /// Pro-tier daily scan quota. Same caveat — surfaces only in
    /// upgrade copy until Phase 22.
    static let scansPerDayPro: Int = 5

    /// Mocked "scans remaining today" — always returns the full daily
    /// quota until Phase 22 wires it to real usage. The success banner
    /// reads this to decide between "Try a photo scan?" (>0 remaining)
    /// and "Upgrade for 5 photo scans/day" (0 remaining).
    static var scansRemainingToday: Int { scansPerDayFree }
}
