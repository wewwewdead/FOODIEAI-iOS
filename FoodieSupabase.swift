//
//  FoodieSupabase.swift
//  Starter code for talking to the Supabase backend from iOS.
//
//  Setup:
//    1. Add the supabase-swift package:
//       https://github.com/supabase/supabase-swift
//       (File → Add Package Dependencies in Xcode)
//
//    2. Fill in supabaseURL and supabaseAnonKey below from
//       Supabase Dashboard → Project Settings → API.
//
//    3. In Xcode you'd typically split this into multiple files
//       (Models.swift, FoodieClient.swift, FoodLogService.swift, etc.).
//       Kept together here for readability.
//

import Foundation
import Supabase

// MARK: - Client singleton ----------------------------------------------------

enum FoodieClient {
    static let shared: SupabaseClient = SupabaseClient(
        supabaseURL: URL(string: "https://YOUR-PROJECT.supabase.co")!,
        supabaseKey: "YOUR-PUBLIC-ANON-KEY"
    )
}

// MARK: - Models --------------------------------------------------------------

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

/// Mirrors public.food_logs (read shape — what comes back from a SELECT)
struct FoodLog: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let foodName: String
    let imagePath: String?
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
        case userId       = "user_id"
        case foodName     = "food_name"
        case imagePath    = "image_path"
        case calories
        case carbsG       = "carbs_g"
        case sugarG       = "sugar_g"
        case proteinG     = "protein_g"
        case fatG         = "fat_g"
        case fiberG       = "fiber_g"
        case benefits, drawbacks, nutrients
        case coachName    = "coach_name"
        case coachAdvice  = "coach_advice"
        case eatenAt      = "eaten_at"
        case createdAt    = "created_at"
    }
}

/// Insert shape — note we do NOT include user_id; the DB fills it from auth.uid().
struct NewFoodLog: Encodable {
    let foodName: String
    let imagePath: String?
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
        case foodName    = "food_name"
        case imagePath   = "image_path"
        case calories
        case carbsG      = "carbs_g"
        case sugarG      = "sugar_g"
        case proteinG    = "protein_g"
        case fatG        = "fat_g"
        case fiberG      = "fiber_g"
        case benefits, drawbacks, nutrients
        case coachName   = "coach_name"
        case coachAdvice = "coach_advice"
    }
}

/// Mirrors public.daily_food_totals
struct DailyTotals: Codable, Hashable {
    let userId: UUID
    let day: Date
    let entries: Int
    let totalCalories: Double
    let totalCarbs: Double
    let totalSugar: Double
    let totalProtein: Double
    let totalFat: Double
    let totalFiber: Double

    enum CodingKeys: String, CodingKey {
        case userId        = "user_id"
        case day, entries
        case totalCalories = "total_calories"
        case totalCarbs    = "total_carbs"
        case totalSugar    = "total_sugar"
        case totalProtein  = "total_protein"
        case totalFat      = "total_fat"
        case totalFiber    = "total_fiber"
    }
}

// MARK: - Auth ----------------------------------------------------------------

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var currentUserId: UUID?

    private let client: SupabaseClient
    private var authTask: Task<Void, Never>?

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
        // Listen for auth state changes (sign in / sign out / token refresh).
        authTask = Task { [weak self] in
            for await change in client.auth.authStateChanges {
                self?.currentUserId = change.session?.user.id
            }
        }
    }

    func signUp(email: String, password: String) async throws {
        try await client.auth.signUp(email: email, password: password)
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }
}

// MARK: - Food log queries ----------------------------------------------------

actor FoodLogService {
    private let client: SupabaseClient

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Insert a freshly-analyzed meal. Returns the persisted row.
    func insert(_ draft: NewFoodLog) async throws -> FoodLog {
        try await client
            .from("food_logs")
            .insert(draft, returning: .representation)
            .single()
            .execute()
            .value
    }

    /// Today's logs for the signed-in user (RLS keeps it scoped).
    func todaysLogs() async throws -> [FoodLog] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endOfDay   = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        let f = ISO8601DateFormatter()

        return try await client
            .from("food_logs")
            .select()
            .gte("eaten_at", value: f.string(from: startOfDay))
            .lt ("eaten_at", value: f.string(from: endOfDay))
            .order("eaten_at", ascending: false)
            .execute()
            .value
    }

    /// Pre-aggregated totals for today via the daily_food_totals view.
    func todaysTotals() async throws -> DailyTotals? {
        let dayString = todayDateString()
        return try await client
            .from("daily_food_totals")
            .select()
            .eq("day", value: dayString)
            .limit(1)
            .execute()
            .value
            .first
    }

    func delete(_ id: UUID) async throws {
        try await client
            .from("food_logs")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    private func todayDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}

// MARK: - Image storage -------------------------------------------------------

actor FoodImageService {
    private let client: SupabaseClient
    private let bucket = "food-images"

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Upload JPEG bytes. The path MUST start with the user's id folder
    /// so the storage RLS policy allows it.
    /// Returns the storage path (save this in food_logs.image_path).
    func upload(jpegData: Data) async throws -> String {
        guard let userId = client.auth.currentUser?.id.uuidString else {
            throw NSError(domain: "Foodie", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let fileName = "\(UUID().uuidString).jpg"
        let path     = "\(userId)/\(fileName)"

        try await client.storage
            .from(bucket)
            .upload(
                path,
                data: jpegData,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )
        return path
    }

    /// Short-lived signed URL for displaying a private image in the UI.
    func signedUrl(for path: String, expiresIn seconds: Int = 60 * 60) async throws -> URL {
        try await client.storage
            .from(bucket)
            .createSignedURL(path: path, expiresIn: seconds)
    }
}

// MARK: - End-to-end usage example -------------------------------------------
//
// 1. User snaps a photo  →  UIImage / Data
// 2. POST it to your Express /analyze endpoint  →  Gemini JSON
// 3. Upload the photo to Supabase Storage
// 4. Insert the analysis into food_logs
//
//   let imagePath = try await FoodImageService().upload(jpegData: jpeg)
//   let draft = NewFoodLog(
//       foodName:    analysis.food,
//       imagePath:   imagePath,
//       calories:    analysis.calories,
//       carbsG:      analysis.carbs,
//       sugarG:      analysis.sugar,
//       proteinG:    nil,
//       fatG:        nil,
//       fiberG:      nil,
//       benefits:    analysis.benefits,
//       drawbacks:   analysis.drawbacks,
//       nutrients:   analysis.nutrients,
//       coachName:   coach,
//       coachAdvice: analysis.coachAdvice
//   )
//   let saved = try await FoodLogService().insert(draft)
//
