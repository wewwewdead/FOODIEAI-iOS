import UIKit

/// Pure helper — no network. Resize a `UIImage` so its long edge is at most
/// `maxLongEdge` (no upscaling), then JPEG-encode at `quality`.
///
/// Phase 12 introduces two named presets so the egress-shaped sizing isn't
/// scattered across call sites:
///
///   - `compressMain`      → 1024px / 0.70 quality, ~80–150 KB target.
///     Used for the multipart body sent to `/analyze` and stored as the
///     full-resolution object in Supabase Storage.
///   - `compressThumbnail` → 256px  / 0.60 quality, ~10–25 KB target.
///     Stored alongside the main object for use by list/grid views.
///
/// Returns `nil` only if `UIGraphicsImageRenderer.jpegData(...)` fails — in
/// practice that's unrecoverable, and the caller should surface a generic
/// "couldn't read this photo" error.
enum ImagePreparation {

    /// Phase 12: main image — uploaded to /analyze AND stored in
    /// Storage as the full-resolution object. Long edge 1024, quality 0.70.
    static func compressMain(_ image: UIImage) -> Data? {
        compress(image, maxLongEdge: 1024, quality: 0.70)
    }

    /// Phase 12: thumbnail — small object loaded by list/grid views.
    /// Long edge 256, quality 0.60.
    static func compressThumbnail(_ image: UIImage) -> Data? {
        compress(image, maxLongEdge: 256, quality: 0.60)
    }

    /// Internal compressor used by both presets above. Kept `internal` (not
    /// `private`) so tests can exercise the underlying knobs directly.
    static func compress(_ image: UIImage,
                         maxLongEdge: CGFloat,
                         quality: CGFloat) -> Data? {
        let resized = resize(image, maxLongEdge: maxLongEdge)
        let renderer = UIGraphicsImageRenderer(size: resized.size)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            resized.draw(in: CGRect(origin: .zero, size: resized.size))
        }
    }

    /// Returns the original image when its long edge already fits — no
    /// upscaling, no copy. Otherwise scales by `maxLongEdge / longEdge`,
    /// preserving aspect ratio.
    static func resize(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }

        let scale = maxLongEdge / longEdge
        let newSize = CGSize(width: floor(size.width * scale),
                             height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
