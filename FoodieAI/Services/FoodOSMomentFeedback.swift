import Foundation

// MARK: - FoodOSMomentTag
//
// Coarse "what kind of nudge is this" taxonomy used by the local
// feedback loop. The bandit aggregates feedback per tag — a single
// .lighterDinner tag covers every refresh that produced "Try keeping
// dinner lighter" even though each refresh is a distinct moment.
//
// Tags are deliberately broader than `FoodOSMoment.Kind` so the
// learner can collect enough evidence per bucket without slicing it
// across too many shapes.

/// Stable, codable tag for grouping feedback across moment refreshes.
/// New cases should be added to the end; existing rawValues must stay
/// stable so on-disk preference rows survive future versions.
enum FoodOSMomentTag: String, Codable, CaseIterable, Equatable {
    case proteinPairing
    case lighterDinner
    case repeatReliableMeal
    case moodReflection
    case consistency
    case weeklyChange
    case genericReflection
    case unknown
}

// MARK: - FoodOSMomentFeedback
//
// What the user told us about one specific moment. Three calm
// surfaces: helpful / notUseful / willTry. No 5-star scale, no free
// text — V1 only needs directional signal.

enum FoodOSMomentFeedback: String, Codable, CaseIterable, Equatable {
    case helpful
    case notUseful
    case willTry
}

// MARK: - FoodOSMomentFeedbackEvent
//
// One feedback tap, captured as an append-only log row. We keep the
// moment's kind + title + tag so future versions can re-derive richer
// aggregates without altering the schema. Local only.

struct FoodOSMomentFeedbackEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let momentKind: String
    let momentTitle: String
    let feedback: FoodOSMomentFeedback
    let momentTag: FoodOSMomentTag
    let createdAt: Date

    init(id: UUID = UUID(),
         momentKind: String,
         momentTitle: String,
         feedback: FoodOSMomentFeedback,
         momentTag: FoodOSMomentTag,
         createdAt: Date = Date()) {
        self.id = id
        self.momentKind = momentKind
        self.momentTitle = momentTitle
        self.feedback = feedback
        self.momentTag = momentTag
        self.createdAt = createdAt
    }
}

// MARK: - FoodOSMomentPreference
//
// Per-tag rolled-up evidence. Updated incrementally as events arrive
// so the bandit can score adjustments without rescanning history.

struct FoodOSMomentPreference: Codable, Equatable {
    enum Confidence: String, Codable, Equatable {
        case low, medium, high
    }

    let tag: FoodOSMomentTag
    var shownCount: Int
    var helpfulCount: Int
    var notUsefulCount: Int
    var willTryCount: Int
    /// Reserved for V2 — flips once mood-pulse-after-try tracking
    /// lands. Carried in the schema now so on-disk rows don't need
    /// migration later.
    var positiveMoodAfterTryCount: Int
    var negativeMoodAfterTryCount: Int
    /// `alpha / (alpha + beta)` where alpha and beta are formed from
    /// the counts above plus a Beta(1, 1) prior. Recomputed on every
    /// mutation so callers can read a fresh value without an extra
    /// computation step.
    var posteriorMean: Double
    var confidence: Confidence

    init(tag: FoodOSMomentTag,
         shownCount: Int = 0,
         helpfulCount: Int = 0,
         notUsefulCount: Int = 0,
         willTryCount: Int = 0,
         positiveMoodAfterTryCount: Int = 0,
         negativeMoodAfterTryCount: Int = 0) {
        self.tag = tag
        self.shownCount = shownCount
        self.helpfulCount = helpfulCount
        self.notUsefulCount = notUsefulCount
        self.willTryCount = willTryCount
        self.positiveMoodAfterTryCount = positiveMoodAfterTryCount
        self.negativeMoodAfterTryCount = negativeMoodAfterTryCount
        self.posteriorMean = FoodOSMomentPreference.computePosteriorMean(
            helpful: helpfulCount,
            willTry: willTryCount,
            positiveMood: positiveMoodAfterTryCount,
            notUseful: notUsefulCount,
            negativeMood: negativeMoodAfterTryCount
        )
        self.confidence = FoodOSMomentPreference.computeConfidence(
            shownCount: shownCount
        )
    }

    /// Re-derive `posteriorMean` and `confidence` from the current
    /// counts. Called after every increment so the rolled-up fields
    /// stay aligned with the raw counters.
    mutating func recomputeDerived() {
        posteriorMean = FoodOSMomentPreference.computePosteriorMean(
            helpful: helpfulCount,
            willTry: willTryCount,
            positiveMood: positiveMoodAfterTryCount,
            notUseful: notUsefulCount,
            negativeMood: negativeMoodAfterTryCount
        )
        confidence = FoodOSMomentPreference.computeConfidence(
            shownCount: shownCount
        )
    }

    static func computePosteriorMean(helpful: Int,
                                     willTry: Int,
                                     positiveMood: Int,
                                     notUseful: Int,
                                     negativeMood: Int) -> Double {
        let alpha = Double(helpful + willTry + positiveMood + 1)
        let beta  = Double(notUseful + negativeMood + 1)
        return alpha / (alpha + beta)
    }

    static func computeConfidence(shownCount: Int) -> Confidence {
        if shownCount < 3 { return .low }
        if shownCount <= 7 { return .medium }
        return .high
    }
}

// MARK: - FoodOSMoment → tag derivation
//
// The engine itself never sets a tag; the view-model and tests derive
// it from the moment shape. This keeps `FoodOSMoment` free of bandit
// concepts and lets us evolve tag mapping without re-running the
// engine.

extension FoodOSMoment {
    /// Stable tag for this moment shape. Used by the feedback store
    /// to bucket events and by the bandit to score priority
    /// adjustments. Pure — no I/O, no side effects.
    var momentTag: FoodOSMomentTag {
        switch kind {
        case .celebration:
            return .consistency
        case .change:
            return .weeklyChange
        case .recognition:
            return .repeatReliableMeal
        case .nudge:
            // The current nudge branch is always the "lighter dinner"
            // shape; a body mention of "protein" routes a future
            // protein-pairing nudge to its own bucket.
            let body = (body ?? "").lowercased()
            if body.contains("protein") { return .proteinPairing }
            return .lighterDinner
        case .reflection:
            // Mood-driven reflection cites "mood note(s)"; the
            // gentle fallback cites meals. Routing on evidenceLine
            // keeps the rule local and easy to test.
            let evidence = (evidenceLine ?? "").lowercased()
            if evidence.contains("mood note") { return .moodReflection }
            return .genericReflection
        case .learning, .experiment:
            return .unknown
        }
    }
}

// MARK: - FoodOSMomentFeedbackPolicy
//
// Pure decisions about *which* feedback affordances the UI should
// surface for a given moment. Kept out of the SwiftUI view so tests
// can assert the rules without bringing UI infrastructure into the
// test target.

enum FoodOSMomentFeedbackPolicy {
    /// Helpful / Not useful chips: visible on every kind except
    /// learning. Learning moments already have a "Keep logging" CTA
    /// — adding feedback there would feel like critique of the data
    /// the user hasn't yet produced.
    static func showsControls(for moment: FoodOSMoment) -> Bool {
        moment.kind != .learning
    }

    /// "I'll try this" is a forward-looking promise — only meaningful
    /// on moments that actually prompt an action. Nudge + experiment
    /// qualify; reflections and recognitions do not.
    static func showsWillTry(for moment: FoodOSMoment) -> Bool {
        moment.kind == .nudge || moment.kind == .experiment
    }
}
