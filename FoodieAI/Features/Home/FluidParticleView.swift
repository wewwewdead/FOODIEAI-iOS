import SwiftUI
import UIKit
import MetalKit
import simd

/// SwiftUI host for the GPU particle-fluid "liquefy into the island" effect.
/// Wraps an `MTKView` whose `Coordinator` runs a Metal compute + render loop:
/// the meal photo is shattered into thousands of colored particles that are
/// advected toward the Dynamic Island by an attractor + divergence-free
/// curl-noise turbulence (see `FluidParticles.metal`), and drawn as soft
/// sprites that overlap into a liquid surface.
///
/// Self-timed: `progress` ramps 0→1 over `duration` while `isAnalyzing`, then
/// holds (gathered at the island); when analysis ends the parent can swap this
/// out. Foundation built behind a flag — final particle counts / forces want a
/// real-device tuning pass.
struct FluidParticleView: UIViewRepresentable {
    let image: UIImage
    /// Where the particles start (the photo card) and where they're sucked to.
    let cardRect: CGRect
    let target: CGPoint
    /// Where particles flow back to while dissolving (the app / result area).
    var returnTarget: CGPoint = .zero
    /// When true, run the return/dissolve phase instead of gathering.
    var returning: Bool = false
    var attract: Float = 2600
    var curlStrength: Float = 1100
    var pointDiameter: CGFloat = 10
    var duration: CFTimeInterval = 1.2
    var returnDuration: CFTimeInterval = 0.9
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image, cardRect: cardRect, target: target,
                    attract: attract, curl: curlStrength,
                    pointDiameter: pointDiameter, duration: duration,
                    returnDuration: returnDuration)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.contentMode = .redraw
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        c.islandTarget = target
        c.returnTarget = returnTarget == .zero ? CGPoint(x: cardRect.midX, y: cardRect.midY) : returnTarget
        c.setReturning(returning)
        c.isPaused = !isActive
        // Keep rendering through the return even if the tab's `isActive` flips,
        // so the dissolve completes.
        view.isPaused = !isActive && !returning
    }

    // MARK: - Renderer

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private var computePSO: MTLComputePipelineState?
        private var renderPSO: MTLRenderPipelineState?
        private var particles: MTLBuffer?
        private var particleCount = 0

        var islandTarget: CGPoint
        var returnTarget: CGPoint = .zero
        var isPaused = false
        private(set) var returning = false
        private var returnStart: CFTimeInterval = 0
        private let attract: Float
        private let curl: Float
        private let pointDiameter: CGFloat
        private let duration: CFTimeInterval
        private let returnDuration: CFTimeInterval

        private var viewSize: CGSize = .zero
        private var scale: CGFloat = 2
        private var startTime: CFTimeInterval = CACurrentMediaTime()
        private var lastTime: CFTimeInterval = CACurrentMediaTime()

        /// Flip into the return/dissolve phase, stamping the start time once.
        func setReturning(_ value: Bool) {
            guard value != returning else { return }
            returning = value
            if value { returnStart = CACurrentMediaTime() }
        }

        init(image: UIImage, cardRect: CGRect, target: CGPoint,
             attract: Float, curl: Float, pointDiameter: CGFloat,
             duration: CFTimeInterval, returnDuration: CFTimeInterval) {
            self.device = MTLCreateSystemDefaultDevice()!
            self.queue = device.makeCommandQueue()!
            self.islandTarget = target
            self.attract = attract
            self.curl = curl
            self.pointDiameter = pointDiameter
            self.duration = duration
            self.returnDuration = returnDuration
            super.init()
            buildPipelines()
            buildParticles(image: image, cardRect: cardRect)
        }

        private func buildPipelines() {
            guard let lib = device.makeDefaultLibrary() else { return }
            if let f = lib.makeFunction(name: "fluidSimulate") {
                computePSO = try? device.makeComputePipelineState(function: f)
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "fluidVertex")
            desc.fragmentFunction = lib.makeFunction(name: "fluidFragment")
            let c = desc.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one          // premultiplied
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            renderPSO = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // MARK: Particle init from the photo

        private func buildParticles(image: UIImage, cardRect: CGRect) {
            let gridW = 84, gridH = 84
            guard let px = Self.downsample(image, w: gridW, h: gridH) else { return }
            var arr: [FluidParticle] = []
            arr.reserveCapacity(gridW * gridH)
            for gy in 0..<gridH {
                for gx in 0..<gridW {
                    let c = px[gy * gridW + gx]
                    if c.w < 0.15 { continue }   // skip transparent cells
                    let x = cardRect.minX + (CGFloat(gx) + 0.5) / CGFloat(gridW) * cardRect.width
                    let y = cardRect.minY + (CGFloat(gy) + 0.5) / CGFloat(gridH) * cardRect.height
                    arr.append(FluidParticle(pos: SIMD2(Float(x), Float(y)),
                                             vel: .zero, color: c))
                }
            }
            particleCount = arr.count
            guard particleCount > 0 else { return }
            particles = device.makeBuffer(bytes: arr,
                                          length: arr.count * MemoryLayout<FluidParticle>.stride,
                                          options: .storageModeShared)
        }

        /// Center-crop to square, then downsample to a w×h RGBA grid (0…1 floats).
        private static func downsample(_ image: UIImage, w: Int, h: Int) -> [SIMD4<Float>]? {
            guard let cg = image.cgImage else { return nil }
            let side = min(cg.width, cg.height)
            let cropRect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2,
                                  width: side, height: side)
            let square = cg.cropping(to: cropRect) ?? cg

            let bpp = 4, bpr = w * bpp
            var buf = [UInt8](repeating: 0, count: w * h * bpp)
            let cs = CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bpr, space: cs, bitmapInfo: info) else { return nil }
            ctx.draw(square, in: CGRect(x: 0, y: 0, width: w, height: h))

            var out = [SIMD4<Float>]()
            out.reserveCapacity(w * h)
            var i = 0
            while i < buf.count {
                let a = Float(buf[i + 3]) / 255.0
                // un-premultiply for straight color
                let inv: Float = a > 0.001 ? 1.0 / a : 0
                out.append(SIMD4(Float(buf[i]) / 255.0 * inv,
                                 Float(buf[i + 1]) / 255.0 * inv,
                                 Float(buf[i + 2]) / 255.0 * inv, a))
                i += bpp
            }
            return out
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : 2
            viewSize = CGSize(width: size.width / scale, height: size.height / scale)  // points
        }

        func draw(in view: MTKView) {
            guard !isPaused,
                  let computePSO, let renderPSO, let particles, particleCount > 0,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            if viewSize == .zero {
                scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : 2
                viewSize = CGSize(width: view.drawableSize.width / scale,
                                  height: view.drawableSize.height / scale)
            }

            let now = CACurrentMediaTime()
            let dt = Float(min(1.0 / 30.0, max(0.0001, now - lastTime)))
            lastTime = now
            let elapsed = now - startTime
            let progress = Float(min(1.0, elapsed / duration))

            // Gather toward the island; on return, flow toward the card and
            // fade out over `returnDuration`.
            let tgt = returning ? returnTarget : islandTarget
            let fade: Float = returning
                ? Float(max(0.0, 1.0 - (now - returnStart) / returnDuration))
                : 1.0

            var u = FluidUniforms(
                target: SIMD2(Float(tgt.x), Float(tgt.y)),
                viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                progress: progress,
                time: Float(elapsed),
                dt: dt,
                attract: attract,
                curlStrength: curl,
                pointSize: Float(pointDiameter * scale),
                phase: returning ? 1.0 : 0.0,
                fade: fade
            )

            // Compute: advance the particles.
            if let ce = cmd.makeComputeCommandEncoder() {
                ce.setComputePipelineState(computePSO)
                ce.setBuffer(particles, offset: 0, index: 0)
                ce.setBytes(&u, length: MemoryLayout<FluidUniforms>.stride, index: 1)
                let tew = max(1, computePSO.threadExecutionWidth)
                ce.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1))
                ce.endEncoding()
            }

            // Render: draw the particles as point sprites.
            if let re = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                re.setRenderPipelineState(renderPSO)
                re.setVertexBuffer(particles, offset: 0, index: 0)
                re.setVertexBytes(&u, length: MemoryLayout<FluidUniforms>.stride, index: 1)
                re.setFragmentBytes(&u, length: MemoryLayout<FluidUniforms>.stride, index: 1)
                re.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
                re.endEncoding()
            }

            cmd.present(drawable)
            cmd.commit()
        }
    }
}

// MARK: - Shared layout (must match FluidParticles.metal)

struct FluidParticle {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var color: SIMD4<Float>
}

struct FluidUniforms {
    var target: SIMD2<Float>
    var viewSize: SIMD2<Float>
    var progress: Float
    var time: Float
    var dt: Float
    var attract: Float
    var curlStrength: Float
    var pointSize: Float
    var phase: Float   // 0 = gather, 1 = return
    var fade: Float    // global alpha
}
