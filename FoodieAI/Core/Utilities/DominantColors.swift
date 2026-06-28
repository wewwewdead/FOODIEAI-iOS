import UIKit
import SwiftUI

/// Fast, dependency-free dominant-color sampling used to tint the
/// analyzing aura from the scanned food's own hues.
///
/// The goal here is the *opposite* of precision: we want 2–4 colors that
/// read as "this dish" once they're smeared into a blurred, screen-blended
/// glow. So the pipeline is deliberately tiny and cheap —
///
///   1. Draw the image into an `gridSize`×`gridSize` RGBA8 bitmap with a
///      CPU `CGContext` (no Core Image, no GPU round-trip → safe to call
///      on the main thread; microseconds of work for a one-shot per scan).
///   2. Average each of the four quadrants of that grid into one swatch,
///      skipping cells that are near-black (shadow), near-white (plate /
///      blown highlight) or near-gray (flat background) so the result
///      leans into the food's chroma instead of the table.
///   3. Nudge saturation/brightness up a touch so the hue still reads
///      after the aura blurs and screen-blends over the photo.
///
/// Returns up to `maxColors` colors, most-saturated first. The aura
/// treats "< 2 usable colors" as a cue to fall back to its default
/// rainbow palette, so a flat / monochrome dish degrades gracefully.
///
/// Sampling is intended to run **once per scan** (when analysis begins),
/// never per frame — a `TimelineView` redraw must not re-enter this.
enum DominantColors {

    /// Extract up to `maxColors` representative colors from `image`.
    /// `gridSize` is the side of the downsample grid (8 → 8×8 = 64 cells).
    static func extract(from image: UIImage,
                        gridSize: Int = 8,
                        maxColors: Int = 4) -> [Color] {
        let side = max(2, gridSize)
        guard let pixels = downsample(image, side: side), !pixels.isEmpty else {
            return []
        }

        let half = side / 2
        let quadrants: [(xs: Range<Int>, ys: Range<Int>)] = [
            (0..<half,    0..<half),
            (half..<side, 0..<half),
            (0..<half,    half..<side),
            (half..<side, half..<side),
        ]

        var swatches: [RGB] = []
        for quad in quadrants {
            var acc = Accumulator()
            for y in quad.ys {
                for x in quad.xs where pixels[y * side + x].isVivid {
                    acc.add(pixels[y * side + x])
                }
            }
            if let avg = acc.average() { swatches.append(avg) }
        }

        // If every quadrant filtered down to nothing (a very flat dish),
        // fall back to one whole-image average — still better than no hue,
        // though the caller may decide a single color isn't enough and
        // drop back to its own palette.
        if swatches.isEmpty {
            var acc = Accumulator()
            for p in pixels where p.isVivid { acc.add(p) }
            if let avg = acc.average() { swatches.append(avg) }
        }

        return swatches
            .sorted { $0.saturation > $1.saturation }
            .prefix(maxColors)
            .map { $0.boosted().color }
    }

    // MARK: - Downsample

    /// Renders `image` into a `side`×`side` RGBA8 buffer and returns the
    /// pixels row-major. Premultiplied-last so opaque food photos come
    /// through with their straight color channels intact.
    private static func downsample(_ image: UIImage, side: Int) -> [RGB]? {
        guard let cg = image.cgImage ?? rasterize(image) else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        let drew: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }

        var pixels: [RGB] = []
        pixels.reserveCapacity(side * side)
        var i = 0
        while i < buffer.count {
            pixels.append(RGB(r: buffer[i], g: buffer[i + 1], b: buffer[i + 2]))
            i += bytesPerPixel
        }
        return pixels
    }

    /// Last-resort rasterize for the rare `UIImage` with no backing
    /// `cgImage` (e.g. a `CIImage`-backed image). Flattens into a
    /// 1×-scale context so there are real pixels to downsample.
    private static func rasterize(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}

// MARK: - Small color math (no Core Image)

private extension DominantColors {

    struct RGB {
        var r: UInt8, g: UInt8, b: UInt8

        var rf: Double { Double(r) / 255 }
        var gf: Double { Double(g) / 255 }
        var bf: Double { Double(b) / 255 }

        private var maxC: Double { max(rf, max(gf, bf)) }
        private var minC: Double { min(rf, min(gf, bf)) }

        /// HSV "value" — how bright the brightest channel is.
        var brightness: Double { maxC }
        /// HSV saturation — how far the color is from gray.
        var saturation: Double { maxC <= 0 ? 0 : (maxC - minC) / maxC }

        /// "Usable" = carries enough chroma and isn't crushed to shadow
        /// or blown to highlight. Tuned loose so warm beige / brown dishes
        /// still pass while plate-white and deep shadow get dropped.
        var isVivid: Bool {
            brightness > 0.12 && brightness < 0.97 && saturation > 0.12
        }

        var color: Color { Color(red: rf, green: gf, blue: bf) }

        /// Lift saturation + brightness modestly (in HSB so the hue is
        /// preserved) so the tint survives the aura's blur + screen blend.
        func boosted() -> RGB {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(rf), green: CGFloat(gf), blue: CGFloat(bf), alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let s2 = min(1.0, s * 1.35 + 0.10)
            let v2 = min(1.0, max(v, 0.55) * 1.05)
            var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
            UIColor(hue: h, saturation: s2, brightness: v2, alpha: 1)
                .getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
            return RGB(r: Self.clamp(rr), g: Self.clamp(gg), b: Self.clamp(bb))
        }

        private static func clamp(_ x: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (x * 255).rounded())))
        }
    }

    struct Accumulator {
        var r = 0, g = 0, b = 0, n = 0
        mutating func add(_ p: RGB) {
            r += Int(p.r); g += Int(p.g); b += Int(p.b); n += 1
        }
        func average() -> RGB? {
            guard n > 0 else { return nil }
            return RGB(r: UInt8(r / n), g: UInt8(g / n), b: UInt8(b / n))
        }
    }
}
