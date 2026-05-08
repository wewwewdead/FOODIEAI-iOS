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
    func updateProfile(displayName: String?,
                       dailyCalorieGoal: Int,
                       dailyCarbGoalG: Int,
                       dailySugarGoalG: Int) async throws -> Profile {
        let id = try await signedInUserId()
        let patch = ProfileUpdate(
            displayName:      displayName?.isEmpty == true ? nil : displayName,
            dailyCalorieGoal: dailyCalorieGoal,
            dailyCarbGoalG:   dailyCarbGoalG,
            dailySugarGoalG:  dailySugarGoalG
        )

        #if DEBUG
        NSLog("[Profile] UPDATE profiles SET (display_name=%@ cal=%d carb=%d sugar=%d) WHERE id=%@",
              displayName ?? "<nil>",
              dailyCalorieGoal, dailyCarbGoalG, dailySugarGoalG, id)
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
