import SwiftUI

/// A fully GPU-rendered, interactive aurora UI backdrop (Metal `colorEffect`
/// shader — see `AuroraBackdrop.metal`). A brand-colored flow field slowly
/// morphs over time, and a warm light bloom follows the user's touch, the flow
/// bending toward it. Drop it behind a screen's content:
///
///     ZStack { MetalBackdrop(); content }
///
/// Notes:
/// - Driven by a `TimelineView` clock; pass `isActive: false` (e.g. for an
///   off-screen tab) to PAUSE it — a full-screen procedural shader runs the GPU
///   continuously, so don't leave it animating where it isn't seen.
/// - Reduce Motion freezes the field (no per-frame redraw) and keeps the touch
///   bloom only.
struct MetalBackdrop: View {
    /// Pause the per-frame animation when the host isn't visible.
    var isActive: Bool = true
    /// How long the touch bloom lingers after release.
    var bloomFade: Double = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touch: CGPoint = .zero
    @State private var pressing = false
    @State private var releaseDate = Date.distantPast
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            TimelineView(.animation(paused: !isActive || reduceMotion)) { timeline in
                let now = timeline.date
                let t = reduceMotion ? 0 : now.timeIntervalSince(start)
                // Deterministic bloom decay (computed per frame so it's smooth
                // without relying on @State animation through the shader arg).
                let influence: Double = pressing
                    ? 1.0
                    : max(0, 1.0 - now.timeIntervalSince(releaseDate) / bloomFade)
                let p = touch == .zero ? center : touch

                Rectangle()
                    .colorEffect(
                        ShaderLibrary.auroraBackdrop(
                            .float2(Float(geo.size.width), Float(geo.size.height)),
                            .float(Float(t)),
                            .float2(Float(p.x), Float(p.y)),
                            .float(Float(influence))
                        )
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touch = value.location
                        pressing = true
                    }
                    .onEnded { _ in
                        pressing = false
                        releaseDate = Date()
                    }
            )
        }
        .ignoresSafeArea()
    }
}
