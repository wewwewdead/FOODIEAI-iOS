import Foundation
import Supabase
import UserNotifications

/// Orchestrates user-initiated account deletion in the order that
/// minimizes orphan risk: list storage paths from food_logs first (the
/// query needs the user's RLS context), delete those Storage objects,
/// then call DELETE /account on the server (which cascade-removes the
/// auth.users row and every FK-referencing row), then wipe local
/// per-install state so the next sign-in starts clean.
///
/// App Store Review Guideline 5.1.1(v) requires this affordance in
/// every app that supports sign-in.
@MainActor
final class AccountDeletionService {
    enum Step {
        case fetchingFiles
        case deletingStorage
        case deletingAccount
        case cleaningLocal
    }

    enum DeletionError: Error, LocalizedError {
        case unauthenticated
        case accountDeletionFailed(statusCode: Int, message: String?)
        case unknown(Error)

        var errorDescription: String? {
            switch self {
            case .unauthenticated:
                return "You need to be signed in to delete your account."
            case .accountDeletionFailed(let code, let message):
                if let message, !message.isEmpty {
                    return "Server refused the delete (\(code)): \(message)"
                }
                return "Server refused the delete (HTTP \(code))."
            case .unknown(let error):
                return error.localizedDescription
            }
        }
    }

    private let client: SupabaseClient

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Run the full deletion sequence. Throws on any unrecoverable
    /// failure; storage failures are logged and swallowed (the auth
    /// row is the user-visible source of truth).
    func deleteCurrentAccount(
        onProgress: @escaping (Step) -> Void
    ) async throws {
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            throw DeletionError.unauthenticated
        }
        let accessToken = session.accessToken
        let userId = session.user.id

        // Step 1 — list storage paths (image_path + image_thumb_path)
        // while we still have an authenticated session. RLS scopes the
        // query to the caller's own food_logs.
        onProgress(.fetchingFiles)
        let storagePaths = (try? await fetchUserStoragePaths()) ?? []

        // Step 2 — best-effort batch remove. If this partially fails
        // (network blip, transient bucket error), don't abort: an
        // orphaned JPEG is a much smaller harm than leaving an auth
        // row the user thinks is deleted.
        onProgress(.deletingStorage)
        if !storagePaths.isEmpty {
            do {
                _ = try await client.storage
                    .from("food-images")
                    .remove(paths: storagePaths)
            } catch {
                #if DEBUG
                NSLog("[Delete] storage cleanup partial failure: %@", "\(error)")
                #endif
            }
        }

        // Step 3 — server DELETE /account. The server validates the
        // JWT, extracts the user_id from the verified token (we never
        // pass it in the body), and calls admin.deleteUser, which
        // cascades through every FK-referencing table.
        onProgress(.deletingAccount)
        let url = AppConfig.analyzeBaseURL.appendingPathComponent("account")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeletionError.unknown(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeletionError.unknown(URLError(.badServerResponse))
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8)
            throw DeletionError.accountDeletionFailed(
                statusCode: http.statusCode,
                message: body
            )
        }

        // Step 4 — local cleanup. Sign-out is last so the UI can
        // observe `isSignedIn` flipping to false and route to the
        // landing screen automatically.
        onProgress(.cleaningLocal)

        UNUserNotificationCenter.current()
            .removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current()
            .removeAllDeliveredNotifications()

        // Keep this list in sync with every `forKey:` literal used
        // across the app for foodie/phase-prefixed UserDefaults state.
        // Account-deletion cleanup: keep this list in sync.
        let defaultsKeys: [String] = [
            "phase16.didSeeCoachPicker",
            "phase17.savesSinceInstall",
            "phase17.permissionDeferredUntil",
            "phase17.didPresentPermissionOnce",
            "phase19.onboardingCompletedAtFallback",
            "phase19.onboardingArchetypeFallback",
            "foodie.favorites.v1",
            "foodie.loggingRhythm.v1",
        ]
        for key in defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        try? await client.auth.signOut()

        #if DEBUG
        NSLog("[Delete] account deletion complete: user_id=%@", userId.uuidString)
        #endif
    }

    private func fetchUserStoragePaths() async throws -> [String] {
        let rows: [PathRow] = try await client
            .from("food_logs")
            .select("image_path, image_thumb_path")
            .execute()
            .value

        var paths: [String] = []
        for row in rows {
            if let p = row.imagePath, !p.isEmpty { paths.append(p) }
            if let p = row.imageThumbPath, !p.isEmpty { paths.append(p) }
        }
        return paths
    }

    private struct PathRow: Decodable {
        let imagePath: String?
        let imageThumbPath: String?
        enum CodingKeys: String, CodingKey {
            case imagePath = "image_path"
            case imageThumbPath = "image_thumb_path"
        }
    }
}
