import Foundation
import Vision
import UIKit

// NOVEL_DIRECTIONS Idea 4 — the on-device embedding boundary for
// `VisualFoodMemory`. Turns a meal photo into a compact feature-print vector
// using Vision's `VNGenerateImageFeaturePrintRequest`. Entirely local: the
// image never leaves the device for this, matching the app's low-egress stance
// and adding no third-party dependency (Vision is a system framework).
//
// Everything here is best-effort and fully guarded — any failure returns nil so
// the caller (the save path) simply skips remembering that meal. The pure
// matching/recognition logic lives in `VisualFoodMemory`; this file is the only
// place that touches Vision, so it's the single thing that needs on-device
// verification.

enum VisionMealEmbedder {

    /// Compute a visual descriptor for `image`, or nil if Vision can't (no
    /// backing `CGImage`, unsupported element type, request failure). Runs the
    /// Vision request off the main actor via a continuation.
    static func embed(_ image: UIImage) async -> VisualDescriptor? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNGenerateImageFeaturePrintRequest()
                // Pin the revision so prints stay dimensionally + numerically
                // comparable across app runs and OS updates. Revision1 is
                // available on every supported OS (iOS 13+); if it changes here,
                // bump the store filename in VisualFoodMemory so stale prints
                // from the old revision are discarded rather than mis-compared.
                if VNGenerateImageFeaturePrintRequest.supportedRevisions
                    .contains(VNGenerateImageFeaturePrintRequestRevision1) {
                    request.revision = VNGenerateImageFeaturePrintRequestRevision1
                }
                // Center-crop to a square so plating/framing differences matter
                // less than the food itself.
                request.imageCropAndScaleOption = .centerCrop
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    guard
                        let observation = request.results?.first as? VNFeaturePrintObservation,
                        let vector = Self.vector(from: observation)
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let descriptor = VisualDescriptor(vector: vector)
                    // Reject a corrupt print (NaN/Inf) at the source so it can
                    // never poison distance comparisons downstream.
                    continuation.resume(returning: descriptor.isValid ? descriptor : nil)
                } catch {
                    #if DEBUG
                    NSLog("[VisualMemory] embed failed: %@", "\(error)")
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Extract the raw `Float` vector from a feature-print observation. Vision
    /// exposes it as packed little-endian floats in `data`; we copy them out so
    /// the vector is persistable (the observation object itself is not).
    private static func vector(from observation: VNFeaturePrintObservation) -> [Float]? {
        guard observation.elementType == .float, observation.elementCount > 0 else { return nil }
        let count = observation.elementCount
        let data = observation.data
        guard data.count >= count * MemoryLayout<Float>.stride else { return nil }
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0, count: count * MemoryLayout<Float>.stride) }
        return floats
    }
}
