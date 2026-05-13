import SwiftUI

/// Phase 14 delight pass: a particle burst rendered behind a focal point
/// (typically a checkmark or hero number) on success moments.
///
/// Particles are seeded once on init with random color, shape, size,
/// trajectory, rotation, and stagger. When the bound `active` flag
/// flips from false → true the particles fly outward, rotate, and fade
/// over ~1.0 s using `.spring(response: 1.0, dampingFraction: 0.85)`.
/// They return to origin when `active` flips back to false (free —
/// implicit `withAnimation` reverses each modifier).
///
/// Usage: place behind a focal element inside a `ZStack`; toggle `active`
/// at the moment of celebration.
///
///     ConfettiBurst(active: explode)
///     Image(systemName: "checkmark.circle.fill")
///
/// The view is hit-test transparent so it never intercepts taps from the
/// element it celebrates.
struct ConfettiBurst: View {
    /// Flip false → true to fire. Flipping back to false reverses the
    /// animation (particles return to origin) — useful for re-trigger.
    let active: Bool

    /// Number of particles. 18–24 reads as "celebration" without
    /// overwhelming the small surface a sheet/result-card carries.
    var count: Int = 22

    /// Maximum distance any particle travels from center (points).
    /// Default 130 fits inside a 280pt-wide focal area on iPhone.
    var spread: CGFloat = 130

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let particles: [Particle]

    init(active: Bool, count: Int = 22, spread: CGFloat = 130) {
        self.active = active
        self.count = count
        self.spread = spread
        self.particles = Self.makeParticles(count: count, spread: spread)
    }

    var body: some View {
        ZStack {
            // Reduce Motion suppresses the burst entirely — celebration is
            // delivered by the checkmark stamp + haptic instead. Returning
            // an empty ZStack keeps the parent layout untouched.
            if !reduceMotion {
                ForEach(particles) { p in
                    particleShape(p)
                        .frame(width: p.size, height: p.size * p.aspect)
                        .foregroundStyle(p.color)
                        .rotationEffect(active ? p.endRotation : .degrees(0))
                        .offset(active ? p.offset : .zero)
                        .opacity(active ? 0 : 1)
                        .animation(
                            .spring(response: 1.0, dampingFraction: 0.85)
                                .delay(p.delay),
                            value: active
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func particleShape(_ p: Particle) -> some View {
        switch p.shape {
        case .square:  RoundedRectangle(cornerRadius: 1.5)
        case .circle:  Circle()
        case .capsule: Capsule()
        }
    }

    // MARK: - Particle generation

    private struct Particle: Identifiable {
        let id = UUID()
        let color: Color
        let shape: Shape
        let size: CGFloat
        let aspect: CGFloat       // 1.0 = square; <1 = horizontal capsule
        let offset: CGSize
        let endRotation: Angle
        let delay: Double
    }

    private enum Shape { case square, circle, capsule }

    private static func makeParticles(count: Int, spread: CGFloat) -> [Particle] {
        let palette: [Color] = [
            .brand,
            .brandDeep,
            .accentWarm,
            .accentCool,
            .success
        ]
        return (0..<count).map { i in
            // Distribute angles roughly evenly around 360° with jitter so
            // the burst reads as "starburst" rather than "random cloud".
            let baseAngle = Double(i) / Double(count) * 2 * .pi
            let jitter = Double.random(in: -0.25...0.25)
            let angle = baseAngle + jitter
            let distance = CGFloat.random(in: spread * 0.55 ... spread)
            let shape: Shape = [.square, .circle, .capsule].randomElement()!
            let size: CGFloat = .random(in: 6 ... 11)
            let aspect: CGFloat = (shape == .capsule) ? 0.35 : 1.0

            return Particle(
                color: palette.randomElement()!,
                shape: shape,
                size: size,
                aspect: aspect,
                offset: CGSize(
                    width:  cos(angle) * distance,
                    height: sin(angle) * distance - 8 // bias slightly upward
                ),
                endRotation: .degrees(.random(in: -300...300)),
                delay: Double.random(in: 0 ... 0.08)
            )
        }
    }
}

#if DEBUG
#Preview("ConfettiBurst — toggle to fire") {
    struct PreviewHost: View {
        @State private var active = false
        var body: some View {
            ZStack {
                Color.bgSurface.ignoresSafeArea()
                VStack(spacing: AppSpacing.lg) {
                    ZStack {
                        ConfettiBurst(active: active)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 96, weight: .regular))
                            .foregroundStyle(Color.brand)
                    }
                    .frame(width: 280, height: 220)

                    PrimaryButton(title: active ? "Reset" : "Celebrate",
                                  leadingSystemImage: active ? "arrow.counterclockwise" : "sparkles") {
                        active.toggle()
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
            }
        }
    }
    return PreviewHost()
}
#endif
