import Foundation

/// Phase 23 — the Vault. Read shape of `public.vault_items`: a durable,
/// user-curated snapshot of a food's analysis + photo, kept so the user
/// can re-log a meal they eat often without scanning it again.
///
/// The analysis columns mirror `food_logs` 1:1 (see `FoodLog`), so
/// `newFoodLogForRelog()` rebuilds a `NewFoodLog` from a vault item with
/// a direct field copy. Re-logging reuses the same Storage image paths —
/// no re-upload — exactly like Quick Re-log (`CaptureViewModel.relog`).
struct SavedFood: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let foodName: String
    let imagePath: String?
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
    /// The `food_logs` row this was saved from, when there was one.
    /// Nullable: saved-from-result items have no source row, and the FK
    /// is ON DELETE SET NULL so the vault item outlives a deleted log.
    let sourceLogId: UUID?
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
        case sourceLogId    = "source_log_id"
        case createdAt      = "created_at"
    }

    /// A `FoodLog`-shaped view of this vault item, for display-only reuse
    /// of the meal components (`MealMacroGrid`, etc.) in the Vault detail
    /// screen. Synthesizes the log-only fields: `eatenAt`/`createdAt` from
    /// the vault `createdAt`, `origin` `.relogged`, `mood` nil. Never
    /// inserted — purely a rendering adapter.
    var asFoodLog: FoodLog {
        FoodLog(
            id: id,
            userId: userId,
            foodName: foodName,
            imagePath: imagePath,
            imageThumbPath: imageThumbPath,
            calories: calories,
            carbsG: carbsG,
            sugarG: sugarG,
            proteinG: proteinG,
            fatG: fatG,
            fiberG: fiberG,
            benefits: benefits,
            drawbacks: drawbacks,
            nutrients: nutrients,
            coachName: coachName,
            coachAdvice: coachAdvice,
            eatenAt: createdAt,
            createdAt: createdAt,
            origin: .relogged,
            sourceLogId: sourceLogId,
            mood: nil
        )
    }

    /// Build a `NewFoodLog` that re-logs this vault item into today.
    /// Mirrors `CaptureViewModel.relog(_:)`: origin `.relogged`, reuses
    /// the stored image paths (no re-upload), and carries `sourceLogId`
    /// through so the re-log still points back at the original analyzed
    /// row when it still exists.
    func newFoodLogForRelog() -> NewFoodLog {
        NewFoodLog(
            foodName:       foodName,
            imagePath:      imagePath,
            imageThumbPath: imageThumbPath,
            calories:       calories,
            carbsG:         carbsG,
            sugarG:         sugarG,
            proteinG:       proteinG,
            fatG:           fatG,
            fiberG:         fiberG,
            benefits:       benefits,
            drawbacks:      drawbacks,
            nutrients:      nutrients,
            coachName:      coachName,
            coachAdvice:    coachAdvice,
            origin:         .relogged,
            sourceLogId:    sourceLogId
        )
    }
}

/// Insert shape for `public.vault_items`. No `user_id` (DB default
/// `auth.uid()` + RLS fill it); no `id` / `created_at` (DB-generated).
struct NewVaultItem: Encodable {
    let foodName: String
    let imagePath: String?
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
    let sourceLogId: UUID?

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
        case sourceLogId    = "source_log_id"
    }
}

extension NewVaultItem {
    /// Snapshot an existing saved meal (a `food_logs` row) into a vault
    /// item. Copies the analysis payload verbatim and points
    /// `source_log_id` back at the origin row. Zero image work — the
    /// Storage objects are shared, exactly like Quick Re-log.
    init(from log: FoodLog) {
        self.init(
            foodName:       log.foodName,
            imagePath:      log.imagePath,
            imageThumbPath: log.imageThumbPath,
            calories:       log.calories,
            carbsG:         log.carbsG,
            sugarG:         log.sugarG,
            proteinG:       log.proteinG,
            fatG:           log.fatG,
            fiberG:         log.fiberG,
            benefits:       log.benefits,
            drawbacks:      log.drawbacks,
            nutrients:      log.nutrients,
            coachName:      log.coachName,
            coachAdvice:    log.coachAdvice,
            sourceLogId:    log.id
        )
    }
}
