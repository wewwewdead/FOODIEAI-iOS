import Foundation

/// Mirrors public.profiles
struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String?
    var avatarUrl: String?
    var dailyCalorieGoal: Int
    var dailyCarbGoalG: Int
    var dailySugarGoalG: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName       = "display_name"
        case avatarUrl         = "avatar_url"
        case dailyCalorieGoal  = "daily_calorie_goal"
        case dailyCarbGoalG    = "daily_carb_goal_g"
        case dailySugarGoalG   = "daily_sugar_goal_g"
        case createdAt         = "created_at"
        case updatedAt         = "updated_at"
    }
}

/// Patch shape for updating profile goals & display name (no user_id, no created_at).
struct ProfileUpdate: Encodable {
    var displayName: String?
    var dailyCalorieGoal: Int?
    var dailyCarbGoalG: Int?
    var dailySugarGoalG: Int?

    enum CodingKeys: String, CodingKey {
        case displayName       = "display_name"
        case dailyCalorieGoal  = "daily_calorie_goal"
        case dailyCarbGoalG    = "daily_carb_goal_g"
        case dailySugarGoalG   = "daily_sugar_goal_g"
    }
}
