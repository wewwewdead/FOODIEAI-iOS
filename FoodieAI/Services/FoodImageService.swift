import Foundation
import Supabase

actor FoodImageService {
    private let client: SupabaseClient
    private let bucket = "food-images"

    /// Per-process signed-URL cache keyed by storage path. Lets repeat
    /// openings of the day-detail sheet skip a round-trip per thumbnail.
    /// We sign for one hour (`signedURLTTL`) and serve a cached URL only if
    /// it has at least `signedURLBuffer` of life left, so we never hand out
    /// a URL that could expire while the image is still loading.
    private var signedURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private let signedURLTTL: TimeInterval    = 60 * 60
    private let signedURLBuffer: TimeInterval = 60

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// Phase 12: paired upload of the main image and its thumbnail. Both
    /// objects share the same per-meal `imageId` so they're easy to colocate
    /// in the bucket browser; the thumbnail uses an `_thumb.jpg` suffix.
    /// Both paths land under the user's UUID folder, satisfying the storage
    /// RLS policy (which checks `(storage.foldername(name))[1] = auth.uid()::text`).
    ///
    /// Uploads run concurrently via async-let; partial failures roll up into
    /// the first thrown error — Phase 12 doesn't attempt a partial-cleanup
    /// step because:
    ///   1. The food_logs row hasn't been inserted yet on this path, so the
    ///      orphaned object isn't referenced by anything in the schema.
    ///   2. Storage cost is cheap; we'd rather take the orphan than risk
    ///      compounding a failure with a delete that also fails.
    func uploadMealImages(mainData: Data, thumbnailData: Data) async throws -> UploadedImage {
        let sessionUid = (try? await client.auth.session.user.id.uuidString)?.lowercased()
        let cachedUid  = client.auth.currentUser?.id.uuidString.lowercased()

        guard let userId = sessionUid ?? cachedUid else {
            #if DEBUG
            NSLog("[Save] FoodImageService.uploadMealImages: NOT SIGNED IN")
            #endif
            throw FoodImageError.notSignedIn
        }

        let imageId   = UUID().uuidString.lowercased()
        let mainPath  = "\(userId)/\(imageId).jpg"
        let thumbPath = "\(userId)/\(imageId)_thumb.jpg"

        #if DEBUG
        NSLog("[Save] uploading main_path  = %@ (%d bytes)", mainPath, mainData.count)
        NSLog("[Save] uploading thumb_path = %@ (%d bytes)", thumbPath, thumbnailData.count)
        #endif

        async let mainUpload:  Void = uploadJPEG(mainData,      to: mainPath)
        async let thumbUpload: Void = uploadJPEG(thumbnailData, to: thumbPath)
        _ = try await (mainUpload, thumbUpload)

        return UploadedImage(mainPath: mainPath, thumbPath: thumbPath)
    }

    private func uploadJPEG(_ data: Data, to path: String) async throws {
        try await client.storage
            .from(bucket)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )
    }

    /// Single-object upload retained for back-compat. Phase 12+ callers
    /// should use `uploadMealImages(mainData:thumbnailData:)` instead — it
    /// produces both the main and the thumbnail object in one round-trip.
    @available(*, deprecated, message: "Use uploadMealImages(mainData:thumbnailData:) instead.")
    func upload(jpegData: Data) async throws -> String {
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
        NSLog("[Save] (legacy) storage path being uploaded = %@", path)
        #endif

        try await uploadJPEG(jpegData, to: path)
        return path
    }

    /// Delete one or more objects from the bucket. Caller passes the full
    /// storage paths (e.g., `"{userId}/{uuid}.jpg"`). Empty input is a no-op.
    /// The storage `food_images_delete_own` policy scopes deletes to the
    /// caller's own folder, so this can't accidentally remove another
    /// user's image even if a stray path were passed.
    ///
    /// Also evicts any cached signed URLs for the deleted paths so a
    /// re-upload at the same path (which can't currently happen — paths
    /// are UUID-suffixed) wouldn't serve a stale cached URL.
    func delete(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        #if DEBUG
        NSLog("[Delete] removing %d storage object(s): %@",
              paths.count, paths.joined(separator: ", "))
        #endif
        _ = try await client.storage.from(bucket).remove(paths: paths)
        for p in paths { signedURLCache.removeValue(forKey: p) }
    }

    /// Short-lived signed URL for displaying a private image.
    func signedUrl(for path: String, expiresIn seconds: Int = 60 * 60) async throws -> URL {
        try await client.storage
            .from(bucket)
            .createSignedURL(path: path, expiresIn: seconds)
    }

    /// Cached variant for use by history thumbnails. Returns a signed URL
    /// with at least `signedURLBuffer` seconds of life left; mints a new one
    /// otherwise. Cache is per-actor and lives for the process.
    func cachedSignedURL(for path: String) async throws -> URL {
        let now = Date()
        if let cached = signedURLCache[path],
           cached.expiresAt.timeIntervalSince(now) > signedURLBuffer {
            #if DEBUG
            NSLog("[FoodImage] cachedSignedURL HIT  %@", path)
            #endif
            return cached.url
        }
        #if DEBUG
        NSLog("[FoodImage] cachedSignedURL MISS %@", path)
        #endif
        let url = try await signedUrl(for: path, expiresIn: Int(signedURLTTL))
        signedURLCache[path] = (url, now.addingTimeInterval(signedURLTTL))
        return url
    }
}

/// Phase 12: result of `uploadMealImages` — the two storage paths to write
/// into `food_logs.image_path` and `food_logs.image_thumb_path` respectively.
struct UploadedImage {
    let mainPath: String
    let thumbPath: String
}

enum FoodImageError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You need to sign in before saving meals."
        }
    }
}
