import Foundation
import Supabase

/// Reads and updates `public.profiles`. The row is auto-created by the
/// `handle_new_user` DB trigger when a user signs up — iOS never INSERTs.
///
/// RLS pattern (different from food_logs but same playbook):
///   - `profiles_select_own`  → `auth.uid() = id`
///   - `profiles_update_own`  → `auth.uid() = id`
///
/// The Phase 6 case-mismatch class applies: Swift's `UUID.uuidString` is
/// upper-case and Postgres `auth.uid()::text` is lower-case. We pass the
/// lowercased UUID into `.eq("id", value: …)` to keep the string-typed
/// PostgREST filter consistent with what the policy compares against.
actor ProfileService {
    private let client: SupabaseClient

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Resolve the signed-in user's UUID, preferring the live session over
    /// `currentUser` (defensive against the stale-cache desync mode noted
    /// in Phase 6's playbook).
    private func signedInUserId() async throws -> String {
        let sessionUid = (try? await client.auth.session.user.id.uuidString)?.lowercased()
        let cachedUid  = client.auth.currentUser?.id.uuidString.lowercased()
        guard let id = sessionUid ?? cachedUid else {
            throw ProfileError.notSignedIn
        }
        return id
    }

    /// Read the signed-in user's profile. If the row is missing
    /// (`handle_new_user` trigger didn't fire — see Phase 7 incident),
    /// self-heals by INSERTing a defaulted row under the
    /// `profiles_insert_own` RLS policy added in migration 001, then
    /// re-SELECTs.
    ///
    /// Implementation note: rather than using `.single()` (which throws an
    /// opaque PGRST116 on 0 rows), we read the array and inspect `.count`
    /// ourselves so we can distinguish the missing-row case and self-heal.
    func currentProfile() async throws -> Profile {
        let id = try await signedInUserId()
        #if DEBUG
        NSLog("[Profile] SELECT profiles WHERE id=%@", id)
        #endif

        do {
            let rows: [Profile] = try await client
                .from("profiles")
                .select()
                .eq("id", value: id)
                .execute()
                .value

            #if DEBUG
            NSLog("[Profile] SELECT returned %d row(s)", rows.count)
            #endif

            if let profile = rows.first {
                return profile
            }

            // Self-heal: trigger-skipped row. Insert a defaulted row using
            // auth.uid() as the id and let the schema column defaults
            // (display_name=null, daily_calorie_goal=2000, daily_carb_goal_g=250,
            // daily_sugar_goal_g=50) populate the rest. RLS policy
            // `profiles_insert_own` (migration 001) gates this with
            // `auth.uid() = id` so the user can only insert their own row.
            return try await selfHealMissingProfile(id: id)
        } catch let err as ProfileError {
            throw err
        } catch {
            #if DEBUG
            NSLog("[Profile] SELECT FAILED: %@", "\(error)")
            #endif
            throw error
        }
    }

    /// Self-heal entry point — log loudly so this surfacing in production
    /// is a signal to investigate trigger health, not a routine path.
    private func selfHealMissingProfile(id: String) async throws -> Profile {
        print("[Profile] self-heal: trigger-skipped row, inserting defaults for \(id)")
        #if DEBUG
        NSLog("[Profile] self-heal INSERT profiles (id=%@)", id)
        #endif

        struct ProfileSelfHealInsert: Encodable {
            let id: String
        }
        let payload = ProfileSelfHealInsert(id: id)

        let inserted: [Profile] = try await client
            .from("profiles")
            .insert(payload, returning: .representation)
            .execute()
            .value

        guard let profile = inserted.first else {
            throw ProfileError.notFound
        }
        #if DEBUG
        NSLog("[Profile] self-heal INSERT returned id=%@", profile.id.uuidString)
        #endif
        return profile
    }

    /// Update display name and goals. Returns the updated row so the VM
    /// can swap its loaded copy. Avatar upload is deferred (Phase 0 Q5),
    /// so `avatar_url` is left untouched.
    ///
    /// Phase 16. `preferredCoaches` is opt-in: `nil` means "don't touch
    /// the column" (the patch encoder omits the key); a non-nil value —
    /// including `[]` — replaces the stored array. Callers that only
    /// edit goals should pass `nil` so a stale empty array doesn't
    /// silently clobber the user's preferences.
    func updateProfile(displayName: String?,
                       dailyCalorieGoal: Int,
                       dailyCarbGoalG: Int,
                       dailySugarGoalG: Int,
                       dailyProteinGoalG: Int,
                       dailyFatGoalG: Int,
                       dailyFiberGoalG: Int,
                       preferredCoaches: [String]? = nil) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(
            displayName:       displayName?.isEmpty == true ? nil : displayName,
            dailyCalorieGoal:  dailyCalorieGoal,
            dailyCarbGoalG:    dailyCarbGoalG,
            dailySugarGoalG:   dailySugarGoalG,
            dailyProteinGoalG: dailyProteinGoalG,
            dailyFatGoalG:     dailyFatGoalG,
            dailyFiberGoalG:   dailyFiberGoalG,
            preferredCoaches:  preferredCoaches
        )

        #if DEBUG
        NSLog("[Profile] UPDATE profiles SET (display_name=%@ cal=%d carb=%d sugar=%d protein=%d fat=%d fiber=%d coaches=%@) WHERE id=%@",
              displayName ?? "<nil>",
              dailyCalorieGoal, dailyCarbGoalG, dailySugarGoalG,
              dailyProteinGoalG, dailyFatGoalG, dailyFiberGoalG,
              preferredCoaches.map { "[\($0.joined(separator: ","))]" } ?? "<nil>",
              id)
        #endif

        do {
            let updated: Profile = try await client
                .from("profiles")
                .update(patch)
                .eq("id", value: id)
                .select()
                .single()
                .execute()
                .value
            #if DEBUG
            NSLog("[Profile] UPDATE returned id=%@ updated_at=%@",
                  updated.id.uuidString, ISO8601DateFormatter().string(from: updated.updatedAt))
            #endif
            return updated
        } catch {
            #if DEBUG
            NSLog("[Profile] UPDATE FAILED: %@", "\(error)")
            #endif
            throw error
        }
    }

    /// Phase 16 — narrow API for the Coach Preferences screen. Writes
    /// only `preferred_coaches`, leaves goals + display name untouched.
    /// Returns the freshly-updated row so the caller can refresh any
    /// observers (e.g., the shared ProfileStore).
    func setPreferredCoaches(_ coaches: [String]) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(preferredCoaches: coaches)

        #if DEBUG
        NSLog("[Profile] UPDATE profiles SET preferred_coaches=[%@] WHERE id=%@",
              coaches.joined(separator: ","), id)
        #endif

        let updated: Profile = try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
        return updated
    }

    /// Phase 17 — write notification preferences in one round-trip.
    /// `nil` for any flag means "leave the column alone", matching the
    /// `ProfileUpdate` opt-in encoder contract. The settings UI passes
    /// only the field that just changed, so a master-toggle flip
    /// doesn't perturb the meal flags' stored values.
    func setNotificationPreferences(notificationsEnabled: Bool? = nil,
                                    reminderBreakfast: Bool? = nil,
                                    reminderLunch: Bool? = nil,
                                    reminderDinner: Bool? = nil,
                                    weeklyRecapEnabled: Bool? = nil) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(
            notificationsEnabled: notificationsEnabled,
            reminderBreakfast:    reminderBreakfast,
            reminderLunch:        reminderLunch,
            reminderDinner:       reminderDinner,
            weeklyRecapEnabled:   weeklyRecapEnabled
        )

        #if DEBUG
        NSLog("[Profile] UPDATE profiles SET (master=%@ b=%@ l=%@ d=%@ recap=%@) WHERE id=%@",
              notificationsEnabled.map { "\($0)" } ?? "<nil>",
              reminderBreakfast.map    { "\($0)" } ?? "<nil>",
              reminderLunch.map        { "\($0)" } ?? "<nil>",
              reminderDinner.map       { "\($0)" } ?? "<nil>",
              weeklyRecapEnabled.map   { "\($0)" } ?? "<nil>",
              id)
        #endif

        return try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }

    /// Phase 19 — single round-trip that persists every answer the
    /// onboarding flow has collected (archetype, default macro goals,
    /// preferred coaches, notification preferences) and stamps
    /// `onboarding_completed_at`. Designed as one batched UPDATE so the
    /// ring/bar denominators, coach rotation, and reminder schedule all
    /// pick up the values atomically — no half-onboarded states where
    /// the gate flipped but the goals didn't.
    ///
    /// Each parameter is opt-in (matching `ProfileUpdate`'s encoder). If
    /// the user skipped a screen, pass `nil` for that field and the
    /// stored value (or schema default) is left alone. The exception is
    /// `onboardingCompletedAt` and `onboardingArchetype`, which the
    /// caller is expected to set on every completion.
    func completeOnboarding(archetype: Profile.Archetype,
                            dailyCalorieGoal: Int?,
                            dailyCarbGoalG: Int?,
                            dailySugarGoalG: Int?,
                            dailyProteinGoalG: Int? = nil,
                            dailyFatGoalG: Int? = nil,
                            dailyFiberGoalG: Int? = nil,
                            preferredCoaches: [String]?,
                            notificationsEnabled: Bool?,
                            reminderBreakfast: Bool?,
                            reminderLunch: Bool?,
                            reminderDinner: Bool?,
                            physiology: CalorieGoalCalculator.Physiology? = nil,
                            completedAt: Date) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(
            dailyCalorieGoal:     dailyCalorieGoal,
            dailyCarbGoalG:       dailyCarbGoalG,
            dailySugarGoalG:      dailySugarGoalG,
            dailyProteinGoalG:    dailyProteinGoalG,
            dailyFatGoalG:        dailyFatGoalG,
            dailyFiberGoalG:      dailyFiberGoalG,
            preferredCoaches:     preferredCoaches,
            notificationsEnabled: notificationsEnabled,
            reminderBreakfast:    reminderBreakfast,
            reminderLunch:        reminderLunch,
            reminderDinner:       reminderDinner,
            onboardingCompletedAt: completedAt,
            onboardingArchetype:   archetype,
            biologicalSex:        physiology?.sex,
            ageYears:             physiology?.ageYears,
            heightCm:             physiology?.heightCm,
            weightKg:             physiology?.weightKg,
            activityLevel:        physiology?.activity,
            weightGoalDirection:  physiology?.goal
        )

        #if DEBUG
        NSLog("[Profile] completeOnboarding archetype=%@ id=%@",
              archetype.rawValue, id)
        #endif

        return try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }

    /// Phase 20 — persist physiology + the calorie/macro target derived
    /// from `CalorieGoalCalculator.compute`. One UPDATE keeps the inputs
    /// and the resulting goals atomic, so the BMR/TDEE info row in
    /// Profile never disagrees with the displayed targets.
    ///
    /// Caller computes `Goals` on the client (the calculator is pure)
    /// and passes the values in alongside the source physiology. If
    /// users in the future need to clear physiology without setting
    /// goals (or vice versa) we'd extend this API, but v1's only flow
    /// is "fill out form → save everything together."
    func setPhysiologyAndGoals(
        sex: CalorieGoalCalculator.BiologicalSex,
        ageYears: Int,
        heightCm: Double,
        weightKg: Double,
        activity: CalorieGoalCalculator.ActivityLevel,
        goal: CalorieGoalCalculator.GoalDirection,
        goals: CalorieGoalCalculator.Goals
    ) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(
            dailyCalorieGoal:    goals.calories,
            dailyCarbGoalG:      goals.carbsG,
            dailySugarGoalG:     goals.sugarG,
            dailyProteinGoalG:   goals.proteinG,
            dailyFatGoalG:       goals.fatG,
            dailyFiberGoalG:     goals.fiberG,
            biologicalSex:       sex,
            ageYears:            ageYears,
            heightCm:            heightCm,
            weightKg:            weightKg,
            activityLevel:       activity,
            weightGoalDirection: goal
        )

        #if DEBUG
        NSLog("[Profile] UPDATE profiles SET physiology+goals (sex=%@ age=%d h=%.1f w=%.1f act=%@ goal=%@ cal=%d) WHERE id=%@",
              sex.rawValue, ageYears, heightCm, weightKg,
              activity.rawValue, goal.rawValue, goals.calories, id)
        #endif

        return try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }

    /// Phase 17 — quiet timezone sync. Writes the IANA identifier only
    /// when it differs from `currentValue`. Caller is responsible for
    /// reading the current value from the loaded profile and skipping
    /// the call when it already matches; this method is the leaf write.
    func setTimeZone(_ identifier: String) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(timeZone: identifier)

        #if DEBUG
        NSLog("[Profile] UPDATE profiles SET time_zone=%@ WHERE id=%@",
              identifier, id)
        #endif

        return try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }
}

enum ProfileError: LocalizedError {
    case notSignedIn
    case notFound

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You need to sign in to view your profile."
        case .notFound:    return "We couldn't find your profile."
        }
    }
}
