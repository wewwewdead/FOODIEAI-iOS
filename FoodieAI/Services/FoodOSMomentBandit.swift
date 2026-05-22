import Foundation

// MARK: - FoodOSMomentBandit
//
// Tiny Beta-Binomial-style scorer that turns a set of per-tag
// preferences into a small, bounded adjustment on the moment
// engine's `priorityScore`. V1 keeps the bandit deliberately
// conservative — adjustments only fire at high confidence, and the
// magnitude (±10) is small enough to nudge tie-prone scores without
// fully overriding the engine's priority chain.
//
// Pure value computation. Never mutates, never persists.

enum FoodOSMomentBandit {

    /// Score adjustment magnitude. Picked so it can flip a moment
    /// from one priority tier to the adjacent one (engine uses 10-pt
    /// steps between branches) but never leapfrog two tiers.
    static let adjustmentMagnitude: Double = 10

    /// Posterior thresholds. Tighter than the usual 0.5 split so a
    /// noisy split sample (5 helpful + 5 notUseful → posterior 0.5)
    /// doesn't accidentally trigger boost or suppression — the
    /// confidence gate already filters most of those, the threshold
    /// catches the rest.
    static let positiveThreshold: Double = 0.65
    static let negativeThreshold: Double = 0.35

    /// Map a preference row to a score adjustment.
    ///
    ///  - `.low` / `.medium` confidence → 0 (no opinion, leave the
    ///    engine alone).
    ///  - high confidence + posterior ≥ 0.65 → +10 (boost matching
    ///    tag).
    ///  - high confidence + posterior ≤ 0.35 → -10 (suppress).
    ///  - high confidence but middling posterior → 0 (we have data,
    ///    but it doesn't clearly favor either direction).
    static func adjustment(for preference: FoodOSMomentPreference) -> Double {
        guard preference.confidence == .high else { return 0 }
        if preference.posteriorMean >= positiveThreshold {
            return  adjustmentMagnitude
        }
        if preference.posteriorMean <= negativeThreshold {
            return -adjustmentMagnitude
        }
        return 0
    }

    /// Convenience over a tag + a flat preference array. Returns 0
    /// when no preference exists for the tag — V1's "we've never
    /// seen this tag" default is to leave the engine untouched.
    static func adjustment(for tag: FoodOSMomentTag,
                           in preferences: [FoodOSMomentPreference]) -> Double {
        guard let match = preferences.first(where: { $0.tag == tag }) else {
            return 0
        }
        return adjustment(for: match)
    }
}
