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
    case revelationTimeOfDay
    case revelationMacroLean
    case revelationDayType
    case valueMacroTrend
    case valueCalorieTrend
    case valueConsistency
    case valueVarietyTrend
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
    var revelationRepeatKey: String? {
        guard kind == .revelation else { return nil }
        // Prefer the structured key the engine set at construction; only
        // reverse-engineer it from display copy for moments that didn't
        // supply one (older callers / hand-built test fixtures).
        if let key = authoritativeRepeatKey { return key }
        let joined = [title, body ?? "", evidenceLine ?? ""]
            .joined(separator: " ")
            .lowercased()

        // Value-revelation evidence carries a unique "this week and ...
        // last week" marker; route to value keys first so a value
        // moment mentioning "protein" doesn't get mistagged as the
        // mood macro-lean revelation.
        if isValueRevelationCopy {
            if joined.contains("dropped") || joined.contains("climbed") {
                if joined.contains("protein") { return "macroTrend:protein" }
                if joined.contains("carbs") { return "macroTrend:carbs" }
                if joined.contains("fat") { return "macroTrend:fat" }
            }
            if joined.contains("calories") { return "calorieTrend" }
            if joined.contains("varied") || joined.contains("focused") {
                return "varietyTrend"
            }
            if joined.contains("logged") { return "consistency" }
            return nil
        }

        if joined.contains("morning") { return "timeOfDay:morning" }
        if joined.contains("midday") { return "timeOfDay:midday" }
        if joined.contains("evening") { return "timeOfDay:evening" }

        if joined.contains("protein") { return "macroLean:protein" }
        if joined.contains("carb") { return "macroLean:carb" }
        if joined.contains("balanced") { return "macroLean:balanced" }

        if joined.contains("weekend") { return "dayType:weekend" }
        if joined.contains("weekday") { return "dayType:weekday" }
        return nil
    }

    /// True when this revelation moment was minted by the value-
    /// revelation branch (week-over-week trend). Detected via the
    /// distinctive "this week and N last week" evidence-line pattern
    /// shared by all four value subtypes; mood revelations cite
    /// "mood notes" instead, so the two are unambiguous.
    fileprivate var isValueRevelationCopy: Bool {
        guard let evidence = evidenceLine?.lowercased() else { return false }
        return evidence.contains("this week")
            && evidence.contains("last week")
            && !evidence.contains("mood note")
    }

    /// Deterministic revelation tag from the engine's structured `repeatKey`
    /// (e.g. "timeOfDay:morning", "macroTrend:protein", "calorieTrend"). Mirrors
    /// the copy-based fallback below exactly, just without depending on copy.
    fileprivate static func revelationTag(forRepeatKey key: String) -> FoodOSMomentTag {
        let head = key.split(separator: ":").first.map(String.init) ?? key
        switch head {
        case "timeOfDay":    return .revelationTimeOfDay
        case "macroLean":    return .revelationMacroLean
        case "dayType":      return .revelationDayType
        case "macroTrend":   return .valueMacroTrend
        case "calorieTrend": return .valueCalorieTrend
        case "varietyTrend": return .valueVarietyTrend
        case "consistency":  return .valueConsistency
        default:             return .unknown
        }
    }

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
        case .revelation:
            // Prefer the structured key set at construction over matching the
            // display copy — a copy tweak used to be able to silently re-route
            // feedback to a different learning bucket.
            if let key = authoritativeRepeatKey {
                return Self.revelationTag(forRepeatKey: key)
            }
            let joined = [title, body ?? "", evidenceLine ?? ""]
                .joined(separator: " ")
                .lowercased()
            // Value-revelation copy carries a unique week-over-week
            // evidence marker; route those to value tags first so the
            // mood macro-lean tag isn't claimed by a value moment that
            // happens to mention "protein".
            if isValueRevelationCopy {
                if joined.contains("dropped") || joined.contains("climbed") {
                    return .valueMacroTrend
                }
                if joined.contains("calories") { return .valueCalorieTrend }
                if joined.contains("varied") || joined.contains("focused") {
                    return .valueVarietyTrend
                }
                if joined.contains("logged") { return .valueConsistency }
                return .unknown
            }
            if joined.contains("morning")
                || joined.contains("midday")
                || joined.contains("evening") {
                return .revelationTimeOfDay
            }
            if joined.contains("protein")
                || joined.contains("carb")
                || joined.contains("balanced") {
                return .revelationMacroLean
            }
            if joined.contains("weekday")
                || joined.contains("weekend") {
                return .revelationDayType
            }
            return .unknown
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
    /// always qualify. Recognition qualifies only when the engine has
    /// also produced a renderable action label (e.g. the anchor-meal
    /// prompt), since that's what turns the card from observation into
    /// something a user can opt into.
    static func showsWillTry(for moment: FoodOSMoment) -> Bool {
        switch moment.kind {
        case .nudge, .experiment:
            return true
        case .recognition:
            return FoodOSStoryBuilder.shouldRenderActionLabel(moment)
        case .learning, .change, .celebration, .reflection, .revelation:
            return false
        }
    }
}
