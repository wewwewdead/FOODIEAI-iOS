import SwiftUI

/// Phase 22 — tier indicator for Profile (and anywhere else we want to
/// show the user what plan they're on).
///
/// Two visual states keyed on `SubscriptionManager.Tier`:
///   • `.free` — quiet capsule, neutral palette, no motion. The point
///     of free is that it's invisible until contrasted against pro;
///     the badge confirms tier without nagging.
///   • `.pro` — a "jewel-coin" capsule: pearlescent gold→peach gradient
///     with a glossy inner highlight, twinkling sparkles flanking the
///     crown, a slow diagonal shine sweep, and a soft outer halo that
///     gently breathes. The whole thing wants to feel like a tiny
///     enamel pin — cutesy, but minted. Respects
///     `accessibilityReduceMotion` — when ON every animation is killed
///     and only the static gradient + halo render.
///
/// Rendering is pure SwiftUI: gold is hand-mixed from RGB literals
/// (the design system doesn't have a canonical premium palette yet).
/// If brand-aligned premium tokens are added later, swap the stops on
/// `Self.gold*` without touching the geometry.
struct TierBadge: View {
    let tier: SubscriptionManager.Tier

    var body: some View {
        switch tier {
        case .free:  freeBadge
        case .pro:   ProBadgeShine()
        }
    }

    private var freeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 11, weight: .heavy))
            Text("Free")
                .appFont(.captionStrong)
                .tracking(0.3)
        }
        .foregroundStyle(Color.inkMute)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.bgSurface))
        .overlay(
            Capsule().strokeBorder(Color.inkMute.opacity(0.18), lineWidth: 1)
        )
    }
}

/// The pro badge, factored out so it can hold its own `@State` for the
/// shine + sparkle + breathing animations without forcing every render
/// of the parent view to re-animate.
private struct ProBadgeShine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false
    @State private var breathe = false
    @State private var sparkleA = false
    @State private var sparkleB = false

    // Pearlescent gold → peach. Five stops give the capsule a real
    // jewel feel: a deeper amber at the corners, a creamy champagne
    // through the middle, and a faint rose blush to keep it warm and
    // a touch cutesy instead of straight metallic. Tokens live on
    // `ProGold` so the avatar ring and analyzing tint share them.
    private static let goldEdgeDark = ProGold.edgeDark
    private static let goldWarm     = ProGold.warm
    private static let goldCream    = ProGold.cream
    private static let goldRose     = ProGold.rose
    private static let goldDeep     = ProGold.deep

    var body: some View {
        HStack(spacing: 5) {
            sparkle(active: sparkleA)
                .frame(width: 7, height: 7)

            Image(systemName: "crown.fill")
                .font(.system(size: 11, weight: .heavy))
                // Soft inner shadow on the crown so it reads as
                // embossed into the badge rather than floating on top.
                .shadow(color: Self.goldDeep.opacity(0.55), radius: 0.5, x: 0, y: 0.5)

            Text("PRO")
                .appFont(.captionStrong)
                .tracking(0.7)

            sparkle(active: sparkleB)
                .frame(width: 7, height: 7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(capsuleBackground)
        .overlay(capsuleRim)
        .overlay(glossyTopHighlight)
        .overlay(shineSweep)
        .background(outerHalo)
        .scaleEffect(breathe ? 1.025 : 1.0)
        .shadow(color: Self.goldWarm.opacity(0.45), radius: 8, x: 0, y: 3)
        .shadow(color: Self.goldRose.opacity(0.25), radius: 14, x: 0, y: 6)
        .onAppear(perform: startAnimations)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pro plan")
    }

    // MARK: - Background layers

    // The metallic base. Diagonal sweep through five stops produces a
    // creamy champagne core with deeper amber on the corners and a
    // hint of rose blush — premium, but warm enough to feel like a
    // little enamel pin rather than a cold gold bar.
    private var capsuleBackground: some View {
        Capsule().fill(
            LinearGradient(
                stops: [
                    .init(color: Self.goldEdgeDark, location: 0.0),
                    .init(color: Self.goldWarm,     location: 0.25),
                    .init(color: Self.goldCream,    location: 0.55),
                    .init(color: Self.goldRose,     location: 0.78),
                    .init(color: Self.goldEdgeDark, location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // Two-tone rim — brighter at the top, darker at the bottom — gives
    // the capsule a beveled "minted coin" silhouette without needing
    // an extra outline layer.
    private var capsuleRim: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.85),
                        Self.goldDeep.opacity(0.55),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
    }

    // Glossy top crescent. A radial highlight clipped to the top half
    // of the capsule gives the jelly/enamel sheen that sells the
    // "premium pin" feel.
    private var glossyTopHighlight: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.55),
                        Color.white.opacity(0.0),
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    // Slow diagonal sweep. Soft (max 35% white), wide-band, and
    // clipped to the capsule so the glint stays inside the pill.
    @ViewBuilder
    private var shineSweep: some View {
        if !reduceMotion {
            Capsule().fill(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.35),
                        .clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .rotationEffect(.degrees(18))
            .offset(x: shimmer ? 140 : -140)
            .mask(Capsule())
            .allowsHitTesting(false)
        }
    }

    // Soft outer halo that breathes. This is the "premium aura" — a
    // blurred warm glow placed behind the capsule. It does most of
    // the work selling pro-ness when the badge sits on a calm bg.
    private var outerHalo: some View {
        Capsule()
            .fill(
                RadialGradient(
                    colors: [
                        Self.goldCream.opacity(0.55),
                        Self.goldRose.opacity(0.25),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 4,
                    endRadius: 38
                )
            )
            .blur(radius: 8)
            .scaleEffect(breathe ? 1.25 : 1.10)
            .opacity(breathe ? 0.95 : 0.70)
            .allowsHitTesting(false)
    }

    // MARK: - Sparkle decoration

    // Tiny four-point sparkle that twinkles in/out. We draw it from
    // two crossed diamonds so the shape stays crisp at 7pt — SF
    // Symbols' "sparkle" reads as a generic star at this size.
    private func sparkle(active: Bool) -> some View {
        ZStack {
            SparkleShape()
                .fill(Color.white)
                .shadow(color: Self.goldCream.opacity(0.9), radius: 2)
        }
        .scaleEffect(active ? 1.0 : 0.35)
        .opacity(active ? 1.0 : 0.25)
    }

    // MARK: - Animation orchestration

    private func startAnimations() {
        guard !reduceMotion else { return }

        // Shine sweep — slow, ~3.4s end-to-end with a long pause built
        // in by the offset distance. Faster feels gimmicky; this lets
        // the glint land like a deliberate moment of delight.
        withAnimation(.linear(duration: 3.4).repeatForever(autoreverses: false)) {
            shimmer = true
        }

        // Breathing halo. Very slow, very subtle — barely perceptible
        // per-frame but the badge feels alive when you stop to look.
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
            breathe = true
        }

        // Staggered sparkle twinkles. Out-of-phase so they read as
        // independent little stars instead of a metronome.
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            sparkleA = true
        }
        withAnimation(
            .easeInOut(duration: 1.6)
                .repeatForever(autoreverses: true)
                .delay(0.7)
        ) {
            sparkleB = true
        }
    }
}

// MARK: - Shared pro/gold palette

/// Shared gold palette so the badge, the avatar ring, the analyzing
/// aura tint, and the save sparkle all read as the same "pro" gold.
/// Pulled out of `ProBadgeShine` so other surfaces can use the same
/// stops without copy-pasting hex literals.
enum ProGold {
    static let edgeDark = Color(red: 0.706, green: 0.498, blue: 0.082) // #B47F15
    static let warm     = Color(red: 0.910, green: 0.706, blue: 0.231) // #E8B43B
    static let cream    = Color(red: 1.000, green: 0.918, blue: 0.659) // #FFEAA8
    static let rose     = Color(red: 0.988, green: 0.792, blue: 0.620) // #FCCA9E
    static let deep     = Color(red: 0.612, green: 0.380, blue: 0.027) // #9C6107

    /// Angular gradient stops for spinning ring effects. Wraps back to
    /// the starting color so the rotation has no visible seam.
    static let angularStops: [Gradient.Stop] = [
        .init(color: edgeDark, location: 0.00),
        .init(color: cream,    location: 0.25),
        .init(color: rose,     location: 0.50),
        .init(color: warm,     location: 0.75),
        .init(color: edgeDark, location: 1.00),
    ]
}

// MARK: - Avatar ring

/// Animated gold gradient ring sized to overlay a circular avatar. The
/// gradient angle rotates on a slow loop so the ring shimmers without
/// being distracting. Render via `.proAvatarRing(active:)`.
///
/// Perf notes:
///   • No `.shadow(...)` on the rotating layer. A colored shadow on a
///     continuously rotating gradient forces the GPU to re-rasterize
///     every frame and was measurably stalling the FloatingTabBar
///     spring when switching to Profile (whose backdrop already
///     stacks AuroraWash + AmbientFloater + two large blurred radial
///     gradients). The gradient alone reads as gold-on-page; the
///     shadow added negligible visual weight for its cost.
///   • Rotation slowed from 8s → 16s. Visually identical at glance —
///     the eye can't tell at this speed — but halves the per-second
///     animation work, which matters on the tab-transition frame
///     budget.
struct ProAvatarRing: View {
    let isActive: Bool
    var lineWidth: CGFloat = 2.5
    /// Negative inset so the ring sits *outside* the underlying avatar
    /// rather than overlapping its edge. Pass `0` to draw on the rim.
    var inset: CGFloat = -3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        if isActive {
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(stops: ProGold.angularStops),
                        center: .center
                    ),
                    lineWidth: lineWidth
                )
                .padding(inset)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .allowsHitTesting(false)
                // Defer the rotation start so it doesn't compete with
                // the FloatingTabBar's tab-switch spring (~0.42s) or
                // the host page's entrance animations. .task auto-
                // cancels on disappear; .onAppear-with-DispatchQueue
                // would survive disappear and cause animation leaks
                // on rapid tab toggles.
                .task {
                    guard !reduceMotion else { return }
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Adds the rotating gold ring overlay for Pro users. No-op when
    /// `active` is false, so callers can pass `subscriptions.tier == .pro`
    /// directly without an `if`.
    func proAvatarRing(active: Bool, lineWidth: CGFloat = 2.5, inset: CGFloat = -3) -> some View {
        overlay(
            ProAvatarRing(isActive: active, lineWidth: lineWidth, inset: inset)
        )
    }
}

// MARK: - Gold sparkle burst

/// Save-success delight layered on top of the existing brand confetti
/// for Pro users only. Slightly slower spring and a smaller particle
/// count than `BrandConfetti` so it reads as a refined "your moment"
/// sparkle rather than a second explosion. Pure visual — hit-test
/// disabled, suppressed under Reduce Motion.
struct GoldSparkleBurst: View {
    let active: Bool

    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ten gold particles seeded once for stable composition. Mix of
    /// SF Symbols that read well at small sizes; weights skew toward
    /// the warm/cream stops so the burst feels champagne rather than
    /// raw amber.
    private let particles: [Particle] = (0..<10).map { i in
        let glyphs = ["sparkle", "star.fill", "sparkles", "drop.fill"]
        let palette: [Color] = [
            ProGold.warm,
            ProGold.cream,
            ProGold.rose,
            ProGold.warm,
            ProGold.cream,
        ]
        let seed = Double(i)
        return Particle(
            glyph: glyphs[i % glyphs.count],
            color: palette[i % palette.count],
            angle: (seed / 10.0) * 2 * .pi + Double.random(in: -0.18...0.18),
            distance: 70 + CGFloat.random(in: 0...40),
            size: 11 + CGFloat(i % 3) * 3,
            rotation: Double.random(in: -90...90),
            delay: Double(i) * 0.022
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
                        .shadow(color: ProGold.warm.opacity(0.5), radius: 2)
                        .scaleEffect(revealed ? 1.0 : 0.0)
                        .opacity(revealed ? 0 : 1)
                        .offset(
                            x: revealed ? cos(p.angle) * p.distance : 0,
                            y: revealed ? sin(p.angle) * p.distance : 0
                        )
                        .rotationEffect(.degrees(revealed ? p.rotation : 0))
                        .animation(
                            .spring(response: 1.35, dampingFraction: 0.72)
                                .delay(p.delay),
                            value: revealed
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { if active { revealed = true } }
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

/// Four-point sparkle — two crossed concave diamonds. Stays sharp at
/// small sizes where SF Symbols' "sparkle" gets mushy.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        // Pinch controls how concave the diamond is — smaller value =
        // skinnier, more star-like points.
        let pinch: CGFloat = 0.18

        var p = Path()
        // Vertical diamond, concave sides
        p.move(to:    CGPoint(x: cx,                    y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: cy),
                       control: CGPoint(x: cx + w * pinch, y: cy - h * pinch))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.maxY),
                       control: CGPoint(x: cx + w * pinch, y: cy + h * pinch))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: cy),
                       control: CGPoint(x: cx - w * pinch, y: cy + h * pinch))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.minY),
                       control: CGPoint(x: cx - w * pinch, y: cy - h * pinch))
        p.closeSubpath()
        return p
    }
}

#if DEBUG
#Preview("Tier badges") {
    VStack(spacing: 24) {
        TierBadge(tier: .free)
        TierBadge(tier: .pro)
        TierBadge(tier: .pro)
            .scaleEffect(1.6)
            .padding(.top, 12)
    }
    .padding(40)
    .background(Color.bgCanvas)
}
#endif
