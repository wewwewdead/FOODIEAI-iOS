import SwiftUI

/// Premium-polish wave: brand-petal confetti.
///
/// A celebratory burst of cutesy brand glyphs (hearts, leaves, sparks)
/// that explode outward and gently rotate as they settle. Used on
/// save-success, quest-complete, and goal-reached moments.
///
/// Composes with `ConfettiBurst` (the existing particle-square burst);
/// this one is the cutesy companion that fires on top for a softer,
/// more on-brand celebration.
///
/// Pure visual layer — hit-test disabled, suppressed under Reduce Motion.
struct BrandConfetti: View {
    /// Flip true to trigger the burst. The view animates from rest to
    /// the burst configuration; set false to remove from the tree.
    let active: Bool

    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 14 cutesy glyphs in brand colors. Seeded once so the
    /// composition is stable across renders.
    private let particles: [Particle] = (0..<14).map { i in
        let glyphs = ["heart.fill", "leaf.fill", "sparkle", "star.fill", "drop.fill"]
        let palette: [Color] = [.brand, .brandBright, .accentWarm, .success, .brandDeep]
        let seed = Double(i)
        return Particle(
            glyph: glyphs[i % glyphs.count],
            color: palette[i % palette.count],
            angle: (seed / 14.0) * 2 * .pi + Double.random(in: -0.2...0.2),
            distance: 90 + CGFloat.random(in: 0...60),
            size: 14 + CGFloat(i % 4) * 4,
            rotation: Double.random(in: -120...120),
            delay: Double(i) * 0.018
        )
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            ZStack {
                ForEach(Array(particles.enumerated()), id: \.offset) { _, p in
                    Image(systemName: p.glyph)
                        .font(.system(size: p.size, weight: .heavy))
                        .foregroundStyle(p.color)
                        .scaleEffect(revealed ? 1.0 : 0.0)
                        .opacity(revealed ? 0 : 1)
                        .offset(
                            x: revealed ? cos(p.angle) * p.distance : 0,
                            y: revealed ? sin(p.angle) * p.distance : 0
                        )
                        .rotationEffect(.degrees(revealed ? p.rotation : 0))
                        .animation(
                            .spring(response: 1.2, dampingFraction: 0.7)
                                .delay(p.delay),
                            value: revealed
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                if active { revealed = true }
            }
            .onChange(of: active) { _, newValue in
                if newValue { revealed = true }
            }
        }
    }

    private struct Particle {
        let glyph: String
        let color: Color
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
        let rotation: Double
        let delay: Double
    }
}
