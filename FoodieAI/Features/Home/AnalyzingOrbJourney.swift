import SwiftUI
import UIKit

/// The "analyzing" hero moment: the meal photo becomes a living **Siri-style
/// bubble** — a gooey metaball that morphs continuously — and genie-travels up
/// to just below the notch / Dynamic Island to "think," then back down and
/// dissolves into the next step.
///
/// In-app illusion (iOS won't let an app animate into the real, system-owned
/// Dynamic Island, which is always drawn on top — so the orb docks just *below*
/// it and its glow reaches up).
///
/// Performance: the bubble is one `Canvas` metaball mask flattened with
/// `.drawingGroup()` (a single Metal pass), not a stack of blurred/blended
/// SwiftUI layers — and the whole thing is driven off one `TimelineView` clock,
/// with travel/breathe/wobble applied as GPU transforms (`scaleEffect`/
/// `position`), so nothing re-lays-out or re-blurs per frame.

// MARK: - Shared timing

/// Timing the rest of the analyze flow coordinates against, so the genie
/// warp-back and the result reveal never drift apart.
enum AnalyzingOrbTiming {
    /// How long, after the orb starts its return, the warp reads as "landed"
    /// (the orb has dissolved). The result content + typewriter hold this long
    /// before flowing in, so the genie warp visibly plays *first* — then the
    /// breakdown reveals as the orb finishes vanishing (a clean crossfade, no
    /// text typing on top of a mid-warp orb).
    ///
    /// Tuned to `AnalyzingOrb.fallDuration` (1.05s): the orb's opacity
    /// (`returnFade`) reaches ~0 around 0.85s into the descent, so the reveal
    /// lands right as it disappears. Also covers the SPH-fluid return (0.9s).
    static let returnSettleSeconds: TimeInterval = 0.85
}

// MARK: - Source-frame plumbing

/// Captures the meal photo's on-screen frame (in GLOBAL coords) so the orb
/// knows where to launch from and return to. Published by the photo card; the
/// overlay reads it into `@State` so the value SURVIVES the card disappearing at
/// `.ready` (otherwise the return animation would have nowhere to fly home to,
/// and the overlay subtree would rebuild). `.zero` means "no card right now".
struct OrbSourceRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Overlay host

struct AnalyzingOrbJourneyModifier: ViewModifier {
    let image: UIImage?
    let isAnalyzing: Bool
    let palette: [Color]
    let isPro: Bool
    let isActive: Bool
    let enabled: Bool
    /// When on, the analyzing visual is the GPU particle fluid (the photo
    /// shatters into particles that flow into the island) instead of the
    /// shader genie + metaball orb.
    let useFluid: Bool

    /// Last known photo-card frame (global). Captured while the card exists and
    /// RETAINED after it disappears at `.ready`, so the return animation still
    /// knows where home is.
    @State private var lastCard: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // Capture the card frame into @State (survives the card vanishing).
            .onPreferenceChange(OrbSourceRectKey.self) { rect in
                if rect != .zero { lastCard = rect }
            }
            // STABLE overlay (plain `.overlay`, not preference-driven) so the
            // journey view keeps its identity/@State across the card→result
            // body swap — otherwise the return would reset and never play.
            .overlay {
                GeometryReader { outer in
                    let safeTop = outer.safeAreaInsets.top
                    GeometryReader { full in
                        if enabled, let image {
                            let card = lastCard != .zero ? lastCard
                                : CGRect(x: full.size.width / 2 - 150,
                                         y: full.size.height * 0.42 - 150,
                                         width: 300, height: 300)
                            if useFluid {
                                FluidOrbJourney(
                                    image: image,
                                    isThinking: isAnalyzing,
                                    cardRect: card,
                                    islandTarget: CGPoint(x: full.size.width / 2,
                                                          y: max(34, safeTop) + 24),
                                    returnTarget: CGPoint(x: full.size.width / 2,
                                                          y: full.size.height * 0.42),
                                    isActive: isActive,
                                    canvas: full.size,
                                    safeTop: safeTop,
                                    glowColor: palette.first ?? Color(red: 0.15, green: 0.86, blue: 1.0)
                                )
                            } else {
                                AnalyzingOrb(
                                    image: image,
                                    isAnalyzing: isAnalyzing,
                                    palette: palette,
                                    isPro: isPro,
                                    isActive: isActive,
                                    source: lastCard != .zero ? lastCard : nil,
                                    canvas: full.size,
                                    safeTop: safeTop
                                )
                            }
                        }
                    }
                    .ignoresSafeArea()
                }
                .allowsHitTesting(false)
            }
    }
}

// MARK: - SPH particle fluid journey (mount + return lifecycle)

/// Wraps `FluidParticleView` with the same up→hold→back lifecycle as the genie
/// orb: stays mounted (gathering / swirling at the island) for the whole
/// thinking window, then runs the RETURN phase (particles flow back to the app
/// and dissolve) before unmounting — so the particle mode flows home too,
/// instead of vanishing.
struct FluidOrbJourney: View {
    let image: UIImage
    let isThinking: Bool
    let cardRect: CGRect
    let islandTarget: CGPoint
    let returnTarget: CGPoint
    let isActive: Bool
    /// For the black Dynamic Island pouch the particles swirl inside.
    let canvas: CGSize
    let safeTop: CGFloat
    let glowColor: Color

    @State private var mounted = false
    @State private var returning = false
    @State private var pouchOn = false
    @State private var hideTask: Task<Void, Never>?
    @State private var pouchTask: Task<Void, Never>?
    @State private var pulseTask: Task<Void, Never>?
    private static let returnDuration: CFTimeInterval = 0.9

    private var hasIsland: Bool { safeTop > 51 }

    var body: some View {
        ZStack {
            if mounted {
                // Black "expanded island" pouch behind the particles so the
                // liquid reads as swirling inside the Dynamic Island. Fades in
                // as the particles arrive, out as they flow home.
                if hasIsland {
                    IslandExtension(canvasSize: canvas, bulbCenter: islandTarget,
                                    bulbDiameter: 90, glowColor: glowColor)
                        .opacity(pouchOn ? 1 : 0)
                        .animation(.easeOut(duration: 0.3), value: pouchOn)
                }
                FluidParticleView(
                    image: image,
                    cardRect: cardRect,
                    target: islandTarget,
                    returnTarget: returnTarget,
                    returning: returning,
                    returnDuration: Self.returnDuration,
                    isActive: isActive
                )
            }
        }
        .onAppear { sync() }
        .onChange(of: isThinking) { _, _ in sync() }
        .onDisappear { hideTask?.cancel(); pouchTask?.cancel(); pulseTask?.cancel() }
    }

    private func sync() {
        hideTask?.cancel()
        pouchTask?.cancel()
        pulseTask?.cancel()
        if isThinking {
            let firstLaunch = !mounted
            mounted = true
            returning = false
            if firstLaunch {
                Haptics.prepare()
                Haptics.tap()          // launch
            }
            // Reveal the pouch once the particles have nearly reached the island.
            pouchOn = false
            pouchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled else { return }
                pouchOn = true
                Haptics.soft()         // dock
                pulseTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_300_000_000)
                        guard !Task.isCancelled else { return }
                        Haptics.soft() // thinking heartbeat
                    }
                }
            }
        } else if mounted {
            returning = true   // flow home + dissolve, then unmount
            pouchOn = false    // pouch fades as the liquid leaves
            Haptics.soft()     // release
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.returnDuration * 1_000_000_000) + 120_000_000)
                guard !Task.isCancelled else { return }
                mounted = false
                returning = false
                Haptics.tap()  // settle
            }
        }
    }
}

// MARK: - The orb

private struct AnalyzingOrb: View {
    let image: UIImage
    let isAnalyzing: Bool
    let palette: [Color]
    let isPro: Bool
    let isActive: Bool
    let source: CGRect?
    let canvas: CGSize
    let safeTop: CGFloat

    enum Leg { case hidden, toNotch, returning }
    @State private var leg: Leg = .hidden
    @State private var legStart = Date()
    @State private var mounted = false
    @State private var hideTask: Task<Void, Never>?
    /// The black island pouch — a plain animated opacity (not a per-frame
    /// redraw), since its shape never changes once docked.
    @State private var pouchOn = false
    @State private var pouchTask: Task<Void, Never>?
    /// Gentle "thinking" haptic heartbeat while the orb swirls at the island.
    @State private var pulseTask: Task<Void, Never>?

    /// Slow + luxurious so the fluid flow is savorable (was 0.95 — felt rushed).
    private static let riseDuration: Double = 1.75
    /// The return flows home a touch quicker than the rise, but still smooth.
    private static let fallDuration: Double = 1.05
    /// Fixed reference size the bubble is drawn at; the actual on-screen size is
    /// a GPU `scaleEffect`, so travel never triggers a per-frame layout/redraw
    /// of the Canvas at a new size.
    private static let referenceSide: CGFloat = 300

    private var sourceCenter: CGPoint {
        if let s = source { return CGPoint(x: s.midX, y: s.midY) }
        return CGPoint(x: canvas.width / 2, y: canvas.height * 0.42)
    }
    private var sourceSide: CGFloat {
        if let s = source { return min(s.width, s.height) }
        return min(canvas.width - 48, 300)
    }
    /// The genie's launch/return rectangle (the card), in overlay coords.
    private var srcRect: CGRect {
        if let s = source { return s }
        let side = sourceSide
        return CGRect(x: sourceCenter.x - side / 2, y: sourceCenter.y - side / 2,
                      width: side, height: side)
    }
    /// Dynamic-Island devices report a tall safe-area top (~59pt). On those we
    /// draw a black "expanded island" pouch (see `IslandExtension`) and seat the
    /// orb inside it; on notch/flat devices the orb just docks below the status
    /// bar (no fake pouch to mismatch).
    private var hasIsland: Bool { safeTop > 51 }
    private var dockCenter: CGPoint {
        let y: CGFloat = hasIsland ? 74 : max(28, safeTop) + 22
        return CGPoint(x: canvas.width / 2, y: y)
    }
    private var dockSide: CGFloat { 60 }
    /// Black pouch diameter — a touch larger than the orb so a thin island-black
    /// rim cradles it.
    private var bulbDiameter: CGFloat { dockSide + 24 }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }

    var body: some View {
        Color.clear
            .overlay { if mounted { living } }
            .onAppear { sync(animated: false) }
            .onChange(of: isAnalyzing) { _, _ in sync(animated: true) }
            .onDisappear { hideTask?.cancel(); pouchTask?.cancel(); pulseTask?.cancel() }
    }

    private var living: some View {
        ZStack {
            // Static black pouch — rendered ONCE (not inside the clock) and only
            // fades via an animated opacity, so it never re-rasterizes per frame.
            if hasIsland {
                IslandExtension(canvasSize: canvas, bulbCenter: dockCenter,
                                bulbDiameter: bulbDiameter, glowColor: paletteTint)
                    .opacity(pouchOn ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: pouchOn)
            }
            TimelineView(.animation(paused: !isActive)) { tl in
                orb(now: tl.date)
            }
        }
        .opacity(mounted ? 1 : 0)
    }

    @ViewBuilder
    private func orb(now: Date) -> some View {
        let elapsed = max(0, now.timeIntervalSince(legStart))
        let t = now.timeIntervalSinceReferenceDate
        let g = min(max(travelProgress(elapsed: elapsed), 0), 1)
        let life = Double(g)
        // Crossfade window: let the genie funnel fully collapse into the island
        // before the metaball bubble takes over, so the fluid suck is the star.
        let orbFade = smoothstep(0.9, 1.0, life)
        // On the way back, dissolve over the second half of the descent so the
        // orb doesn't sit on top of the result breakdown that's revealing under
        // it. (g runs 1→0 during the return.)
        let returnFade: Double = (leg == .returning) ? smoothstep(0.0, 0.55, life) : 1
        let breathe = 1 + 0.045 * sin(t * 1.9) * life
        let sx = CGFloat(1 + 0.05 * sin(t * 2.3) * life) * CGFloat(breathe)
        let sy = CGFloat(1 + 0.05 * sin(t * 2.3 + .pi) * life) * CGFloat(breathe)
        let tint = paletteTint
        let dockScale = dockSide / Self.referenceSide

        ZStack {
            // Genie stream — the photo funnels from the card up into the island
            // (and unfurls back). Only built while in transit, so the expensive
            // strip warp never runs once docked.
            if g < 0.995 {
                GenieWarp(image: image, canvasSize: canvas, source: srcRect,
                          target: dockCenter, targetWidth: dockSide * 0.72,
                          g: CGFloat(g), time: CGFloat(elapsed))
                    .opacity((1 - orbFade) * returnFade)
            }
            // The docked Siri bubble — pops/fades in as the genie arrives.
            if g > 0.88 {
                ZStack {
                    BubbleAura(time: t, tint: tint, ringColors: ringColors, energy: CGFloat(life))
                    MorphingBubble(image: image, time: t, rim: tint)
                }
                .frame(width: Self.referenceSide, height: Self.referenceSide)
                .scaleEffect(x: max(0.4, sx) * dockScale, y: max(0.4, sy) * dockScale)
                .scaleEffect(0.7 + 0.3 * orbFade)
                .opacity(orbFade * returnFade)
                .position(dockCenter)
            }
        }
    }

    private var paletteTint: Color {
        if isPro { return Color(red: 1.0, green: 0.90, blue: 0.70) }
        return palette.first ?? Color(red: 0.15, green: 0.86, blue: 1.0)
    }
    private var ringColors: [Color] {
        let base: [Color]
        if isPro {
            base = [Color(red: 0.98, green: 0.85, blue: 0.55), Color(red: 1.0, green: 0.93, blue: 0.78),
                    Color(red: 0.96, green: 0.72, blue: 0.52)]
        } else if palette.count >= 2 {
            base = palette
        } else {
            base = [Color(red: 0.15, green: 0.86, blue: 1.0), Color(red: 0.90, green: 0.21, blue: 1.0),
                    Color(red: 1.0, green: 0.63, blue: 0.18), Color.brandBright]
        }
        return base + [base[0]]
    }

    private func travelProgress(elapsed: Double) -> Double {
        switch leg {
        case .hidden:    return 0
        case .toNotch:   return smootherstep(min(1, elapsed / Self.riseDuration))
        case .returning: return 1 - smootherstep(min(1, elapsed / Self.fallDuration))
        }
    }
    /// Quintic smootherstep (6x⁵−15x⁴+10x³) — zero velocity AND zero
    /// acceleration at both ends (C2). The smoothest possible ease-in-out: a
    /// gentle launch (fixes "too fast") and a soft settle, no rushed front.
    private func smootherstep(_ x: Double) -> Double {
        x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
    }
    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func sync(animated: Bool) {
        hideTask?.cancel()
        pouchTask?.cancel()
        pulseTask?.cancel()
        if isAnalyzing {
            mounted = true
            leg = .toNotch
            legStart = animated ? Date() : Date(timeIntervalSinceNow: -Self.riseDuration)
            if animated {
                // Haptic choreography synced to the genie phases:
                //   launch (tap) → arrive/dock (soft) → thinking heartbeat
                //   (gentle soft pulses) → release (soft) → settle (tap).
                Haptics.prepare()       // warm the engine for low-latency sync
                Haptics.tap()           // launch — the photo lifts up the funnel
                pouchOn = false
                pouchTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.riseDuration * 0.66 * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    pouchOn = true
                    Haptics.soft()      // dock — settles into the island
                    pulseTask = Task { @MainActor in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 1_300_000_000)
                            guard !Task.isCancelled else { return }
                            Haptics.soft()   // gentle "thinking" heartbeat
                        }
                    }
                }
            } else {
                pouchOn = true
            }
        } else {
            guard mounted else { return }
            leg = .returning
            pouchOn = false   // fades out as the orb leaves
            if animated { Haptics.soft() }   // release — the orb warps back home
            legStart = animated ? Date() : Date(timeIntervalSinceNow: -Self.fallDuration)
            let secs = animated ? Self.fallDuration : 0
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000) + 120_000_000)
                guard !Task.isCancelled else { return }
                mounted = false
                if animated { Haptics.tap() }   // settle — the breakdown lands
            }
        }
    }
}

// MARK: - Morphing bubble (the orb itself)

/// The meal photo masked into a gooey, continuously-morphing metaball — a Siri
/// orb made of the food. One `Canvas` (blur + alpha-threshold fuse the lobes
/// into a liquid silhouette) flattened with `.drawingGroup()`, plus a drifting
/// specular sheen for the "wet bubble" read. Drawn at a fixed reference size;
/// the caller scales it with a GPU transform.
private struct MorphingBubble: View {
    let image: UIImage
    let time: TimeInterval
    let rim: Color

    var body: some View {
        // ONE metaball Canvas per frame: the sheen highlight and the colored rim
        // are overlaid on the photo *before* the single mask, so they follow the
        // gooey edge without a second Canvas.
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 300, height: 300)
            .clipped()
            .overlay { sheen }
            .overlay { edgeTint }
            .mask { MetaballSilhouette(time: time) }
    }

    /// Soft white highlight drifting across the surface — reads as a wet,
    /// appetizing bubble. Cheap (one gradient), masked along with the photo.
    private var sheen: some View {
        let cx = 0.34 + 0.06 * sin(time * 0.7)
        let cy = 0.28 + 0.05 * cos(time * 0.6)
        return RadialGradient(
            colors: [.white.opacity(0.55), .white.opacity(0.0)],
            center: UnitPoint(x: cx, y: cy), startRadius: 0, endRadius: 150
        )
        .blendMode(.screen)
    }

    /// Colored rim in the dish's hue — clear at the core, glowing at the edge —
    /// so the bubble reads as energized. Masked by the same silhouette.
    private var edgeTint: some View {
        RadialGradient(
            colors: [.clear, .clear, rim.opacity(0.7)],
            center: .center, startRadius: 70, endRadius: 150
        )
        .blendMode(.screen)
    }
}

/// White gooey metaball silhouette: a breathing central body plus orbiting
/// lobes that separate and re-fuse, blurred then alpha-thresholded so they melt
/// into one liquid edge. Used as the bubble's mask.
private struct MetaballSilhouette: View {
    let time: TimeInterval

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .white))
            ctx.addFilter(.blur(radius: s * 0.06))
            ctx.drawLayer { layer in
                let cx = size.width / 2
                let cy = size.height / 2
                // Breathing central body.
                let bodyD = s * (0.64 + 0.03 * CGFloat(sin(time * 1.8)))
                blob(layer, cx, cy, bodyD)
                // Lobes parting & merging (~5.7s cycle) → the morph.
                let split = 0.5 + 0.5 * sin(time * 1.1)
                let sep = s * (0.12 + 0.12 * CGFloat(split))
                for i in 0..<5 {
                    let ph = time * (0.5 + Double(i) * 0.07) + Double(i) * 1.7
                    let ox = CGFloat(cos(ph)) * sep
                    let oy = CGFloat(sin(ph * 1.13)) * sep
                    let d = s * (0.34 - 0.035 * CGFloat(i))
                    blob(layer, cx + ox, cy + oy, d)
                }
            }
        }
        .drawingGroup()
    }

    private func blob(_ layer: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ d: CGFloat) {
        let rect = CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
        layer.fill(Path(ellipseIn: rect), with: .color(.white))
    }
}

// MARK: - Genie warp

/// A "genie from a bottle" warp: the meal photo flows from its card up into the
/// island — and unfurls back — sucked through a funnel like the macOS minimize
/// effect. The macOS version is a continuous Bezier mesh warp; here we do the
/// per-pixel GPU equivalent via a Metal `distortionEffect` shader (`Genie.metal`)
/// — one pass, no strips, so the edges are perfectly smooth and it's cheap. The
/// photo is rendered into its card rect inside a full-canvas layer; the shader
/// remaps the funnel region (card → target). `g`: 0 = full card, 1 = collapsed.
private struct GenieWarp: View {
    let image: UIImage
    let canvasSize: CGSize
    let source: CGRect
    let target: CGPoint
    let targetWidth: CGFloat
    let g: CGFloat
    /// Seconds into the current leg — drives the curl-noise turbulence so the
    /// fluid churn evolves over the flight.
    let time: CGFloat

    var body: some View {
        Color.clear
            .frame(width: canvasSize.width, height: canvasSize.height)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: source.width, height: source.height)
                    .clipped()
                    .position(x: source.midX, y: source.midY)
            }
            .distortionEffect(
                ShaderLibrary.genie(
                    .float2(Float(source.minX), Float(source.minY)),
                    .float2(Float(source.width), Float(source.height)),
                    .float2(Float(target.x), Float(target.y)),
                    .float(Float(targetWidth)),
                    .float(Float(g)),
                    .float(Float(time))
                ),
                maxSampleOffset: CGSize(width: canvasSize.width, height: canvasSize.height)
            )
    }
}

// MARK: - Fake "expanded island" pouch

/// A black pouch that makes the Dynamic Island look like it stretched down to
/// cradle the orb. Draws the island's pill shape (slightly *narrower* than the
/// real ~126pt system pill so it stays hidden behind it — no seam) fused via
/// metaball blur + alpha-threshold to a round bulb below it, so the two read as
/// one continuous black shape with a smooth neck (the island "dripping" into a
/// pocket). DI devices only — the pill metrics aren't a public API, so a
/// mismatched device would otherwise show a seam.
private struct IslandExtension: View {
    let canvasSize: CGSize
    let bulbCenter: CGPoint
    let bulbDiameter: CGFloat
    /// Dish-derived colour for the glowing edge around the island/orb.
    let glowColor: Color

    private static let pillWidth: CGFloat = 112
    private static let pillTop: CGFloat = 11
    private static let pillHeight: CGFloat = 37
    private static let glowRadius: CGFloat = 18

    /// Drives the breathing glow intensity (animated, not per-frame redrawn).
    @State private var pulse: CGFloat = 0.55

    var body: some View {
        Canvas { ctx, size in
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            ctx.addFilter(.blur(radius: 13))
            ctx.drawLayer { layer in
                let cx = size.width / 2
                let pill = CGRect(x: cx - Self.pillWidth / 2, y: Self.pillTop,
                                  width: Self.pillWidth, height: Self.pillHeight)
                layer.fill(Capsule().path(in: pill), with: .color(.black))
                let r = bulbDiameter / 2
                let bulb = CGRect(x: bulbCenter.x - r, y: bulbCenter.y - r,
                                  width: bulbDiameter, height: bulbDiameter)
                layer.fill(Path(ellipseIn: bulb), with: .color(.black))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .drawingGroup()
        // GPU outer glow tracing the pouch/island edges around the orb. One
        // Metal pass (ring-samples the alpha) instead of stacked blurs.
        .layerEffect(
            ShaderLibrary.islandGlow(
                .color(glowColor),
                .float(Float(Self.glowRadius)),
                .float(Float(pulse))
            ),
            maxSampleOffset: CGSize(width: Self.glowRadius, height: Self.glowRadius)
        )
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = 1.35
            }
        }
    }
}

// MARK: - Aura

/// A soft breathing glow plus a slowly-rotating spectrum ring behind the
/// bubble. Two cheap gradient layers — no per-frame blur stack.
private struct BubbleAura: View {
    let time: TimeInterval
    let tint: Color
    let ringColors: [Color]
    let energy: CGFloat

    var body: some View {
        let speed = 0.6 + 1.2 * Double(energy)
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(0.45 * Double(energy) + 0.10), .clear],
                    center: .center, startRadius: 0, endRadius: 230))
                .scaleEffect(1 + 0.05 * CGFloat(sin(time * 1.5)))
            Circle()
                .strokeBorder(AngularGradient(colors: ringColors, center: .center), lineWidth: 16)
                .blur(radius: 14)
                .scaleEffect(0.62)
                .rotationEffect(.radians(time * speed))
                .blendMode(.screen)
                .opacity(0.7 * Double(energy) + 0.15)
        }
    }
}

// MARK: - View helpers

extension View {
    /// Marks this view (the meal photo) as the orb's launch / return anchor,
    /// publishing its global frame.
    func orbSourceAnchor() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: OrbSourceRectKey.self,
                                       value: geo.frame(in: .global))
            }
        )
    }

    /// Hosts the analyzing orb that genie-travels to the notch and back.
    func analyzingOrbJourney(
        image: UIImage?,
        isAnalyzing: Bool,
        palette: [Color],
        isPro: Bool,
        isActive: Bool,
        enabled: Bool,
        useFluid: Bool
    ) -> some View {
        modifier(AnalyzingOrbJourneyModifier(
            image: image, isAnalyzing: isAnalyzing, palette: palette,
            isPro: isPro, isActive: isActive, enabled: enabled, useFluid: useFluid
        ))
    }
}
