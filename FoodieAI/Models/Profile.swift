import Foundation

/// Mirrors public.profiles
struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String?
    var avatarUrl: String?
    var dailyCalorieGoal: Int
    var dailyCarbGoalG: Int
    var dailySugarGoalG: Int
    var dailyProteinGoalG: Int
    var dailyFatGoalG: Int
    var dailyFiberGoalG: Int
    /// Phase 16. Coach names the user has starred, in preference order
    /// (first = most preferred). Empty array = no preference; the
    /// rotation falls back to uniform random over the canonical pool.
    var preferredCoaches: [String]
    /// Phase 17. Master notification gate. Defaults to false so
    /// existing accounts don't get surprise nudges; the user opts in
    /// via the permission flow.
    var notificationsEnabled: Bool
    var reminderBreakfast: Bool
    var reminderLunch: Bool
    var reminderDinner: Bool
    var weeklyRecapEnabled: Bool
    /// Phase 17. IANA timezone identifier ("Asia/Seoul"). Captured by
    /// the client on auth bootstrap and re-synced when it changes.
    /// Used for reminder scheduling and recap week boundaries.
    var timeZone: String?
    /// Phase 19. NULL means the user has not yet completed v2 onboarding;
    /// non-NULL gates RootView straight into MainTabView.
    var onboardingCompletedAt: Date?
    /// Phase 19. The user's answer to the goal-framing question.
    /// Persisted for future personalization (empty states, coach bias).
    var onboardingArchetype: Archetype?
    /// Phase 20. Optional physiology inputs used by
    /// `CalorieGoalCalculator` to derive personalized targets. NULL
    /// means the user hasn't gone through the personalization flow —
    /// the existing archetype-based defaults still apply.
    var biologicalSex: CalorieGoalCalculator.BiologicalSex?
    var ageYears: Int?
    var heightCm: Double?
    var weightKg: Double?
    var activityLevel: CalorieGoalCalculator.ActivityLevel?
    var weightGoalDirection: CalorieGoalCalculator.GoalDirection?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName            = "display_name"
        case avatarUrl              = "avatar_url"
        case dailyCalorieGoal       = "daily_calorie_goal"
        case dailyCarbGoalG         = "daily_carb_goal_g"
        case dailySugarGoalG        = "daily_sugar_goal_g"
        case dailyProteinGoalG      = "daily_protein_goal_g"
        case dailyFatGoalG          = "daily_fat_goal_g"
        case dailyFiberGoalG        = "daily_fiber_goal_g"
        case preferredCoaches       = "preferred_coaches"
        case notificationsEnabled   = "notifications_enabled"
        case reminderBreakfast      = "reminder_breakfast"
        case reminderLunch          = "reminder_lunch"
        case reminderDinner         = "reminder_dinner"
        case weeklyRecapEnabled     = "weekly_recap_enabled"
        case timeZone               = "time_zone"
        case onboardingCompletedAt  = "onboarding_completed_at"
        case onboardingArchetype    = "onboarding_archetype"
        case biologicalSex          = "biological_sex"
        case ageYears               = "age_years"
        case heightCm               = "height_cm"
        case weightKg               = "weight_kg"
        case activityLevel          = "activity_level"
        case weightGoalDirection    = "weight_goal_direction"
        case createdAt              = "created_at"
        case updatedAt              = "updated_at"
    }

    /// Phase 19. Goal-framing answer. Non-clinical labels on purpose:
    /// "Be more aware" / "Lose weight" / "Build muscle" / "Just curious"
    /// rather than weight_loss/weight_gain framings that sound prescriptive.
    enum Archetype: String, Codable, CaseIterable, Hashable {
        case aware        = "aware"
        case loseWeight   = "lose_weight"
        case buildMuscle  = "build_muscle"
        case curious      = "curious"

        var displayLabel: String {
            switch self {
            case .aware:       "Be more aware"
            case .loseWeight:  "Lose some weight"
            case .buildMuscle: "Build muscle"
            case .curious:     "Just curious"
            }
        }

        /// SF Symbol name used as the row's leading glyph. Emoji would
        /// scale with Dynamic Type unevenly across platforms; SF Symbols
        /// stay aligned with the text baseline.
        var symbolName: String {
            switch self {
            case .aware:       "sparkles"
            case .loseWeight:  "scope"
            case .buildMuscle: "figure.strengthtraining.traditional"
            case .curious:     "questionmark.bubble"
            }
        }

        /// Default macro goals seeded when the user picks (or skips to)
        /// this archetype. Conservative starting points the user can
        /// adjust later in Profile. Tuple order: calories, carbs, sugar.
        var defaultGoals: (calories: Int, carbs: Int, sugar: Int) {
            switch self {
            case .aware:        (2000, 250, 50)
            case .loseWeight:   (1700, 200, 35)
            case .buildMuscle:  (2400, 280, 60)
            case .curious:      (2000, 250, 50)
            }
        }
    }

    // Backwards-compatible decoding: rows from a project that hasn't run
    // migrations 003 / 005 / 006 yet won't have the corresponding
    // columns. Decode with the same defaults the schema uses, so the
    // app keeps working before the migrations land.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        dailyCalorieGoal  = try c.decode(Int.self, forKey: .dailyCalorieGoal)
        dailyCarbGoalG    = try c.decode(Int.self, forKey: .dailyCarbGoalG)
        dailySugarGoalG   = try c.decode(Int.self, forKey: .dailySugarGoalG)
        dailyProteinGoalG = try c.decodeIfPresent(Int.self, forKey: .dailyProteinGoalG) ?? 90
        dailyFatGoalG     = try c.decodeIfPresent(Int.self, forKey: .dailyFatGoalG) ?? 70
        dailyFiberGoalG   = try c.decodeIfPresent(Int.self, forKey: .dailyFiberGoalG) ?? 28
        preferredCoaches  = try c.decodeIfPresent([String].self, forKey: .preferredCoaches) ?? []
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        reminderBreakfast    = try c.decodeIfPresent(Bool.self, forKey: .reminderBreakfast) ?? true
        reminderLunch        = try c.decodeIfPresent(Bool.self, forKey: .reminderLunch) ?? true
        reminderDinner       = try c.decodeIfPresent(Bool.self, forKey: .reminderDinner) ?? true
        weeklyRecapEnabled   = try c.decodeIfPresent(Bool.self, forKey: .weeklyRecapEnabled) ?? true
        timeZone             = try c.decodeIfPresent(String.self, forKey: .timeZone)
        onboardingCompletedAt = try c.decodeIfPresent(Date.self, forKey: .onboardingCompletedAt)
        onboardingArchetype   = try c.decodeIfPresent(Archetype.self, forKey: .onboardingArchetype)
        biologicalSex       = try c.decodeIfPresent(CalorieGoalCalculator.BiologicalSex.self, forKey: .biologicalSex)
        ageYears            = try c.decodeIfPresent(Int.self,    forKey: .ageYears)
        heightCm            = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        weightKg            = try c.decodeIfPresent(Double.self, forKey: .weightKg)
        activityLevel       = try c.decodeIfPresent(CalorieGoalCalculator.ActivityLevel.self, forKey: .activityLevel)
        weightGoalDirection = try c.decodeIfPresent(CalorieGoalCalculator.GoalDirection.self, forKey: .weightGoalDirection)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// Patch shape for updating profile goals & display name (no user_id, no created_at).
///
/// Phase 16/17. All fields are opt-in: a `nil` field means "don't
/// touch the column" (the custom encoder omits the key entirely).
/// Without this contract, calling `updateProfile` for goals-only would
/// silently clobber `preferred_coaches` / notification flags / etc.
struct ProfileUpdate: Encodable {
    var displayName: String? = nil
    var dailyCalorieGoal: Int? = nil
    var dailyCarbGoalG: Int? = nil
    var dailySugarGoalG: Int? = nil
    var dailyProteinGoalG: Int? = nil
    var dailyFatGoalG: Int? = nil
    var dailyFiberGoalG: Int? = nil
    var preferredCoaches: [String]? = nil
    var notificationsEnabled: Bool? = nil
    var reminderBreakfast: Bool? = nil
    var reminderLunch: Bool? = nil
    var reminderDinner: Bool? = nil
    var weeklyRecapEnabled: Bool? = nil
    var timeZone: String? = nil
    var onboardingCompletedAt: Date? = nil
    var onboardingArchetype: Profile.Archetype? = nil
    /// Phase 20. Physiology inputs. Same opt-in semantics as every
    /// other field in this struct — `nil` = "don't touch the column".
    /// No flow in v1 needs to actively clear a physiology field; a
    /// future "reset my profile" affordance would need a different
    /// shape (encode nil as JSON null) but isn't required yet.
    var biologicalSex: CalorieGoalCalculator.BiologicalSex? = nil
    var ageYears: Int? = nil
    var heightCm: Double? = nil
    var weightKg: Double? = nil
    var activityLevel: CalorieGoalCalculator.ActivityLevel? = nil
    var weightGoalDirection: CalorieGoalCalculator.GoalDirection? = nil

    enum CodingKeys: String, CodingKey {
        case displayName            = "display_name"
        case dailyCalorieGoal       = "daily_calorie_goal"
        case dailyCarbGoalG         = "daily_carb_goal_g"
        case dailySugarGoalG        = "daily_sugar_goal_g"
        case dailyProteinGoalG      = "daily_protein_goal_g"
        case dailyFatGoalG          = "daily_fat_goal_g"
        case dailyFiberGoalG        = "daily_fiber_goal_g"
        case preferredCoaches       = "preferred_coaches"
        case notificationsEnabled   = "notifications_enabled"
        case reminderBreakfast      = "reminder_breakfast"
        case reminderLunch          = "reminder_lunch"
        case reminderDinner         = "reminder_dinner"
        case weeklyRecapEnabled     = "weekly_recap_enabled"
        case timeZone               = "time_zone"
        case onboardingCompletedAt  = "onboarding_completed_at"
        case onboardingArchetype    = "onboarding_archetype"
        case biologicalSex          = "biological_sex"
        case ageYears               = "age_years"
        case heightCm               = "height_cm"
        case weightKg               = "weight_kg"
        case activityLevel          = "activity_level"
        case weightGoalDirection    = "weight_goal_direction"
    }

    /// Encode only the keys the caller actually populated. Without this,
    /// a nil field would be serialized as `null` and PostgREST would
    /// write NULL into the column — clobbering existing values. With
    /// this, omitted fields stay omitted.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(displayName,          forKey: .displayName)
        try c.encodeIfPresent(dailyCalorieGoal,     forKey: .dailyCalorieGoal)
        try c.encodeIfPresent(dailyCarbGoalG,       forKey: .dailyCarbGoalG)
        try c.encodeIfPresent(dailySugarGoalG,      forKey: .dailySugarGoalG)
        try c.encodeIfPresent(dailyProteinGoalG,    forKey: .dailyProteinGoalG)
        try c.encodeIfPresent(dailyFatGoalG,        forKey: .dailyFatGoalG)
        try c.encodeIfPresent(dailyFiberGoalG,      forKey: .dailyFiberGoalG)
        try c.encodeIfPresent(preferredCoaches,     forKey: .preferredCoaches)
        try c.encodeIfPresent(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encodeIfPresent(reminderBreakfast,    forKey: .reminderBreakfast)
        try c.encodeIfPresent(reminderLunch,        forKey: .reminderLunch)
        try c.encodeIfPresent(reminderDinner,       forKey: .reminderDinner)
        try c.encodeIfPresent(weeklyRecapEnabled,   forKey: .weeklyRecapEnabled)
        try c.encodeIfPresent(timeZone,             forKey: .timeZone)
        try c.encodeIfPresent(onboardingCompletedAt, forKey: .onboardingCompletedAt)
        try c.encodeIfPresent(onboardingArchetype,   forKey: .onboardingArchetype)
        try c.encodeIfPresent(biologicalSex,         forKey: .biologicalSex)
        try c.encodeIfPresent(ageYears,              forKey: .ageYears)
        try c.encodeIfPresent(heightCm,              forKey: .heightCm)
        try c.encodeIfPresent(weightKg,              forKey: .weightKg)
        try c.encodeIfPresent(activityLevel,         forKey: .activityLevel)
        try c.encodeIfPresent(weightGoalDirection,   forKey: .weightGoalDirection)
    }
}
