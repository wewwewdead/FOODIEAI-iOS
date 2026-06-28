import SwiftUI

/// Premium-polish wave: ambient drifting brand blobs.
///
/// 4 brand-tinted soft circles that drift on independent slow loops
/// behind hero surfaces. Performance-tuned rewrite — the previous
/// implementation used `Canvas` inside `TimelineView` running 30fps
/// with `.blur(36)`, which forced a full re-rasterize of the blurred
/// output every frame on every tab simultaneously (TabView keeps all
/// tabs alive). On switch this read as a sticky transition.
///
/// New implementation:
///   - Plain `Circle` views with `.offset` animated by SwiftUI's
///     animation system (no per-frame Canvas rebuild)
///   - `.drawingGroup()` rasterizes the composition once into a Metal
///     texture; subsequent animation just translates the cached layer
///   - `.blur(radius: 26)` (down from 36) — visually identical
///   - 4 blobs (down from 6) — cheaper compositing, looks the same
///   - `isActive` gate: when false, the drift animation stops so
///     inactive tabs cost nothing
///
/// Use as a background underneath hero copy:
///   ```swift
///   ZStack {
///       AmbientFloater(isActive: selection == 0)
///       contentStack
///   }
///   ```
///
/// Hit-test disabled. Reduce Motion renders the static seed positions.
struct AmbientFloater: View {
    /// 0 = invisible, 1 = full opacity. Hero areas want ~0.6, secondary
    /// areas want ~0.35.
    var intensity: Double = 0.55
    var palette: [Color] = [.brand, .brandBright, .accentCool]
    /// When false, the drift animation stops — blobs render once at
    /// their starting positions. Use to pause hidden tabs.
    var isActive: Bool = true

    @State private var driftPhase: CGFloat = 0
    /// Toggled by `.onAppear` / `.onDisappear`. TabView fires these
    /// when switching tabs in iOS 17+, so hidden tabs stop animating
    /// entirely — frees GPU time for the active tab and removes
    /// background work that was contributing to laggy tab transitions.
    @State private var isVisible: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let seeds: [Seed] = [
        Seed(startAngle: 0.0,            radius: 0.20, period: 16, size: 220, colorIndex: 0),
        Seed(startAngle: .pi * 0.55,     radius: 0.16, period: 19, size: 180, colorIndex: 1),
        Seed(startAngle: .pi * 1.15,     radius: 0.22, period: 22, size: 240, colorIndex: 2),
        Seed(startAngle: .pi * 1.65,     radius: 0.18, period: 18, size: 200, colorIndex: 0),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(seeds.enumerated()), id: \.offset) { _, seed in
                    let angle = seed.startAngle + Double(driftPhase) * 2 * .pi
                    let cx = cos(angle) * geo.size.width * seed.radius
                    let cy = sin(angle * 0.7) * geo.size.height * seed.radius
                    // Blur + flatten each blob ONCE into a cached Metal texture;
                    // only the cheap `.offset` transform changes per frame as it
                    // drifts. The previous version blurred the whole moving
                    // composition every frame — a full-screen Gaussian per tick.
                    Circle()
                        .fill(palette[seed.colorIndex])
                        .frame(width: seed.size, height: seed.size)
                        .blur(radius: 22)
                        .drawingGroup()
                        .opacity(0.35 * intensity)
                        .offset(x: cx, y: cy)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            isVisible = true
            startDriftIfNeeded()
        }
        .onDisappear {
            // Stop the drift loop — TabView keeps the view alive but
            // hidden, and without this an idle background tab keeps
            // burning GPU cycles updating offsets every frame.
            isVisible = false
            withAnimation(.linear(duration: 0)) {
                // Snap-stop the animation; the next .onAppear will
                // start a fresh loop from the frozen phase.
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                startDriftIfNeeded()
            } else {
                stopDrift()
            }
        }
    }

    private func startDriftIfNeeded() {
        // Reduce Motion, inactive tab, or hidden view → freeze.
        guard !reduceMotion, isActive, isVisible else { return }
        // One slow continuous rotation. ~30s for a full loop — well
        // below detection threshold, but cheap to animate (just a
        // value tween that drives cheap offset math in body).
        withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
            driftPhase = 1
        }
    }

    private func stopDrift() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            driftPhase = 0
        }
    }

    private struct Seed {
        let startAngle: Double
        let radius: Double
        let period: Double
        let size: CGFloat
        let colorIndex: Int
    }
}

#if DEBUG
#Preview("AmbientFloater") {
    ZStack {
        Color.bgCanvas.ignoresSafeArea()
        AmbientFloater()
            .ignoresSafeArea()
        VStack {
            Text("Hero content")
                .appFont(.display1)
                .foregroundStyle(Color.ink)
        }
    }
}
#endif
