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
    let benefits: [String]?
    let drawbacks: [String]?
    let nutrients: [String]?
    let coachAdvice: String?

    /// True when Gemini detected food. The server emits an *empty-string*
    /// `fallback` (not null) on the success path because Gemini's structured
    /// output always populates the field; the no-food branch in
    /// `routes/gemini.js` returns ONLY `{ fallback: "<message>" }` and omits
    /// every other field. So "has food" = "no non-empty fallback".
    var hasFood: Bool {
        let fb = fallback ?? ""
        return fb.isEmpty && food != nil
    }
}

/// Top-level shape returned by /analyze: `{ analysis, coach }`.
struct AnalyzeResponse: Codable, Hashable {
    let analysis: GeminiAnalysis
    let coach: String?
}
