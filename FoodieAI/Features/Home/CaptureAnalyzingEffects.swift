import SwiftUI
import UIKit

// Extracted from CaptureView.swift (2026-07) to shrink the file.
// The analyzing-state animation kit (image entrance, glow, aura, Siri glow/ribbons, blur modifiers, analyzing dots) and the experimental bubble-morph apparatus. Types are module-scoped so CaptureView still references them.

// MARK: - Delightful image entrance

/// Duolingo-style "land" choreography for a freshly captured or picked
/// image. Three coordinated beats:
///
///   1. **Drop in** (`.appBouncy`, 0–~0.55s): the image enters at
///      0.55× scale with a slight −6° tilt and zero opacity. The
///      `appBouncy` spring (response 0.55, damping 0.55) overshoots
///      its target before settling, so the photo "bounces" into place
///      instead of fading in flat.
///   2. **Land haptic** (~0.32s): a soft impact fires just before the
///      bounce settles. Paired with the visual overshoot it reads as
///      the photo physically thudding onto the card.
///   3. **Stamp pulse** (~0.40s, then `.appPress`): a quick 1.0 → 1.04
///      → 1.0 scale pop confirms the moment and gives the card a
///      heartbeat — the same cue the analyze-result hero number uses.
///
/// The view is keyed by `ObjectIdentifier(image)` at the call site so
/// SwiftUI tears it down and rebuilds it whenever the user picks a new
/// photo, which re-runs the whole choreography from the top.
struct DelightfulImageEntry: View {
    let image: UIImage
    /// When true, skip the bounce-in entirely and render at identity. Used
    /// during the bubble→result morph so the matched-geometry effect owns
    /// the photo's transform instead of this entrance fighting it.
    var suppressEntrance: Bool = false
    @State private var landed: Bool = false
    @State private var stamping: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Treat the photo as fully landed (no transform) whenever the entrance
    /// is suppressed — derived rather than written to @State so there's no
    /// opacity-0 flash before `onAppear` would otherwise run.
    private var effectiveLanded: Bool { suppressEntrance || landed }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            // Without this frame cap, a tall input UIImage reports its
            // intrinsic pixel size as its layout size and the parent
            // photo card grows to fit, blowing past the screen. The
            // frame forces the image to accept the parent's proposed
            // size; `.clipped()` enforces the bounds in layout terms
            // before the rounded-rect clip handles the visual edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl2))
            .scaleEffect(scale)
            // Reduce Motion: skip the rotation tilt so the image fades in
            // straight rather than swinging into place.
            .rotationEffect(.degrees(reduceMotion ? 0 : (effectiveLanded ? 0 : -6)))
            .opacity(effectiveLanded ? 1 : 0)
            .onAppear {
                guard !suppressEntrance else { return }
                runEntrance()
            }
    }

    private var scale: CGFloat {
        if suppressEntrance { return 1.0 }
        if reduceMotion { return 1.0 }
        if !landed { return 0.55 }
        return stamping ? 1.04 : 1.0
    }

    private func runEntrance() {
        // Reduce Motion: opacity-only entrance, no bounce, no stamp, no
        // haptic — keeps the user oriented but quiet.
        if reduceMotion {
            withAnimation(.appReduced) { landed = true }
            return
        }
        // Beat 1 — bounce in.
        withAnimation(.appBouncy) {
            landed = true
        }
        Task {
            // Cancellation-aware: if the view is torn down mid-entrance
            // (the photo card was rebuilt with a different image), bail
            // immediately rather than firing late haptics + state writes
            // against a defunct @State storage.
            do {
                // Beat 2 — soft land haptic just before the bounce settles.
                try await Task.sleep(nanoseconds: 320_000_000)
                await MainActor.run { Haptics.soft() }

                // Beat 3 — stamp pulse, then release back to identity.
                try await Task.sleep(nanoseconds:  80_000_000)
                await MainActor.run {
                    withAnimation(.appStamp) { stamping = true }
                }
                try await Task.sleep(nanoseconds: 180_000_000)
                await MainActor.run {
                    withAnimation(.appPress) { stamping = false }
                }
            } catch {
                return
            }
        }
    }
}

// MARK: - First-scan celebratory glow

/// Lifetime-first-scan delight. A brand-tinted ring fades in around the
/// photo card, scales up slightly, then fades out — under a second from
/// start to finish. Owns its own lifecycle via SwiftUI's `.task`, which
/// SwiftUI cancels automatically when the view leaves the tree, so the
/// host doesn't have to retain a delayed `Task` to cancel.
///
/// Reduce Motion path: opacity-only crossfade, no scale, same duration
/// budget. No haptic — DelightfulImageEntry already fires the land
/// haptic and stacking a second would double-tap the user.
struct FirstScanGlow: View {
    let onDone: () -> Void
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl2)
            .strokeBorder(Color.brand, lineWidth: 3)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
            .task {
                do {
                    if reduceMotion {
                        withAnimation(.appReduced) { opacity = 0.55 }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 700)
                        try Task.checkCancellation()
                        withAnimation(.appReduced) { opacity = 0 }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 220)
                    } else {
                        withAnimation(.easeOut(duration: 0.45)) {
                            opacity = 0.75
                            scale = 1.08
                        }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 520)
                        try Task.checkCancellation()
                        withAnimation(.easeIn(duration: 0.32)) {
                            opacity = 0
                        }
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 340)
                    }
                    try Task.checkCancellation()
                } catch {
                    return
                }
                onDone()
            }
    }
}

// MARK: - Analyzing image aura

/// Siri-inspired analyzing state for the selected image. The effect uses
/// the same ingredients common to Siri-like recreations: layered color,
/// blur, blend modes, and continuously shifting sine-wave ribbons. It is
/// decorative only; the actual analyze state remains driven by
/// `CaptureViewModel.State.analyzing`.
///
/// `isPro` swaps the underlying palettes to champagne/gold without
/// touching the motion — same fluid recipe, premium colorway. We don't
/// surface this as a marketing line; it's a quiet daily moment that
/// belongs to Pro users.
struct AnalyzingImageAura: View {
    var isPro: Bool = false
    /// Food-derived tint for the free path, sampled once per scan by the
    /// photo card and threaded straight into the fluid glow + ribbons.
    /// Empty → the subviews use their default rainbow palette. Ignored on
    /// the Pro path (champagne override) and under Reduce Motion (static
    /// aura draws no blobs).
    var foodPalette: [Color] = []
    /// Pauses the per-frame metaball `TimelineView` when the Home tab isn't
    /// active (e.g. the user switches tabs mid-analyze) — the inactive tab
    /// stays alive in the TabView and would otherwise keep redrawing the
    /// Canvas every frame.
    var isActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                // Static aura: a quiet dim + the analyzing badge. No
                // TimelineView, no continuous redraw — the Siri-style
                // motion is purely decorative and the analyzing state
                // is communicated by the badge.
                ZStack {
                    Color.black.opacity(0.22)
                    LinearGradient(
                        colors: [Color.clear, Color.ink.opacity(0.34)],
                        startPoint: .center, endPoint: .bottom
                    )
                    analyzingBadge
                        .padding(AppSpacing.md)
                        .frame(maxWidth: .infinity,
                               maxHeight: .infinity,
                               alignment: .bottomTrailing)
                }
            } else {
                TimelineView(.animation(paused: !isActive)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate

                    ZStack {
                        Color.black.opacity(0.16)

                        // Outer blur is intentionally lighter than the
                        // pre-metaball recipe (was 26): the Canvas now emits
                        // a defined fused silhouette, so a softer halo keeps
                        // the liquid edge legible instead of diffusing the
                        // bubble back into a vague glow.
                        SiriFluidGlow(time: seconds, isPro: isPro,
                                      palette: foodPalette)
                            .blur(radius: 14)
                            .opacity(0.82)
                            .blendMode(.screen)

                        SiriWaveRibbons(time: seconds, isPro: isPro,
                                        palette: foodPalette)
                            .blendMode(.screen)

                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.ink.opacity(0.34)
                            ],
                            startPoint: .center,
                            endPoint: .bottom
                        )

                        analyzingBadge
                            .padding(AppSpacing.md)
                            .frame(maxWidth: .infinity,
                                   maxHeight: .infinity,
                                   alignment: .bottomTrailing)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var analyzingBadge: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                AnalyzingDot(delay: Double(index) * 0.16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
    }
}

struct AnalyzingDot: View {
    let delay: Double
    @State private var isLifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 6, height: 6)
            .scaleEffect(reduceMotion ? 1.0 : (isLifted ? 1.35 : 0.75))
            .opacity(reduceMotion ? 0.85 : (isLifted ? 1 : 0.48))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.62)
                        .repeatForever(autoreverses: true)
                        .delay(delay),
                value: isLifted
            )
            .onAppear {
                guard !reduceMotion else { return }
                isLifted = true
            }
    }
}

struct SiriFluidGlow: View {
    let time: TimeInterval
    var isPro: Bool = false
    /// Food-derived tint for the bubble. When non-empty (the caller
    /// guarantees ≥ 2 colors before passing it through) its dominant hue
    /// tints the fused silhouette; empty falls back to the classic Siri
    /// cyan. Only the *first* color is read now that the four blobs fuse
    /// into a single metaball — per-blob color is discarded by the alpha
    /// threshold, so multi-hue richness comes from the ribbons drawn over
    /// the bubble instead.
    var palette: [Color] = []

    /// Number of orbiting blobs fused into the bubble. Held at 4 — the
    /// metaball Canvas (blur + alpha-threshold) is the expensive part, so
    /// the blob count stays put for performance regardless of palette size.
    private static let blobCount = 4

    private static let freeColors: [Color] = [
        Color(red: 0.15, green: 0.86, blue: 1.00),
        Color(red: 0.90, green: 0.21, blue: 1.00),
        Color(red: 1.00, green: 0.63, blue: 0.18),
        Color.brandBright,
    ]

    /// Single fill + threshold color for the fused bubble. Pro keeps its
    /// champagne body; otherwise the dominant food hue tints the bubble,
    /// falling back to the classic Siri cyan when no palette was sampled.
    private var bubbleTint: Color {
        if isPro { return ProGold.cream }
        return palette.first ?? Self.freeColors[0]
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // Bubble breathing: a gentle ±4% sin pulse on the blob radius,
            // driven off the same `time` the orbit uses, so the fused shape
            // feels alive while analyzing. This scales the *drawn* blobs,
            // never the blur/threshold parameters — the metaball recipe
            // stays static per frame.
            let breathe = 1 + 0.04 * sin(time * 1.6)

            Canvas { context, size in
                // Gooey metaball fusion. The four orbiting blobs are drawn
                // into one transparency layer, blurred, then alpha-
                // thresholded so their soft fields merge into a single
                // liquid silhouette wherever they overlap — instead of four
                // separate orbs floating apart.
                //
                // Filter order is deliberate: SwiftUI applies the most
                // recently added filter first, so adding the threshold
                // *first* and the blur *last* means the blur runs on the raw
                // blobs (building the gooey field) and the threshold runs on
                // the blurred result (cutting the crisp fused edge). Both
                // filter parameters are constant — only `position(for:)`
                // animates the orbit — so the recipe never re-tunes per
                // frame.
                context.addFilter(.alphaThreshold(min: 0.45, color: bubbleTint))
                context.addFilter(.blur(radius: 18))
                context.drawLayer { layer in
                    for index in 0..<Self.blobCount {
                        let diameter = side * blobScale(index) * breathe
                        let center = position(for: index, in: size)
                        let rect = CGRect(
                            x: center.x - diameter / 2,
                            y: center.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                        layer.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(stops: [
                                    .init(color: bubbleTint.opacity(0.95),
                                          location: 0.0),
                                    .init(color: bubbleTint.opacity(0.90),
                                          location: 0.45),
                                    .init(color: bubbleTint.opacity(0.0),
                                          location: 1.0),
                                ]),
                                center: center,
                                startRadius: 0,
                                endRadius: diameter * 0.5
                            )
                        )
                    }
                }
            }
            // Flatten the metaball into a single Metal-backed layer so the
            // blur + threshold compose once per frame rather than against
            // the parent's blend.
            .drawingGroup()
        }
    }

    private func blobScale(_ index: Int) -> CGFloat {
        [0.72, 0.62, 0.54, 0.48][index]
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        let phase = time * (0.48 + Double(index) * 0.08) + Double(index) * 1.7
        let x = size.width * (0.5 + 0.27 * cos(phase))
        let y = size.height * (0.5 + 0.24 * sin(phase * 1.17))
        return CGPoint(x: x, y: y)
    }
}

struct SiriWaveRibbons: View {
    let time: TimeInterval
    var isPro: Bool = false
    /// Food-derived tint for the free path. When non-empty it's expanded
    /// into the same 3-ribbon × 3-stop shape the hardcoded
    /// `freeRibbonColors` uses, so the wave geometry below is untouched —
    /// only the colors change. Empty falls back to the default rainbow.
    var palette: [Color] = []

    private static let freeRibbonColors: [[Color]] = [
        [
            Color(red: 0.22, green: 0.92, blue: 1.00),
            Color(red: 0.73, green: 0.35, blue: 1.00),
            Color(red: 1.00, green: 0.53, blue: 0.28)
        ],
        [
            Color.brandBright,
            Color(red: 0.98, green: 0.30, blue: 0.92),
            Color(red: 0.18, green: 0.78, blue: 1.00)
        ],
        [
            Color.white.opacity(0.95),
            Color(red: 0.45, green: 0.86, blue: 1.00),
            Color(red: 1.00, green: 0.79, blue: 0.22)
        ]
    ]

    // Pro palette: each ribbon walks the gold→cream→rose triad with a
    // hint of white on the top ribbon for sparkle. Same three rows so
    // the wave/blur geometry below stays identical.
    private static let proRibbonColors: [[Color]] = [
        [
            ProGold.warm,
            ProGold.cream,
            ProGold.rose,
        ],
        [
            ProGold.cream,
            ProGold.warm,
            ProGold.edgeDark,
        ],
        [
            Color.white.opacity(0.95),
            ProGold.cream,
            ProGold.rose,
        ],
    ]

    private var ribbonColors: [[Color]] {
        if isPro { return Self.proRibbonColors }
        return palette.isEmpty ? Self.freeRibbonColors : Self.ribbons(from: palette)
    }

    /// Expand a flat food palette into 3 ribbons of 3 stops, keeping the
    /// existing 3-ribbon geometry (drawWaves centers its vertical offset
    /// on index 1, so the count must stay 3). Each ribbon walks the
    /// palette from a different offset for variety; a white top-stop on
    /// the first ribbon preserves the sparkle `freeRibbonColors` had.
    private static func ribbons(from palette: [Color]) -> [[Color]] {
        let n = palette.count
        func c(_ i: Int) -> Color { palette[((i % n) + n) % n] }
        return [
            [c(0), c(1), c(2)],
            [c(1), c(2), c(0)],
            [Color.white.opacity(0.9), c(0), c(2)],
        ]
    }

    var body: some View {
        Canvas { context, size in
            var softenedContext = context
            softenedContext.addFilter(.blur(radius: 9))
            drawWaves(in: &softenedContext, size: size, softened: true)

            drawWaves(in: &context, size: size, softened: false)
        }
        .drawingGroup()
    }

    private func drawWaves(in context: inout GraphicsContext,
                           size: CGSize,
                           softened: Bool) {
        let baseY = size.height * 0.52
        let width = max(size.width, 1)
        let height = max(size.height, 1)

        for index in ribbonColors.indices {
            var path = Path()
            let phase = time * (1.22 + Double(index) * 0.18)
                + Double(index) * 1.35
            let amplitude = height * (softened ? 0.055 : 0.042)
                * (1 + 0.22 * sin(time * 1.4 + Double(index)))
            let frequency = 1.55 + Double(index) * 0.38
            let verticalOffset = CGFloat(index - 1) * height * 0.065

            for step in 0...120 {
                let progress = CGFloat(step) / 120
                let x = progress * width
                let envelope = sin(Double(progress) * .pi)
                let primary = sin(Double(progress) * .pi * 2 * frequency + phase)
                let secondary = sin(Double(progress) * .pi * 4.2 + phase * 0.72)
                let y = baseY + verticalOffset
                    + CGFloat((primary + secondary * 0.34) * envelope) * amplitude

                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let gradient = Gradient(colors: ribbonColors[index])
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: baseY - height * 0.14),
                endPoint: CGPoint(x: width, y: baseY + height * 0.14)
            )

            context.stroke(
                path,
                with: shading,
                style: StrokeStyle(
                    lineWidth: softened ? height * 0.075 : height * 0.018,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}

/// Transition-only blur for the analyzing aura's "lock-in" collapse — the
/// glow softens slightly as it contracts toward center. Kept as a
/// dedicated modifier so the blur can animate via `.modifier(active:
/// identity:)` inside the asymmetric removal transition.
struct AuraCollapseBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// Transition-only blur for the result reveal's "focus-pull": the analysis
/// content lands diffuse (blur ~16) and resolves to crisp (blur 0) as the
/// analyzing bubble collapses inward — the analysis "comes into focus."
/// Driven by the same `.appMorph` spring already animating the idle↔result
/// switch; the call site degrades to a plain opacity fade (no blur ramp)
/// under Reduce Motion.
struct FocusPullBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

// MARK: - Experimental bubble → result-photo morph

/// Gate + constants for the experimental "analyzing bubble physically
/// morphs into the result meal photo" handoff. The morph replaces the
/// capture→result crossfade with a single matched-geometry travel of the
/// photo (position + size + corner radius).
///
/// Two locks, both required to engage (plus Reduce Motion off, checked at
/// the call site): this compile-time `isAvailable` constant, and the
/// `@AppStorage("bubbleMorphEnabled")` runtime toggle (default off). Flip
/// `isAvailable` to false to strip the matched-geometry path entirely
/// without touching persisted user defaults. `internal` (not `private`)
/// so `AnalysisResultView` in its own file can share the same `matchID`.
enum BubbleMorphFeature {
    static let isAvailable = true
    /// Separate, currently-off gate for the matched-geometry photo→result
    /// handoff (capture photo flying into `AnalysisResultView`). Decoupled
    /// from the analyzing-bubble effect because the mandatory `.confirmingName`
    /// step sits between `.analyzing` and `.ready`, so a clean bubble→result
    /// morph isn't possible without state-logic changes. Left in place
    /// (gated off) rather than deleted so it can be revisited.
    static let resultHandoffAvailable = false
    /// Geometry id shared by the capture-side source photo and the
    /// result-side destination photo. Must appear on exactly those two
    /// views and never on two simultaneously-mounted *sources*.
    static let matchID = "mealPhoto"
    /// Near-circular corner radius the result photo starts the morph at,
    /// rounding down to the thumbnail radius as it settles. Large enough
    /// that `RoundedRectangle` clamps it to a circle on the bubble-sized
    /// starting frame.
    static let circularRadius: CGFloat = 200
}

/// Applies the shared meal-photo matched-geometry effect when a namespace
/// is provided; a no-op otherwise, so the flag-off / Reduce-Motion path is
/// structurally identical to today's tree (no matched geometry attached).
struct MealMorphMatch: ViewModifier {
    let namespace: Namespace.ID?
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(
                id: BubbleMorphFeature.matchID,
                in: namespace,
                isSource: isSource
            )
        } else {
            content
        }
    }
}

/// Applies `BubbleMorphMask` only when the morph is engaged for this view;
/// otherwise passes content through untouched, so the flag-off path keeps
/// the photo's plain rounded-rect clip (no mask, no extra redraws).
struct ConditionalBubbleMask: ViewModifier {
    let active: Bool
    let progress: CGFloat
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.modifier(BubbleMorphMask(
                progress: progress,
                cornerRadius: cornerRadius
            ))
        } else {
            content
        }
    }
}

/// Masks a view into a living "jelly" that embodies what the app does while
/// it works: the meal photo melts out of its card into a glossy blob that
/// rhythmically **loosens into lobes and re-fuses** — a visual "we're
/// breaking your meal down" — while it **jiggles** with elastic squash-and-
/// stretch and carries a drifting **wet sheen**. Morphs between a full
/// rounded-rect (progress 0 — the photo card) and the formed jelly
/// (progress 1), un-forming back to the card as analysis ends.
///
/// Three motions, each serving the brief:
///  - Split & merge: the metaball lobes' separation breathes, so the blob
///    gently parts into pieces and rejoins — the decomposition the analyzer
///    is performing, made tactile.
///  - Squash & stretch: anisotropic x/y wobble (out of phase) gives the
///    elastic, edible jiggle that matches the app's bouncy character.
///  - Sheen: a soft white highlight drifts across the surface (overlaid on
///    the photo, masked along with it) so the jelly reads as wet/appetizing.
///
/// Conforms to `Animatable` so `progress` interpolates frame-by-frame; the
/// metaball blur scales with `progress` so progress 0 is a crisp full card
/// (matching the normal photo) and only the formed jelly is gooey.
struct BubbleMorphMask: ViewModifier, Animatable {
    /// 0 = full rounded-rect card; 1 = formed jelly.
    var progress: CGFloat
    /// Card corner radius the silhouette starts from at progress 0.
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        return content
            // Wet sheen — a soft, slowly drifting highlight. It sits over the
            // photo and is clipped by the same jelly mask below, so it only
            // shows on the blob. Fades in with `p`; gone at rest.
            .overlay {
                if p > 0.02 {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        GeometryReader { geo in
                            let w = geo.size.width
                            let h = geo.size.height
                            let r = min(w, h) * 0.42
                            let cx = w * (0.34 + 0.05 * CGFloat(sin(t * 0.7)))
                            let cy = h * (0.28 + 0.04 * CGFloat(cos(t * 0.6)))
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [.white.opacity(0.75 * p),
                                                 .white.opacity(0.18 * p),
                                                 .white.opacity(0.0)],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: r
                                    )
                                )
                                .frame(width: r * 2, height: r * 2)
                                .position(x: cx, y: cy)
                                .blendMode(.screen)
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
            .mask {
                // Paused when flat so an idle/picked photo card doesn't drive
                // a continuous redraw; runs while the jelly forms or lives.
                TimelineView(.animation(paused: p <= 0.001)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        // Gooey fusion: blur then alpha-threshold (threshold
                        // added first → applied last, since SwiftUI applies
                        // the most recently added filter first). A small base
                        // blur even at progress 0 keeps the rounded-card edge
                        // anti-aliased; it ramps up as the jelly forms.
                        ctx.addFilter(.alphaThreshold(min: 0.5, color: .white))
                        ctx.addFilter(.blur(radius: 0.5 + 17 * p))
                        ctx.drawLayer { layer in
                            let w = size.width
                            let h = size.height
                            let center = CGPoint(x: w / 2, y: h / 2)
                            let side = min(w, h)

                            // Elastic jiggle: width and height wobble out of
                            // phase so the body widens-then-heightens like
                            // settling jelly (subsumes the old uniform breath).
                            let jiggleX = 1 + 0.05 * sin(t * 2.0) * p
                            let jiggleY = 1 + 0.05 * sin(t * 2.0 + .pi) * p

                            // Body: full card → ~58% rounded core as it forms,
                            // corner rounding all the way to a circle. Smaller
                            // core lets the lobes read as distinct pieces.
                            let bodyScale = 1 - 0.42 * p
                            let bw = w * bodyScale * jiggleX
                            let bh = h * bodyScale * jiggleY
                            let circleCorner = min(bw, bh) / 2
                            let corner = cornerRadius
                                + (circleCorner - cornerRadius) * p
                            let bodyRect = CGRect(x: center.x - bw / 2,
                                                  y: center.y - bh / 2,
                                                  width: bw, height: bh)
                            layer.fill(
                                Path(roundedRect: bodyRect, cornerRadius: corner),
                                with: .color(.white.opacity(0.98))
                            )

                            guard p > 0.02 else { return }

                            // Split & merge: separation breathes (~5.7s cycle)
                            // so the lobes gently part — "breaking it down" —
                            // and re-fuse. 0 = merged, 1 = most separated.
                            let split = 0.5 + 0.5 * sin(t * 1.1)
                            let sep = (0.10 + 0.22 * split) * p
                            let scales: [CGFloat] = [0.6, 0.54, 0.48, 0.42]
                            for i in 0..<4 {
                                let phase = t * (0.5 + Double(i) * 0.08)
                                    + Double(i) * 1.7
                                let ox = CGFloat(cos(phase)) * w * sep * jiggleX
                                let oy = CGFloat(sin(phase * 1.13)) * h * sep * jiggleY
                                let bx = center.x + ox
                                let by = center.y + oy
                                let d = side * scales[i] * p
                                    * (jiggleX + jiggleY) / 2
                                guard d > 0.5 else { continue }
                                let r = CGRect(x: bx - d / 2, y: by - d / 2,
                                               width: d, height: d)
                                layer.fill(Path(ellipseIn: r),
                                           with: .color(.white.opacity(0.98)))
                            }
                        }
                    }
                    .drawingGroup()
                }
            }
    }
}

/// The analyzing "dots" badge, extracted so bubble mode can float it over
/// the photo bubble. Mirrors the badge `AnalyzingImageAura` draws.
struct AnalyzingDotsBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                AnalyzingDot(delay: Double(index) * 0.16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
    }
}
