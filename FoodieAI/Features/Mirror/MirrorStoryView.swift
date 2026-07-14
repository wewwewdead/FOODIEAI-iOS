import SwiftUI
import UIKit

// Extracted from FoodMirrorView.swift (2026-07) to shrink the file.
// The full-screen Instagram-Stories-style FoodOS moment deck and its counting-number helper. Types are module-scoped so the parent view still references them.

// MARK: - Full-screen story view

/// Full-screen Wrapped-style story experience launched from the
/// Mirror tab's entry card. Pure interaction layer: it doesn't know
/// about the view model — page content is rendered by closures the
/// caller supplies. Owns its own navigation state (current index,
/// expanded album card, drag-to-dismiss offset, staggered-entrance
/// flag) so the parent never has to manage carousel internals.
///
/// Interaction model is explicit and deliberate: tap Next to advance
/// (no auto-advance, no timers), tap X to close at any time. The last
/// "page" is the album grid; tapping a thumbnail expands that card
/// full-screen with a matchedGeometry transition; dragging the
/// expanded card down interactively dismisses it back to the grid.
struct FoodMirrorStoryView: View {
    /// Ordered list of pages to show, including a trailing `.album`
    /// page when there's more than one content card to revisit.
    let pages: [FoodMirrorView.StoryPageKind]
    /// Renders a single non-album content page. The caller is
    /// responsible for matching kind → page renderer (so the cover
    /// stays decoupled from the view model that owns the moment,
    /// summary etc.). Called with `AnyView` so the cover can hold a
    /// uniform child type regardless of which page is showing.
    /// Second argument is the per-card "appeared" phase. The story
    /// view flips this false → true on each index change so per-
    /// element stagger and the value-card's bar-grow / count-up
    /// flourish can animate from a hidden state to their rest state.
    let renderPage: (FoodMirrorView.StoryPageKind, Bool) -> AnyView
    /// Renders the compact album thumbnail for a content page. Same
    /// rationale as `renderPage` — the cover doesn't know the
    /// page-specific styling.
    let renderAlbumThumbnail: (FoodMirrorView.StoryPageKind) -> AnyView
    /// VoiceOver label for an album thumbnail (typically the page's
    /// uppercase eyebrow). Empty string means no extra label.
    let albumAccessibilityLabel: (FoodMirrorView.StoryPageKind) -> String
    /// Fired when the user taps the X close button or the album's
    /// "Done" affordance. The parent uses this to flip the
    /// presentation flag and dismiss the full-screen cover.
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Current page index within `pages`. Manual advance only — no
    /// timer ever mutates this.
    @State private var index: Int = 0
    /// Per-card entrance flag. Reset to `false` immediately before
    /// each card change and flipped back to `true` on the next run
    /// loop, which drives `StoryShell`'s per-element `FlyIn` cascade
    /// (eyebrow → title → body → evidence → chips, one at a time)
    /// on every advance. Starts `false` so the FIRST card also runs
    /// the cascade once the cover settles in. Distinct from
    /// `presented` (whole-cover scale+fade); content elements inside
    /// the shell read `contentAppeared`, the cover wrapper reads
    /// `presented`.
    @State private var contentAppeared: Bool = false
    /// Whole-cover entrance flag. Drives the scale-from-0.90 +
    /// fade-from-0 "zoom open" the user sees the instant the cover
    /// appears. Replaces the broken matchedGeometryEffect zoom from
    /// the prior overlay experiment — the cover slide handles the
    /// presentation context, this spring sells the "expands open"
    /// inside that context.
    @State private var presented: Bool = false
    /// Which album card (if any) is currently expanded to full-
    /// screen. nil means we're showing the grid (or a non-album
    /// content page).
    @State private var expandedCard: FoodMirrorView.StoryPageKind? = nil
    /// Live drag distance for the interactive dismiss of the
    /// expanded album card. Only tracks downward translation
    /// (`max(0, …)`); used to offset, scale, and fade the card.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Opaque base layer FIRST. This is the fix for the
            // home-screen / Mirror-tab bleed-through that broke the
            // overlay attempt — guarantees the cover is fully opaque
            // edge to edge regardless of what the gradient above it
            // does. `bgCanvas` matches the Mirror tab's canvas color
            // so the cover reads as a continuation of that surface.
            Color.bgCanvas.ignoresSafeArea()

            backgroundLayer
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.md) {
                topBar
                cardArea
                bottomBar
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.lg)

            if let kind = expandedCard, kind != .album {
                expandedAlbumCard(kind)
                    // Symmetric scale + opacity transition for both
                    // open and close. The earlier "fly back to the
                    // exact thumbnail tile" version layered a
                    // `PreferenceKey` + `isClosing` flag + iOS-17
                    // `withAnimation` completion callback on top of
                    // each other, and the resulting state machine
                    // raced against rapid open/close interactions —
                    // a stale completion would tear down a freshly
                    // opened card, or the inner-frame measurement
                    // would lag a frame and produce a half-rendered
                    // card chrome. The simpler transition can't get
                    // stuck: SwiftUI always knows the start and end
                    // states, so the close is rock-solid no matter
                    // how fast the user open/close cycles.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.85)
                                .combined(with: .opacity)
                    )
            }
        }
        // Whole-cover zoom-open: scale from 0.90 + fade from 0 on
        // appear so the story content "expands into" the cover
        // rather than hard-cutting. The cover's own slide-up still
        // plays underneath; this adds the "blooms open" feel that
        // the prior matched-geometry attempt was trying (and failing)
        // to provide. Reduce Motion sticks at rest values — no
        // scale, no fade.
        .scaleEffect(presented || reduceMotion ? 1.0 : 0.90)
        .opacity(presented || reduceMotion ? 1.0 : 0.0)
        .onAppear {
            // First-card fly-in: flipping `contentAppeared` here
            // (not just in `onChange(of: index)`) is what makes the
            // FIRST card's per-element cascade actually run. Before
            // this, the initial value was already `true` so card 1
            // skipped the kinetic stagger entirely — exactly the
            // "fly-in didn't render" symptom from the prior pass.
            if reduceMotion {
                presented = true
                contentAppeared = true
            } else {
                withAnimation(
                    .spring(response: 0.42, dampingFraction: 0.82)
                ) {
                    presented = true
                }
                withAnimation(
                    .spring(response: 0.5, dampingFraction: 0.7)
                ) {
                    contentAppeared = true
                }
            }
        }
        // Note: the per-card fly-in reset used to live in an
        // `.onChange(of: index)` block here, but that fired AFTER
        // the new card had already mounted via the `.id()` change
        // in `cardArea` — so the new view read `contentAppeared`
        // at its initial value and FlyIn never saw an animatable
        // false→true transition on the live view. The ordering
        // now lives inside `advance()` (false BEFORE the index
        // mutation so the new view mounts hidden, true AFTER a
        // short delay so FlyIn animates on the mounted view).
    }

    // MARK: - Background

    /// Soft brand-tinted gradient that fills the whole screen behind
    /// the story content. Matches the Mirror tab's visual language
    /// (brandSoft → bgSurface) so the transition into the cover
    /// feels continuous with the tab it came from.
    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                Color.brandSoft.opacity(0.6),
                Color.bgSurface
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Top bar

    /// Progress segments + close button. Segments are *binary* — a
    /// page is either seen (or current) or upcoming. No timed fill,
    /// no animated tick; the bar updates only when the user advances.
    private var topBar: some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: 4) {
                ForEach(0..<max(pages.count, 1), id: \.self) { i in
                    Capsule()
                        .fill(
                            i < index
                                ? Color.brandDeep
                                : i == index
                                    ? Color.brand
                                    : Color.brand.opacity(0.2)
                        )
                        .frame(height: 4)
                        .accessibilityHidden(true)
                }
            }
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.inkMute)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(Color.bgSurface.opacity(0.85))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close story"))
        }
    }

    // MARK: - Card area

    /// The current page rendered inside a brand-tinted card surface.
    /// On index change, the new card replaces the old with an
    /// asymmetric slide (trailing → leading). The per-card entrance
    /// is now driven INSIDE the card by `StoryShell`'s `FlyIn`
    /// cascade (eyebrow → title → body → evidence → chips, one at
    /// a time) — the old whole-card scale+opacity wrap was removed
    /// because it competed with the per-element animation and read
    /// as a single block-in instead of the intended Duolingo-style
    /// staggered assembly.
    @ViewBuilder
    private var cardArea: some View {
        let kind = currentKind
        Group {
            if let kind, kind == .album {
                albumGrid
                    .id("album")
            } else if let kind {
                cardSurface {
                    renderPage(kind, contentAppeared)
                }
                .id("card-\(kind.rawValue)-\(index)")
            } else {
                // Defensive: empty pages list shouldn't be possible
                // (the entry card hides when there's nothing to
                // show), but render a neutral surface rather than
                // an empty cover if it ever happens.
                cardSurface { AnyView(EmptyView()) }
            }
        }
        .transition(cardTransition)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Visual frame that wraps each content page. Same rounded
    /// surface + hairline + soft shadow as the Mirror tab cards, so
    /// a tap-through into the story doesn't feel like leaving the
    /// app's design system.
    private func cardSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(Color.brand.opacity(0.18), lineWidth: 1)
            )
            .appShadow(.shadowCard)
    }

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Album grid (full-screen)

    /// Full-screen recap grid. Each thumbnail is wired to a
    /// matchedGeometry pair with `expandedAlbumCard` so tapping a
    /// tile springs it into a full-size card. `isSource` flips off
    /// the thumbnail's side while it's expanded so SwiftUI only sees
    /// a single source rect per id at a time (avoids the
    /// "duplicate matchedGeometryEffect source" warning that breaks
    /// the transition).
    private var albumGrid: some View {
        let contentPages = pages.filter { $0 != .album }
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.brandSoft)
                        .frame(width: 44, height: 44)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.brandDeep)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR MOMENTS")
                        .eyebrow()
                        .foregroundStyle(Color.brandDeep)
                    Text("Tap any card to revisit it.")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                }
                Spacer(minLength: 0)
            }

            ScrollView(showsIndicators: false) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: AppSpacing.sm),
                        GridItem(.flexible(), spacing: AppSpacing.sm)
                    ],
                    spacing: AppSpacing.sm
                ) {
                    ForEach(contentPages) { kind in
                        renderAlbumThumbnail(kind)
                            .contentShape(
                                RoundedRectangle(cornerRadius: AppRadius.lg)
                            )
                            .onTapGesture {
                                Haptics.tap()
                                dragOffset = 0
                                if reduceMotion {
                                    expandedCard = kind
                                } else {
                                    withAnimation(
                                        .spring(response: 0.4,
                                                dampingFraction: 0.85)
                                    ) {
                                        expandedCard = kind
                                    }
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(
                                Text(albumAccessibilityLabel(kind))
                            )
                            .accessibilityHint(
                                Text("Opens this card.")
                            )
                    }
                }
                .padding(.top, AppSpacing.xs)
            }
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.brand.opacity(0.18), lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }

    // MARK: - Expanded album card (interactive dismiss)

    /// Full-screen view of a single album card with interactive
    /// drag-down dismiss.
    ///
    /// While the user drags down, the card follows the finger
    /// (`dragOffset` driven directly by the gesture), scales down
    /// slightly, and the scrim behind it brightens. Release past the
    /// threshold → `collapseExpanded` sets `expandedCard = nil`
    /// inside a spring; the overlay's `.transition(.scale + .opacity)`
    /// runs the removal — the card shrinks down from its
    /// (drag-adjusted) position and fades out. Release short → the
    /// drag offset springs back to zero.
    ///
    /// An earlier version tried to fly the card back to the exact
    /// thumbnail tile using a `PreferenceKey` for the grid frame, an
    /// `isClosing` flag, and an iOS-17 `withAnimation` completion
    /// callback. That state machine raced against rapid open/close
    /// interactions (stale completions tearing down freshly opened
    /// cards, half-rendered chrome on re-entry) and was deleted in
    /// favour of the simpler, race-free transition you see here.
    private func expandedAlbumCard(
        _ kind: FoodMirrorView.StoryPageKind
    ) -> some View {
        // 100pt threshold — easy to commit to once the user has
        // started dragging downward. Short releases snap back to
        // expanded centre.
        let dismissThreshold: CGFloat = 100
        let dismissProgress = min(abs(dragOffset) / 300.0, 1.0)

        let offsetY: CGFloat = dragOffset
        let scale: CGFloat = 1 - dismissProgress * 0.15
        let opacity: Double = 1 - dismissProgress * 0.5
        let scrimOpacity: Double = 0.25 * (1 - dismissProgress)

        return ZStack {
            Color.black.opacity(scrimOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { collapseExpanded() }

            // Note: no `appShadow` here. The shadow was the single
            // biggest cost on the expand spring — rasterising it
            // every frame against changing content. The card
            // already has a hairline border + the dim scrim behind
            // it to set it off from the background.
            // Expanded album cards are presented via a scale-up
            // transition rather than a fresh per-element cascade, so
            // we pass `appeared: true` — the inner content renders at
            // its rest state immediately while the outer card scales.
            renderPage(kind, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.bgSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .strokeBorder(Color.brand.opacity(0.22),
                                      lineWidth: 1)
                )
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.xl2)
                .scaleEffect(scale, anchor: .center)
                .offset(y: offsetY)
                .opacity(opacity)
                // `.highPriorityGesture` (not `.gesture`) so the
                // dismiss drag wins over the StoryShell's inner
                // `ScrollView`, which would otherwise consume every
                // vertical pan and leave the user unable to dismiss.
                // Trade-off: the card's content isn't vertically
                // scrollable while expanded. Acceptable here because
                // full-screen gives much more room than the old
                // 500pt container, so the cards already fit. The
                // 12pt `minimumDistance` keeps short flicks and
                // mis-taps from triggering an accidental drag — taps
                // on inner Buttons (e.g. the moment feedback chips)
                // still go through because tap and drag are routed
                // separately.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // Only follow downward drags; ignore
                            // tiny upward jitter so the user doesn't
                            // see the card hop above its expanded
                            // position.
                            dragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > dismissThreshold {
                                collapseExpanded()
                            } else {
                                withAnimation(
                                    reduceMotion
                                        ? .none
                                        : .spring(response: 0.35,
                                                  dampingFraction: 0.8)
                                ) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
                .accessibilityAddTraits(.isModal)
        }
    }

    /// Dismisses the expanded card. The overlay's `.transition`
    /// (scale + opacity) handles the visual — the card shrinks from
    /// its current drag-adjusted state to 0.85 scale and fades out.
    /// No state machine, no completion callbacks, no preference-key
    /// dance. SwiftUI knows the start and end states cold, so this
    /// cannot get stuck no matter how rapidly the user open/close
    /// cycles.
    private func collapseExpanded() {
        Haptics.tap()
        if reduceMotion {
            expandedCard = nil
            dragOffset = 0
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                expandedCard = nil
                dragOffset = 0
            }
        }
    }

    // MARK: - Bottom bar

    /// "Next" / "See your moments" / "Done" — single primary CTA
    /// keyed off the current page. Hidden when an album card is
    /// expanded (the drag-to-dismiss is the only action that makes
    /// sense in that overlay) so the user isn't tempted to advance
    /// past their expanded card by accident.
    @ViewBuilder
    private var bottomBar: some View {
        if expandedCard == nil {
            Button {
                advance()
            } label: {
                Text(nextButtonLabel)
                    .appFont(.pillTitle)
                    // Ink-on-brand, not white-on-brand: white on lime (#B8CA38)
                    // fails WCAG contrast. Ink is the AA-verified pairing.
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(
                        Capsule().fill(Color.brand)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(nextButtonLabel))
        } else {
            // Reserve the same height so the card above doesn't jump
            // when the button hides; keeps the layout perfectly still
            // through the expand/collapse spring.
            Color.clear.frame(height: 56)
        }
    }

    private var nextButtonLabel: String {
        guard let kind = currentKind else { return "Done" }
        if kind == .album { return "Done" }
        if index == pages.count - 2,
           pages.last == .album {
            return "See your moments"
        }
        return "Next"
    }

    private var currentKind: FoodMirrorView.StoryPageKind? {
        guard index >= 0, index < pages.count else { return nil }
        return pages[index]
    }

    private func advance() {
        Haptics.tap()
        guard let kind = currentKind else {
            onClose()
            return
        }
        if kind == .album {
            onClose()
            return
        }
        let next = min(index + 1, pages.count - 1)
        if next == index {
            // Already at the end with no album to roll into (single-
            // card story): treat Next as Done.
            onClose()
            return
        }
        // Step 1: hide content of the upcoming card BEFORE it
        // mounts. Because `cardArea` recreates the card view on
        // every index change (via `.id("card-…")`), the new view
        // reads `contentAppeared` at mount time — so it must be
        // false at this moment for FlyIn to have a hidden start
        // state to animate from.
        contentAppeared = false

        if reduceMotion {
            index = next
            contentAppeared = true
            return
        }

        // Step 2: change the index. The new card mounts with
        // `contentAppeared == false`, so its FlyIn elements are
        // hidden (opacity 0, offset 24) while the slide plays.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            index = next
        }

        // Step 3: after the new card has mounted (and the slide
        // is settling), flip the flag on the now-live view. This
        // is the false→true transition FlyIn's `.animation(value:
        // appeared)` actually animates — element by element, with
        // the per-order delay cascade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                contentAppeared = true
            }
        }
    }
}

/// Two-bar reveal's signature beat: a number that rolls 0 → target
/// when `appeared` flips. Generation token cancels any in-flight
/// dispatch loop if the card is replaced mid-animation (rapid Next
/// taps), so a stale schedule can't overwrite the next card's
/// counting state.
///
/// Under Reduce Motion the number jumps straight to `target`.
struct CountingNumber: View {
    let target: Double
    let unit: String
    let valueFont: AppFont.Style
    let valueColor: Color
    let appeared: Bool
    let reduceMotion: Bool

    @State private var shown: Double = 0
    @State private var generation: Int = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(Int(shown.rounded()))")
                .appFont(valueFont)
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(unitDisplay)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
        .onAppear {
            if appeared {
                if reduceMotion { shown = target }
                else            { runCount() }
            }
        }
        .onChange(of: appeared) { _, now in
            if !now {
                // Card stepping away — cancel any pending schedule
                // and reset to baseline so the next appearance
                // starts cleanly.
                generation += 1
                shown = 0
                return
            }
            if reduceMotion { shown = target; return }
            runCount()
        }
        .onChange(of: target) { _, newTarget in
            // The owning moment can recompute while this card is
            // still mounted (refresh tick, new logs landing). The
            // parent re-renders with fresh `reveal.before/after`,
            // but `shown` is @State so it keeps the previous
            // moment's settled value — leaving the bar NUMBER
            // stale while the title, bar heights, and delta pill
            // already reflect the new moment. Re-drive `shown` so
            // all three stay in sync.
            guard appeared else { return }
            if reduceMotion { shown = newTarget; return }
            runCount()
        }
    }

    private var unitDisplay: String {
        // Counts (meals / foods) read better with a leading space;
        // mass and energy units sit flush per nutrition-label
        // convention.
        switch unit {
        case "meals", "foods": return " \(unit)"
        default:               return unit
        }
    }

    private func runCount() {
        generation += 1
        let gen = generation
        let steps = 20
        let duration = 0.6
        shown = 0
        for i in 1...steps {
            let when = DispatchTime.now()
                + duration * Double(i) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: when) {
                // Stale schedule from a prior appearance — ignore.
                guard gen == generation else { return }
                shown = target * Double(i) / Double(steps)
            }
        }
    }
}
