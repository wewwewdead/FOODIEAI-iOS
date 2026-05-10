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
    /// Phase 15: how this row was created. Pre-Phase-15 rows decode as
    /// `.analyzed` via the migration's column default.
    let origin: Origin
    /// Phase 15: when `origin == .relogged`, points at the row whose
    /// analysis was copied. Nullable because the source can be deleted
    /// (ON DELETE SET NULL) and because `.analyzed` rows never set it.
    let sourceLogId: UUID?
    /// Phase 18: the user's post-save reaction. NULL when the row predates
    /// Phase 18, when the post-save pulse was dismissed without answering,
    /// or when the user later cleared their answer. Set via
    /// `FoodLogService.setMood(_:on:)`.
    let mood: Mood?

    /// Phase 15. String-coded so PostgREST round-trips cleanly through
    /// the `text` column with its CHECK constraint.
    enum Origin: String, Codable, Hashable {
        case analyzed
        case relogged
    }

    /// Phase 18. Three deliberately small options — five would dilute
    /// signal. Naming is everyday, not clinical.
    enum Mood: String, Codable, Hashable, CaseIterable {
        case loved
        case fine
        case tough

        /// Display emoji for the post-save pulse and the Profile mood log.
        var emoji: String {
            switch self {
            case .loved: return "💚"
            case .fine:  return "🙂"
            case .tough: return "🌧"
            }
        }

        /// Short label rendered under the emoji button.
        var label: String {
            switch self {
            case .loved: return "Loved it"
            case .fine:  return "It was fine"
            case .tough: return "Tough one"
            }
        }
    }

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
        case origin
        case sourceLogId    = "source_log_id"
        case mood
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
    /// Phase 15. Defaults to `.analyzed` so the existing Capture →
    /// Analyze → Save path doesn't need to change. The Quick Re-log path
    /// passes `.relogged` + a non-nil `sourceLogId`. Sent explicitly even
    /// though the DB has the same default — makes intent visible at the
    /// call site.
    let origin: FoodLog.Origin
    let sourceLogId: UUID?

    init(foodName: String,
         imagePath: String?,
         imageThumbPath: String?,
         calories: Double,
         carbsG: Double,
         sugarG: Double,
         proteinG: Double?,
         fatG: Double?,
         fiberG: Double?,
         benefits: [String],
         drawbacks: [String],
         nutrients: [String],
         coachName: String?,
         coachAdvice: String?,
         origin: FoodLog.Origin = .analyzed,
         sourceLogId: UUID? = nil) {
        self.foodName       = foodName
        self.imagePath      = imagePath
        self.imageThumbPath = imageThumbPath
        self.calories       = calories
        self.carbsG         = carbsG
        self.sugarG         = sugarG
        self.proteinG       = proteinG
        self.fatG           = fatG
        self.fiberG         = fiberG
        self.benefits       = benefits
        self.drawbacks      = drawbacks
        self.nutrients      = nutrients
        self.coachName      = coachName
        self.coachAdvice    = coachAdvice
        self.origin         = origin
        self.sourceLogId    = sourceLogId
    }

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
        case origin
        case sourceLogId    = "source_log_id"
    }
}
