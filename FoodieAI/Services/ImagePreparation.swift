import UIKit

/// Pure helper — no network. Resize a `UIImage` so its long edge is at most
/// `maxLongEdge` (no upscaling), then JPEG-encode at `quality`.
///
/// Used by the capture flow before handing bytes to `AnalyzeService`.
/// Returns `nil` only if `UIGraphicsImageRenderer.jpegData(...)` fails — in
/// practice that's unrecoverable, and the caller should surface a generic
/// "couldn't read this photo" error.
enum ImagePreparation {
    static func compress(_ image: UIImage,
                         maxLongEdge: CGFloat = 2048,
                         quality: CGFloat = 0.8) -> Data? {
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
