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
    ///
    /// Pipeline: bake EXIF rotation into pixels (so `image.size` and the
    /// actual pixel buffer agree), resize at scale 1, then JPEG-encode at
    /// scale 1. Without the explicit format on the JPEG renderer it would
    /// default to screen scale (2x/3x on retina iPhones), inflating the
    /// encoded buffer to 2048–3072 px on the long edge and producing
    /// ~1 MB+ JPEGs from a nominally 1024 px target.
    static func compress(_ image: UIImage,
                         maxLongEdge: CGFloat,
                         quality: CGFloat) -> Data? {
        let oriented = normalized(image)
        let resized = resize(oriented, maxLongEdge: maxLongEdge)

        #if DEBUG
        if let cg = resized.cgImage {
            print("[Analyze-prep] resized-pixels=\(cg.width)x\(cg.height) logical=\(resized.size.width)x\(resized.size.height)")
        }
        #endif

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: resized.size, format: format)
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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Bakes the EXIF orientation into pixels. iPhone camera captures
    /// often arrive with a non-`.up` `imageOrientation` (the rotation is
    /// metadata, not pixels), which makes `image.size` disagree with the
    /// underlying CGImage's pixel dimensions. Normalizing up front means
    /// the rest of the pipeline can treat point size and pixel size as
    /// the same number.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
