import Foundation
import Supabase

actor FoodImageService {
    private let client: SupabaseClient
    private let bucket = "food-images"

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Upload JPEG bytes. The path MUST start with the user's id folder
    /// (`{auth.uid()}/...`) so the storage RLS policy permits it.
    /// Returns the storage path — save this in food_logs.image_path.
    ///
    /// IMPORTANT — UUID case: Swift's `UUID.uuidString` is upper-cased
    /// ("67E5...0C8"), but Postgres `auth.uid()::text` returns
    /// lower-case. The storage RLS policy in `foodie_schema.sql` compares
    /// `(storage.foldername(name))[1] = auth.uid()::text` — that's a
    /// case-sensitive string compare, NOT a UUID compare. So we must
    /// `.lowercased()` both the user-id segment AND the random
    /// per-object UUID for consistency.
    func upload(jpegData: Data) async throws -> String {
        // Prefer the live session's user id over `currentUser` to avoid a
        // stale-cache divergence after a token refresh.
        let sessionUid = (try? await client.auth.session.user.id.uuidString)?.lowercased()
        let cachedUid  = client.auth.currentUser?.id.uuidString.lowercased()

        guard let userId = sessionUid ?? cachedUid else {
            #if DEBUG
            NSLog("[Save] FoodImageService.upload: NOT SIGNED IN (currentUser=nil, session=nil)")
            #endif
            throw FoodImageError.notSignedIn
        }

        let fileName = "\(UUID().uuidString.lowercased()).jpg"
        let path     = "\(userId)/\(fileName)"

        #if DEBUG
        NSLog("[Save] auth.currentUser?.id        = %@", cachedUid ?? "<nil>")
        NSLog("[Save] auth.session?.user.id       = %@", sessionUid ?? "<nil>")
        NSLog("[Save] storage path being uploaded = %@", path)
        NSLog("[Save] path leading char           = %@",
              String(path.prefix(1)))
        NSLog("[Save] path contains '/'           = %@",
              path.contains("/") ? "yes" : "no")
        #endif

        try await client.storage
            .from(bucket)
            .upload(
                path,
                data: jpegData,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )
        return path
    }

    /// Short-lived signed URL for displaying a private image.
    func signedUrl(for path: String, expiresIn seconds: Int = 60 * 60) async throws -> URL {
        try await client.storage
            .from(bucket)
            .createSignedURL(path: path, expiresIn: seconds)
    }
}

enum FoodImageError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You need to sign in before saving meals."
        }
    }
}
