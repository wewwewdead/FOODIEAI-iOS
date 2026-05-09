import Foundation

/// Mirrors public.food_logs (read shape — what comes back from a SELECT).
struct FoodLog: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let foodName: String
    let imagePath: String?
    /// Phase 12: small (256px / ~10–25 KB) sibling JPEG used by list/grid
    /// thumbnails. NULL for pre-Phase-12 rows; readers fall back to
    /// `imagePath` for those rows.
    let imageThumbPath: String?
    let calories: Double
    let carbsG: Double
    let sugarG: Double
    let proteinG: Double?
    let fatG: Double?
    let fiberG: Double?
    let benefits: [String]
    let drawbacks: [String]
    let nutrients: [String]
    let coachName: String?
    let coachAdvice: String?
    let eatenAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case foodName       = "food_name"
        case imagePath      = "image_path"
        case imageThumbPath = "image_thumb_path"
        case calories
        case carbsG         = "carbs_g"
        case sugarG         = "sugar_g"
        case proteinG       = "protein_g"
        case fatG           = "fat_g"
        case fiberG         = "fiber_g"
        case benefits, drawbacks, nutrients
        case coachName      = "coach_name"
        case coachAdvice    = "coach_advice"
        case eatenAt        = "eaten_at"
        case createdAt      = "created_at"
    }
}

/// Insert shape — note: NO user_id. Postgres default `auth.uid()` fills it
/// and the food_logs_insert_own RLS policy enforces the match.
struct NewFoodLog: Encodable {
    let foodName: String
    let imagePath: String?
    /// Phase 12: paired thumbnail path. NULL only if the caller skipped the
    /// thumbnail upload (shouldn't happen on the standard save path).
    let imageThumbPath: String?
    let calories: Double
    let carbsG: Double
    let sugarG: Double
    let proteinG: Double?
    let fatG: Double?
    let fiberG: Double?
    let benefits: [String]
    let drawbacks: [String]
    let nutrients: [String]
    let coachName: String?
    let coachAdvice: String?

    enum CodingKeys: String, CodingKey {
        case foodName       = "food_name"
        case imagePath      = "image_path"
        case imageThumbPath = "image_thumb_path"
        case calories
        case carbsG         = "carbs_g"
        case sugarG         = "sugar_g"
        case proteinG       = "protein_g"
        case fatG           = "fat_g"
        case fiberG         = "fiber_g"
        case benefits, drawbacks, nutrients
        case coachName      = "coach_name"
        case coachAdvice    = "coach_advice"
    }
}
