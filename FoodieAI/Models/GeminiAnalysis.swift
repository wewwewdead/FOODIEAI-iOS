import Foundation

/// Decoded body of a successful POST /analyze response.
///
/// Every field is optional because Gemini's structured-output mode isn't
/// strictly enforced server-side — `routes/gemini.js` defensively returns
/// partial objects on malformed Gemini responses, and the no-food path
/// returns `{ fallback: "..." }` with everything else absent. Use
/// `hasFood` to gate result UI.
struct GeminiAnalysis: Codable, Hashable {
    let fallback: String?
    let food: String?
    let calories: Double?
    let carbs: Double?
    let sugar: Double?
    /// Phase 11: requested from Gemini in grams. Optional because pre-Phase-11
    /// server builds (and any partial Gemini output) won't include them.
    let protein: Double?
    let fat: Double?
    let fiber: Double?
    let benefits: [String]?
    let drawbacks: [String]?
    let nutrients: [String]?
    let coachAdvice: String?
    /// Quantity Clarification — items in the image where the visible
    /// portion cannot determine the actual quantity (rice, noodles,
    /// soup, drinks in opaque containers, etc.). Nullable because
    /// pre-clarification servers won't return the field. Empty array
    /// means "all portions are visually determinable" — no follow-up
    /// needed.
    let portionAmbiguousItems: [AmbiguousItem]?
    /// Uncertainty-aware naming. "high" | "medium" | "low". Nullable
    /// so older server builds (and partial Gemini outputs) decode
    /// cleanly — treat nil/unknown as effectively "high" (no friction).
    let nameConfidence: String?
    /// Alternative dish names the model considered when confidence is
    /// "low" or "medium". Empty/nil on high-confidence scans. Most
    /// likely first — the UI renders them as tappable chips.
    let nameAlternatives: [String]?

    /// Quantity Clarification — one row in `portionAmbiguousItems`.
    /// Hashable + Identifiable so the clarification sheet can iterate
    /// over the list directly. `id` uses the name since the server
    /// guarantees at most one entry per food name within a single
    /// response.
    struct AmbiguousItem: Codable, Hashable, Identifiable {
        let name: String
        let assumedQuantity: String
        var id: String { name }
    }

    /// True when Gemini detected food. The server emits an *empty-string*
    /// `fallback` (not null) on the success path because Gemini's structured
    /// output always populates the field; the no-food branch in
    /// `routes/gemini.js` returns ONLY `{ fallback: "<message>" }` and omits
    /// every other field. So "has food" = "no non-empty fallback".
    var hasFood: Bool {
        let fb = fallback ?? ""
        return fb.isEmpty && food != nil
    }

    /// Surface the suggestion UI when the model expressed uncertainty
    /// — either an explicit low/medium confidence label, or simply by
    /// returning a non-empty alternatives list. Treats nil/unknown
    /// confidence as confident so pre-feature servers stay friction-free.
    var isNameUncertain: Bool {
        let label = (nameConfidence ?? "").lowercased()
        if label == "low" || label == "medium" { return true }
        if let alts = nameAlternatives, !alts.isEmpty { return true }
        return false
    }
}

/// Top-level shape returned by /analyze: `{ analysis, coach }`.
struct AnalyzeResponse: Codable, Hashable {
    let analysis: GeminiAnalysis
    let coach: String?
}
