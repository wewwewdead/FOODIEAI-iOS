import SwiftUI

/// Phase 23. Honest, parameterized social proof for onboarding. Single source
/// of truth so the hero and the pre-paywall step stay in lockstep.
///
/// Deliberate call at small scale: we show the real star rating with
/// transparent "early users" framing and honest trust cues, but NOT raw
/// download/rating COUNTS — tiny counts (dozens) read as unproven and hurt
/// more than they help. When the counts get compelling (a few hundred+
/// ratings, thousands of users), set `showsCounts = true` and fill
/// `ratingCount` / `userCount` to surface them.
enum OnboardingSocialProof {
    /// Real App Store average. Currently 5.0 from a small number of ratings.
    static let starsDisplay = "5.0"
    /// Honest framing that doesn't imply a large base.
    static let ratingLine = "Early users rate it \(starsDisplay)★"

    /// Flip on once the counts are worth featuring; fill the two fields below.
    static let showsCounts = false
    static let ratingCount = 3      // real, but too small to show yet
    static let userCount   = 37     // real, but too small to show yet

    struct Cue: Identifiable {
        var id: String { label }
        let icon: String
        let label: String
    }
    static let trustCues: [Cue] = [
        .init(icon: "lock.shield", label: "Private"),
        .init(icon: "sparkles",    label: "AI-powered"),
        .init(icon: "gift",        label: "Free to start"),
    ]
}

/// Phase 19. First screen of the v2 onboarding flow.
///
/// Three jobs:
///   1. Say what the app does in one line (microcopy decided in spec).
///   2. Hint at the celebrity-coach voice as a unique feature without
///      naming a specific coach (intentional curiosity hook).
///   3. Provide one primary CTA + a secondary "Sign in" link for
///      returning users who already have an account.
///
/// Layout uses `HeroSnapScene` as the visual anchor — a bespoke,
/// animated pure-SwiftUI scene (viewfinder card + scan sweep + nutrient
/// fact-chips on hairline tethers) that previews the app's core magic
/// instead of a static food photo. Type tokens (Phase 14): `display1`
/// for the headline, `bodyV2` for the supporting paragraph, `caption`
/// for the secondary link.
struct OnboardingHeroView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var vm: OnboardingViewModel
    /// Shared CTA namespace from `OnboardingFlow`. When the user advances
    /// from hero → archetype the "Get started" pill matched-geometry
    /// morphs into the "Continue" pill on the next screen. Optional so
    /// previews still build with a stand-alone namespace.
    var ctaNamespace: Namespace.ID? = nil

    /// Stable id used by both this view's primary CTA and
    /// `OnboardingArchetypeView`'s Continue button. One per logical
    /// button — adding a second match here would tear the morph.
    static let ctaMatchedID = "onboardingPrimaryCTA"

    var body: some View {
        GeometryReader { proxy in
            let heroHeight = proxy.size.height * 0.45

            ScrollView {
                VStack(spacing: 0) {
                    heroImage(height: heroHeight)
                    content
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.bgCanvas.ignoresSafeArea())
        }
    }

    private func heroImage(height: CGFloat) -> some View {
        HeroSnapScene()
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ratingBadge

                Text("Snap a meal,\nknow what's in it.")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Foodie uses AI to break down nutrition from a photo. Coached by people who knew a thing or two about life.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)

                trustStrip
                    .padding(.top, AppSpacing.xs)
            }

            VStack(spacing: AppSpacing.sm) {
                PrimaryButton(title: "Get started",
                              leadingSystemImage: "sparkles") {
                    vm.startFromHero(isSignedIn: auth.isSignedIn)
                }
                .matchedCTA(Self.ctaMatchedID, in: ctaNamespace)

                if !auth.isSignedIn {
                    Button {
                        Haptics.tap()
                        vm.step = .signIn
                    } label: {
                        HStack(spacing: 4) {
                            Text("Already have an account?")
                                .appFont(.caption)
                                .foregroundStyle(Color.inkLight)
                            Text("Sign in")
                                .appFont(.caption)
                                .foregroundStyle(Color.brandDeep)
                                .underline()
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Already have an account? Sign in")
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.xl2)
    }

    // MARK: - Social proof

    /// Real 5.0★ with honest "early users" framing — no inflated count.
    private var ratingBadge: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentWarm)
                }
            }
            Text(OnboardingSocialProof.ratingLine)
                .appFont(.captionStrong)
                .foregroundStyle(Color.inkMute)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.bgSurface))
        .overlay(Capsule().strokeBorder(Color.borderHairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingSocialProof.ratingLine)
    }

    /// Scale-independent credibility cues (private / AI / free) — honest and
    /// effective even before the app has a large review base.
    private var trustStrip: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(OnboardingSocialProof.trustCues) { cue in
                HStack(spacing: 5) {
                    Image(systemName: cue.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.brandDeep)
                    Text(cue.label)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Matched-CTA helper

/// Applies `matchedGeometryEffect` only when a namespace is provided.
/// Optional so previews and any non-flow caller can drop the
/// `ctaNamespace` arg without restructuring the call site.
extension View {
    @ViewBuilder
    func matchedCTA(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Hero illustration: Snap-to-knowledge scene

/// Bespoke, animated onboarding hero. Replaces the old static food photo
/// with a pure-SwiftUI scene that previews the app's core magic: a meal
/// inside a viewfinder card, a soft scan-sweep "reading" it, and three
/// nutrient fact-chips resolving around it on hairline tethers — the same
/// callout language as the result screen's annotated photo, so the first
/// screen already shows the payoff.
///
/// Layers (back → front): canvas · AuroraWash · soft brand glow · tethers ·
/// viewfinder card (bowl + scan sweep + corner brackets) · fact-chips ·
/// sparkles · bottom fade into the copy below.
///
/// Motion is deliberate and gentle: the card floats, chips stagger in and
/// bob on independent phases, the sweep glides on a loop whose fade-at-ends
/// hides the reset. Reduce Motion renders a calm, fully-resolved resting
/// state — chips present, no sweep, no float.
private struct HeroSnapScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stagger-reveal gate for the chips + tethers.
    @State private var chipsIn = false
    /// Drives the card + chip float loops (each view attaches its own
    /// repeating animation keyed on this).
    @State private var floating = false
    /// 0…1 scan position; opacity fades to 0 at both ends so the loop
    /// reset is invisible.
    @State private var sweepPos: CGFloat = 0
    /// Sparkle twinkle loop.
    @State private var twinkle = false

    private struct ChipSpec: Identifiable {
        let id: String
        let value: String
        let unit: String
        let color: Color
        /// Chip center in normalized scene coordinates (0…1).
        let anchor: CGPoint
    }

    /// Three macros that flank the card (right / left / right) for a
    /// balanced-but-asymmetric float. Values are illustrative.
    private let chips: [ChipSpec] = [
        .init(id: "kcal",    value: "520", unit: "kcal",    color: .accentWarm, anchor: CGPoint(x: 0.80, y: 0.24)),
        .init(id: "carbs",   value: "32g", unit: "carbs",   color: .brand,      anchor: CGPoint(x: 0.15, y: 0.50)),
        .init(id: "protein", value: "28g", unit: "protein", color: .accentCool, anchor: CGPoint(x: 0.78, y: 0.72)),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cardW = min(w * 0.50, 196)
            let cardH = cardW * 1.16
            let cardCenter = CGPoint(x: w * 0.5, y: h * 0.46)
            let cardRect = CGRect(x: cardCenter.x - cardW / 2,
                                  y: cardCenter.y - cardH / 2,
                                  width: cardW, height: cardH)

            ZStack {
                Color.bgCanvas
                AuroraWash(intensity: 0.5)

                // Soft brand glow lifting the card off the canvas.
                Circle()
                    .fill(Color.brand.opacity(0.20))
                    .frame(width: cardW * 1.7, height: cardW * 1.7)
                    .blur(radius: 44)
                    .position(cardCenter)

                tetherCanvas(w: w, h: h, cardRect: cardRect)
                    .opacity(chipsIn ? 1 : 0)

                mealCard(rect: cardRect)
                    .position(cardCenter)
                    .offset(y: floating ? -5 : 0)
                    .animation(reduceMotion ? nil
                        : .easeInOut(duration: 3.6).repeatForever(autoreverses: true),
                        value: floating)

                ForEach(Array(chips.enumerated()), id: \.element.id) { idx, spec in
                    chipView(spec, index: idx)
                        .position(x: spec.anchor.x * w, y: spec.anchor.y * h)
                }

                sparkle(size: 20, at: CGPoint(x: 0.30, y: 0.15), color: .brandBright, phase: 0.0, w: w, h: h)
                sparkle(size: 13, at: CGPoint(x: 0.67, y: 0.86), color: .accentWarm,  phase: 0.6, w: w, h: h)
            }
            .frame(width: w, height: h)
            .clipped()
            .overlay(alignment: .bottom) {
                // Melt the scene into the copy that follows.
                LinearGradient(colors: [Color.bgCanvas.opacity(0), Color.bgCanvas],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
                    .allowsHitTesting(false)
            }
            .onAppear { animateIn() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A meal being analyzed into calories, carbs, and protein.")
    }

    // MARK: Card

    private func mealCard(rect: CGRect) -> some View {
        let d = min(rect.width, rect.height) * 0.66
        return ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color.brandIvory, Color.bgSurface],
                                     startPoint: .top, endPoint: .bottom))
            bowlView(diameter: d)
            scanSweep(cardW: rect.width, cardH: rect.height)
            CornerBrackets(inset: 12, arm: 16)
                .stroke(Color.brandDeep.opacity(0.55),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .shadow(color: Color.brandDeep.opacity(0.16), radius: 22, x: 0, y: 14)
    }

    /// Top-down bowl: a soft plate, four food-arc "piles" hugging the rim
    /// (colors echo the macro chips), a rice mound, and a leaf garnish.
    private func bowlView(diameter d: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white, Color.brandIvory],
                                     center: .center, startRadius: 0, endRadius: d * 0.5))
                .overlay(Circle().strokeBorder(Color.brandDeep.opacity(0.16), lineWidth: 2))

            foodArc(0.03, 0.22, .accentWarm, d)
            foodArc(0.28, 0.47, .brand, d)
            foodArc(0.53, 0.72, .brandBright, d)
            foodArc(0.78, 0.97, .accentCool, d)

            Circle()
                .fill(RadialGradient(colors: [Color.white, Color.brandSoft],
                                     center: .center, startRadius: 0, endRadius: d * 0.18))
                .frame(width: d * 0.32, height: d * 0.32)

            // Herb-leaf garnish on the rice mound — a vein keeps it
            // reading as a leaf rather than a speck at small sizes.
            ZStack {
                Leaf().fill(Color.brandDeep.opacity(0.9))
                Rectangle()
                    .fill(Color.brandBright.opacity(0.5))
                    .frame(width: 0.8, height: d * 0.16)
            }
            .frame(width: d * 0.15, height: d * 0.26)
            .rotationEffect(.degrees(-22))
            .offset(x: -d * 0.01, y: -d * 0.05)
        }
        .frame(width: d, height: d)
        .shadow(color: Color.brandDeep.opacity(0.10), radius: 5, x: 0, y: 3)
    }

    private func foodArc(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ d: CGFloat) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: d * 0.15, lineCap: .round))
            .frame(width: d * 0.66, height: d * 0.66)
            .shadow(color: color.opacity(0.35), radius: 3, x: 0, y: 1)
    }

    /// Soft bright bar gliding down the card. Clipped by the card's shape
    /// (this view lives inside the card ZStack). Fades to nothing at both
    /// travel ends so the repeat reset never shows.
    private func scanSweep(cardW: CGFloat, cardH: CGFloat) -> some View {
        let inset: CGFloat = 10
        let travel = cardH - inset * 2
        let y = inset + sweepPos * travel
        let alpha = reduceMotion ? 0 : sin(Double(sweepPos) * .pi)
        return ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.brandBright.opacity(0),
                             Color.brandBright.opacity(0.55),
                             Color.brandBright.opacity(0)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: cardW, height: cardH * 0.22)
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: cardW, height: 1.5)
        }
        .compositingGroup()
        .blendMode(.plusLighter)
        .opacity(alpha)
        .position(x: cardW / 2, y: y)
        .allowsHitTesting(false)
    }

    // MARK: Chips + tethers

    private func chipView(_ spec: ChipSpec, index: Int) -> some View {
        let bob: CGFloat = floating ? -CGFloat(3 + index % 2) : 0
        return HStack(spacing: 4) {
            Circle().fill(spec.color).frame(width: 7, height: 7)
            Text(spec.value).appFont(.captionStrong).foregroundStyle(Color.ink)
            Text(spec.unit).appFont(.caption).foregroundStyle(Color.inkMute)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.bgSurface))
        .overlay(Capsule().strokeBorder(Color.borderHairline, lineWidth: 1))
        .shadow(color: Color.brandDeep.opacity(0.12), radius: 8, x: 0, y: 4)
        .scaleEffect(chipsIn ? 1 : 0.9)
        .opacity(chipsIn ? 1 : 0)
        .offset(y: (chipsIn ? 0 : 10) + bob)
        .animation(.easeOut(duration: 0.5).delay(0.2 + Double(index) * 0.12), value: chipsIn)
        .animation(reduceMotion ? nil
            : .easeInOut(duration: 3.0 + Double(index) * 0.35)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.25),
            value: floating)
    }

    /// Hairline dashed tethers from each chip to the nearest point on the
    /// card border, each ending in a small filled disc — mirrors the
    /// result screen's annotated-photo connectors.
    private func tetherCanvas(w: CGFloat, h: CGFloat, cardRect: CGRect) -> some View {
        Canvas { ctx, _ in
            for spec in chips {
                let chipC = CGPoint(x: spec.anchor.x * w, y: spec.anchor.y * h)
                let ep = edgePoint(rect: cardRect, toward: chipC)
                var line = Path()
                line.move(to: ep)
                line.addLine(to: chipC)
                ctx.stroke(line, with: .color(Color.brandDeep.opacity(0.22)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let disc = Path(ellipseIn: CGRect(x: ep.x - 3, y: ep.y - 3, width: 6, height: 6))
                ctx.fill(disc, with: .color(Color.brand))
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the ray from the card center toward `p` exits the card
    /// rectangle (corner radius ignored — close enough for the disc).
    private func edgePoint(rect: CGRect, toward p: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = p.x - c.x
        let dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let sx = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: c.x + dx * s, y: c.y + dy * s)
    }

    // MARK: Sparkles

    private func sparkle(size: CGFloat, at n: CGPoint, color: Color,
                         phase: Double, w: CGFloat, h: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .opacity(twinkle ? 0.95 : 0.35)
            .scaleEffect(twinkle ? 1.05 : 0.7)
            .position(x: n.x * w, y: n.y * h)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil
                : .easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(phase),
                value: twinkle)
    }

    // MARK: Motion

    private func animateIn() {
        guard !reduceMotion else { chipsIn = true; return }
        chipsIn = true
        floating = true
        twinkle = true
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false)) {
            sweepPos = 1
        }
    }
}

// MARK: - Illustration shapes

/// Camera-viewfinder corner brackets (four L's) inset inside the frame.
private struct CornerBrackets: Shape {
    var inset: CGFloat = 12
    var arm: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        // Top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + arm))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
        // Top-right
        p.move(to: CGPoint(x: r.maxX - arm, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + arm))
        // Bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - arm))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - arm, y: r.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: r.minX + arm, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - arm))
        return p
    }
}

/// A simple pointed-oval leaf (two mirrored quadratic curves).
private struct Leaf: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w / 2, y: 0))
        p.addQuadCurve(to: CGPoint(x: w / 2, y: h),
                       control: CGPoint(x: w, y: h * 0.5))
        p.addQuadCurve(to: CGPoint(x: w / 2, y: 0),
                       control: CGPoint(x: 0, y: h * 0.5))
        return p
    }
}

#if DEBUG
#Preview("Hero — pre-auth") {
    OnboardingHeroView(vm: OnboardingViewModel())
        .environmentObject(AuthService())
}

#Preview("Hero scene") {
    HeroSnapScene()
        .frame(height: 360)
        .background(Color.bgCanvas)
}
#endif
