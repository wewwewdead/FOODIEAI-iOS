import SwiftUI
import UIKit

/// Editorial magazine-style result page.
///
/// Vertical zone flow (top to bottom):
///   1. Title block — brand mark + "Meal analysis" eyebrow + headline
///      food name (tap-to-edit) + optional repeat chip.
///   2. Hero photo — full-width 4:3, radius-xl, card shadow. No
///      callouts on the photo itself; the coach lives in zone 4.
///   3. "By the numbers" — 3×2 macro grid (calories, carbs, sugar /
///      protein, fat, fiber). Missing values render as "—".
///   4. "From your coach" — EditorialQuote with the coach advice + a
///      small inline reaction bubble underneath.
///   5. "Insights" — three CategoryAccordions (nutrients / benefits /
///      drawbacks) with the existing typewriter reveal.
///   6. Save action — PrimaryButton + Discard link, in-flow at the
///      bottom (this view is hosted in a ScrollView).
///
/// The image is provided by the parent (`CaptureViewModel.state.image`)
/// so we can render the user's photo without re-loading it from Storage.
/// On revisit (saved-meal expansion in DayDetailSheet / Tracker), the
/// MealRow / FullImageViewer paths already cover the photo display.
/// Reward-pill phase. Separate from `isSaving` so the pill copy doesn't
/// claim "Added to today" before the meal actually lands — `isSaving`
/// alone can't distinguish success from a transient saving→failed bounce.
///
/// Mapping responsibility lives at the call site (CaptureView), keyed off
/// `CaptureViewModel.State`. The view itself only consumes the phase.
enum SaveRewardPhase: Equatable {
    case idle
    case saving
    case saved
}

struct AnalysisResultView: View {
    let image: UIImage?
    let response: AnalyzeResponse
    var isSaving: Bool = false
    /// Drives the reward pill copy/animation independently of
    /// `isSaving` (which the PrimaryButton uses for its loading state).
    /// Default `.idle` keeps existing call sites silent until they
    /// opt in.
    var saveRewardPhase: SaveRewardPhase = .idle
    /// Optional pre-scan calorie status. When supplied, the result page
    /// shows a tiny day-aware line ("This still keeps you within today's
    /// goal." / etc.) computed from the *predicted* post-save total.
    /// Nil hides the line entirely — invalid/missing goals are not a
    /// place to surface vague copy.
    var dailyStatus: DailyCalorieGoalStatus? = nil
    /// User's weight-goal direction (lose / maintain / gain). Drives the
    /// framing of the goal-standing block: "earn it back" effort only
    /// appears for lose/maintain; gain stays positive. Nil → treated as a
    /// neutral cut (lose/maintain framing) so the line is never silent.
    var goalDirection: CalorieGoalCalculator.GoalDirection? = nil
    /// User's body weight (kg) for the personalized burn-off estimate.
    /// Nil falls back to a neutral adult default inside `ActivityBurnEstimator`.
    var bodyWeightKg: Double? = nil
    /// User-corrected food name from a prior tap-to-edit. When set,
    /// shadows `analysis.food` in the detected block so the corrected
    /// name reads first. Nil = show what the AI returned.
    var foodNameOverride: String? = nil
    /// On-device pattern insight. Pure enrichment — never overrides
    /// Gemini's calories/macros. Renders a "Your Pattern" card below
    /// the editorial quote when the user has prior observations for
    /// this food; for first-time foods the card is suppressed
    /// entirely (no empty placeholder) so a new meal looks identical
    /// to the v1 result page.
    var patternInsight: FoodPatternInsight? = nil
    /// Fired when the user commits an inline food-name edit. Trimmed,
    /// non-empty value. Parent threads this into the view model so it
    /// flows into `save()` (pre-save) or a `food_logs` row patch
    /// (post-save).
    var onFoodNameEdited: ((String) -> Void)? = nil
    /// Uncertainty-aware naming. Fired when the user picks an alternative
    /// chip OR submits a custom name from the "Something else…" field.
    /// Triggers a server re-analysis anchored on the corrected dish
    /// (calories/macros recompute). Server treats this as a refinement
    /// and does NOT charge it against the daily scan limit.
    var onFoodNameCorrected: ((String) -> Void)? = nil
    /// Optional shared namespace for the experimental capture→result photo
    /// morph. Nil — the default and every existing call site — keeps the
    /// result photo static (no matched geometry, exactly today's reveal).
    /// Non-nil means the parent has the morph engaged (flag on + Reduce
    /// Motion off), so the meal photo becomes the matched-geometry
    /// destination and its corner radius settles from near-circular.
    var morphNamespace: Namespace.ID? = nil
    /// Seconds to hold the content reveal (cascade + typewriters) after the
    /// view appears, so the genie warp-back can play *first*. The parent passes
    /// `AnalyzingOrbTiming.returnSettleSeconds` when the orb journey is active
    /// and `0` otherwise (Reduce Motion / feature off / revisits) — so every
    /// non-warp call site keeps today's instant reveal. The whole choreography
    /// shifts by this one offset, preserving the tuned per-element stagger.
    var revealDelay: TimeInterval = 0
    let onSave: () -> Void
    let onCancel: () -> Void

    /// Inline food-name edit. When true, the detected block swaps the
    /// title Text for a TextField focused on appear. `editedNameDraft`
    /// holds the in-progress value; commit trims and pushes through
    /// `onFoodNameEdited`. Empty/whitespace-only submissions revert.
    @State private var isEditingName: Bool = false
    @State private var editedNameDraft: String = ""
    @FocusState private var foodNameFieldFocused: Bool
    /// Uncertainty UI — shown when the model returned low/medium
    /// `nameConfidence` or a non-empty `nameAlternatives`. We surface
    /// the suggestions only until the user has committed a correction
    /// (then they trust their pick and don't need to be re-prompted).
    @State private var hasAcceptedNameCorrection: Bool = false
    /// Drives the inline "Something else…" custom-name TextField.
    @State private var isEnteringCustomName: Bool = false
    @State private var customNameDraft: String = ""
    @FocusState private var customNameFieldFocused: Bool
    /// One-shot bounce trigger for the "Edit name" pill's pencil glyph.
    /// Flips 0 → 1 once after the cascade reveal so the symbolEffect
    /// plays exactly once per result-view lifetime.
    @State private var ctaNudge: Int = 0
    /// Press-state scale for the Edit pill — kept on the view so we can
    /// drive it from button gestures if we wire one in later. For now
    /// it stays at 1; the nudge alone is enough attention-getter
    /// without a constant pulse.
    @State private var ctaPressScale: CGFloat = 1.0
    /// Cascade reveal — set true on appear so the detected title and
    /// macro chips fade up in sequence after the photo card lands. Driven
    /// by a single state flag (not a per-element Task) so SwiftUI handles
    /// the timeline via per-modifier `.delay()`; nothing to cancel.
    @State private var cascadeOn: Bool = false
    /// Guards the one-shot reveal scheduling so a re-render (e.g. the
    /// typewriter ticking, or a save state change) never re-arms the delayed
    /// cascade. Separate from `cascadeOn` because the flip is now deferred by
    /// `revealDelay`, so we can't use `cascadeOn` itself as the latch.
    @State private var cascadeScheduled: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Phase 15 — repeat detection. Populated by a non-blocking
    /// `MealHistoryService.priorOccurrences(of:)` query in `.task`.
    /// `nil` means the query hasn't returned yet; `0` means it has and
    /// there are no priors. We render the chip only when `>= 1`.
    @State private var priorCount: Int? = nil
    @State private var lastPriorDate: Date? = nil
    /// Week 3 — optional time-of-day cluster ("morning"/"lunch"/etc.)
    /// derived from prior occurrences. Surfaced only when 2+ priors
    /// fall in the same daypart; otherwise nil and the chip uses the
    /// "last time" suffix instead.
    @State private var timeOfDayCluster: String? = nil

    /// Display-resolution UIImage. The captured source can be up to
    /// 2048pt long-edge JPEG; SwiftUI's `Image(uiImage:).resizable()` will
    /// decode + rescale that on every redraw during scroll, which is the
    /// largest source of jank on this screen. We downsample once on
    /// appear to ~700pt long-edge (still retina-sharp at the hero size)
    /// and render from this cache instead. Falls back to `image` until
    /// the downsample lands so the screen never shows an empty card.
    @State private var displayImage: UIImage? = nil

    /// Drives the morph's corner-radius settle. Starts false (near-circular,
    /// matching the round bubble) and flips true on appear under `.appMorph`
    /// so the photo rounds down to the thumbnail radius as it lands. Only
    /// consulted when `morphNamespace != nil`.
    @State private var photoMorphSettled: Bool = false

    private var analysis: GeminiAnalysis { response.analysis }

    /// Corner radius for the result meal photo. Static at the thumbnail
    /// radius normally; during the bubble→photo morph it starts near-
    /// circular and rounds down to the thumbnail radius via `.appMorph`, so
    /// the photo "sets" out of the round analyzing bubble. Only animated
    /// when a morph namespace is supplied.
    private var photoCornerRadius: CGFloat {
        guard morphNamespace != nil else { return AppRadius.lg }
        return photoMorphSettled ? AppRadius.lg : BubbleMorphFeature.circularRadius
    }

    /// Stable scroll target id used by `CaptureView`'s `ScrollViewReader`
    /// to focus the typewriter cascade once analyze succeeds. Always
    /// present in the view tree even when there's no coach advice, so
    /// scroll-to-anchor never misses.
    static let cascadeAnchorID = "analysisCascadeAnchor"

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl2) {
            // Zone 1 — editorial title block: brand mark, eyebrow,
            // headline food name, repeat chip.
            titleBlock
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 10)
                .animation(cascadeAnim(delay: 0.10), value: cascadeOn)

            // Zone 2 — annotated photo: centered hero photo with macro
            // callouts arranged around its perimeter, each tethered by a
            // dashed line and a small endpoint disc. Replaces the prior
            // photo card + 3×2 grid pair.
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                sectionEyebrow("By the numbers")
                annotatedPhotoBlock
                goalStandingBlock
            }
            .opacity(cascadeOn ? 1 : 0)
            .offset(y: cascadeOn ? 0 : 8)
            .animation(cascadeAnim(delay: 0.20), value: cascadeOn)

            // Scroll anchor: CaptureView scrolls to this point when the
            // /analyze request returns, so the typewriter cascade fills
            // the viewport while the user reads it.
            Color.clear
                .frame(height: 0)
                .id(Self.cascadeAnchorID)

            // Zone 4 — "From your coach": editorial quote + reaction.
            // Container fades up; the typewriter inside `EditorialQuote`
            // continues to drive the text reveal on its own clock.
            Group {
                if let advice = analysis.coachAdvice, !advice.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        sectionEyebrow("From your coach")
                        quoteBlock
                        coachReactionBubble
                    }
                } else if response.coach?.isEmpty == false {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        sectionEyebrow("From your coach")
                        coachReactionBubble
                    }
                }
            }
            .opacity(cascadeOn ? 1 : 0)
            .offset(y: cascadeOn ? 0 : 8)
            .animation(cascadeAnim(delay: 0.30), value: cascadeOn)

            // Zone 4b — "Your Pattern": on-device insight card. Renders
            // only when the user has enough priors for the current food
            // to say something honest; otherwise the zone collapses to
            // zero height (no empty placeholder).
            yourPatternZone
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 8)
                .animation(cascadeAnim(delay: 0.35), value: cascadeOn)

            // Zone 5 — "Insights": the three category accordions.
            // Container fades up; the per-accordion typewriter keeps its
            // existing 0.5 / 0.7 / 0.9 staggered start delays.
            if hasAnyInsights {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    sectionEyebrow("Insights")
                    accordions
                }
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 8)
                .animation(cascadeAnim(delay: 0.40), value: cascadeOn)
            }

            // Zone 6 — save action.
            saveBlock
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 8)
                .animation(cascadeAnim(delay: 0.50), value: cascadeOn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tap-outside-to-commit: while editing the food name, any tap
        // that doesn't land on an interactive child (the field itself,
        // Save/Cancel buttons, accordion headers, the PrimaryButton)
        // falls through to this gesture and commits the edit. iOS's
        // gesture exclusivity ensures Button-style children swallow
        // their own taps first, so this only fires for "outside" taps.
        // `contentShape(Rectangle())` is required because a VStack's
        // own hit area defaults to its content's union — without it,
        // taps on the spacing between sections wouldn't register.
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditingName {
                commitFoodNameEdit()
            }
        }
        .onAppear {
            // Idempotent: arm exactly once. When the orb journey is active the
            // parent passes a `revealDelay` so the breakdown holds until the
            // genie warp has landed; otherwise it's 0 and the cascade fires
            // immediately, exactly as before.
            guard !cascadeScheduled else { return }
            cascadeScheduled = true
            guard revealDelay > 0 else { cascadeOn = true; return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(revealDelay * 1_000_000_000))
                cascadeOn = true
            }
        }
        .task(id: analysis.food ?? "") {
            await loadPriorOccurrences()
        }
        // Downsample the captured image off-main exactly once per source
        // image. Keyed off identity (object pointer + size) so a fresh
        // analyze run replaces the cache cleanly. Scrolling never touches
        // the JPEG decoder again — the smaller bitmap is what renders.
        .task(id: imageIdentity) {
            await downsampleSourceImageIfNeeded()
        }
    }

    /// Stable identity for the source image so `.task(id:)` re-fires only
    /// when the image itself changes, not on every re-render. UIImage is a
    /// reference type, so `ObjectIdentifier` is sufficient; the size hash
    /// is a belt-and-braces guard for cases where the parent passes a new
    /// derivative with the same pointer.
    private var imageIdentity: String {
        guard let image else { return "nil" }
        return "\(ObjectIdentifier(image).hashValue)-\(Int(image.size.width))x\(Int(image.size.height))"
    }

    /// Off-main downsample. Runs at user-initiated priority so it lands
    /// before the eye notices the placeholder, and skips work entirely
    /// when the source is already small enough.
    @MainActor
    private func downsampleSourceImageIfNeeded() async {
        guard let source = image else { return }
        let target = await Task.detached(priority: .userInitiated) {
            Self.downsample(source, maxDimensionPt: 720)
        }.value
        // Bail if a newer task already populated `displayImage`.
        guard displayImage !== target else { return }
        displayImage = target
    }

    /// Renders a downscaled copy of `image` at `maxDimensionPt` * screen
    /// scale. Opaque format keeps the bitmap small and avoids an alpha
    /// channel we don't need (the rounded clip is applied by SwiftUI on
    /// top). Returns the original when no downscale is needed.
    private static func downsample(_ image: UIImage,
                                   maxDimensionPt: CGFloat) -> UIImage {
        let screenScale = UIScreen.main.scale
        let maxPx = maxDimensionPt * screenScale
        let widthPx = image.size.width * image.scale
        let heightPx = image.size.height * image.scale
        let longestPx = max(widthPx, heightPx)
        guard longestPx > maxPx else { return image }
        let downscale = maxPx / longestPx
        let newSize = CGSize(
            width: image.size.width * downscale,
            height: image.size.height * downscale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Cascade reveal curve: the existing `.motionReveal` spring with a
    /// per-section delay so detected title → calories → macro chips land
    /// one after the other. Reduce Motion swaps to a flat fade.
    private func cascadeAnim(delay: Double) -> Animation {
        reduceMotion
            ? .appReduced
            : .motionReveal.delay(delay)
    }

    // MARK: - Phase 15 — repeat detection

    /// Fire-and-forget query for prior occurrences of the detected food
    /// name. Failures are silent — the chip is non-essential, and the
    /// rest of the result page is fully functional without it.
    private func loadPriorOccurrences() async {
        guard let name = analysis.food, !name.isEmpty else { return }
        do {
            let priors = try await MealHistoryService()
                .priorOccurrences(of: name, excluding: nil)
            let cluster = Self.dominantDaypart(in: priors.map(\.eatenAt))
            await MainActor.run {
                self.priorCount = priors.count
                self.lastPriorDate = priors.first?.eatenAt
                self.timeOfDayCluster = cluster
            }
        } catch is CancellationError {
            // SwiftUI cancelled `.task` (food name changed, view torn
            // down). Don't paint a fake "no priors" state — the next
            // task run will repopulate it.
            return
        } catch {
            #if DEBUG
            NSLog("[Repeat] priorOccurrences failed: %@", "\(error)")
            #endif
            // Leave priorCount as nil — UI hides the chip in either
            // the nil or 0 case, so a failed query reads identically
            // to "first time".
        }
    }

    // MARK: - Section eyebrow helper

    /// Editorial section eyebrow. Uses the existing `.eyebrow()` styling
    /// (11pt Nunito ExtraBold, +2 tracking, uppercase) tinted brandDeep
    /// so it reads as a magazine-style "kicker" above each zone.
    private func sectionEyebrow(_ text: String) -> some View {
        Text(text).eyebrow()
            .foregroundStyle(Color.brandDeep)
    }

    // MARK: - Zone 1 — title block

    /// Editorial title: small brand-tinted mark on the leading edge,
    /// uppercase "Meal analysis" eyebrow, then the headline food name
    /// (with tap-to-edit + repeat chip beneath).
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 32, height: 32)
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brandDeep)
                }
                Text("Meal analysis").eyebrow()
                    .foregroundStyle(Color.brandDeep)
                    .tracking(2.4)
                Spacer(minLength: 0)
            }
            editableFoodName
            nameSuggestionsBlock
            repeatChip
        }
    }

    // MARK: - Uncertainty-aware naming suggestions

    /// True when the model expressed name uncertainty AND the user
    /// hasn't already committed a correction this session. Suppressed
    /// during inline edit to avoid competing affordances.
    private var shouldShowNameSuggestions: Bool {
        guard !hasAcceptedNameCorrection else { return false }
        guard !isEditingName else { return false }
        guard onFoodNameCorrected != nil else { return false }
        return analysis.isNameUncertain
    }

    /// "Is this right?" prompt + tappable alternatives + custom-entry
    /// affordance. Rendered only when `shouldShowNameSuggestions`. The
    /// chips are wrapped via a simple FlowLayout so longer dish names
    /// (e.g. "Ppyeo-haejangguk (pork bone soup)") flow to a second row
    /// without clipping.
    @ViewBuilder
    private var nameSuggestionsBlock: some View {
        if shouldShowNameSuggestions {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Is this right?")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brandDeep)

                NameSuggestionFlow(spacing: 8, runSpacing: 8) {
                    ForEach(uniqueAlternatives, id: \.self) { alt in
                        suggestionChip(label: alt) {
                            commitNameCorrection(alt)
                        }
                    }
                    suggestionChip(
                        label: "Something else…",
                        systemImage: "pencil",
                        emphasized: false
                    ) {
                        beginCustomNameEntry()
                    }
                }

                if isEnteringCustomName {
                    customNameField
                        .transition(.opacity.combined(
                            with: .move(edge: .top)
                        ))
                }
            }
            .padding(.top, 2)
            .transition(.opacity)
        }
    }

    /// Dedupe + drop any alternative that equals the displayed name
    /// (case-insensitive, whitespace-trimmed) so we never offer the
    /// user a chip that re-asserts what's already on screen.
    private var uniqueAlternatives: [String] {
        let raw = analysis.nameAlternatives ?? []
        let currentKey = displayedFoodName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var seen = Set<String>()
        seen.insert(currentKey)
        var out: [String] = []
        out.reserveCapacity(raw.count)
        for s in raw {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                out.append(trimmed)
            }
        }
        return Array(out.prefix(3))
    }

    private func suggestionChip(label: String,
                                systemImage: String? = nil,
                                emphasized: Bool = true,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .bold))
                }
                Text(label)
                    .appFont(.captionStrong)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(emphasized ? Color.brandDeep : Color.inkMute)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(emphasized ? Color.brandSoft : Color.bgSurface)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        emphasized
                            ? Color.brand.opacity(0.55)
                            : Color.borderHairline,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            emphasized ? "Use suggestion \(label)" : label
        )
    }

    private var customNameField: some View {
        HStack(spacing: AppSpacing.sm) {
            TextField("Type the dish name",
                      text: $customNameDraft)
                .font(AppFont.font(.bodyEmphasis))
                .foregroundStyle(Color.ink)
                .tint(Color.brand)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .autocorrectionDisabled(false)
                .textInputAutocapitalization(.sentences)
                .focused($customNameFieldFocused)
                .onSubmit { commitCustomNameEntry() }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.bgSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .strokeBorder(Color.brand.opacity(0.55), lineWidth: 1)
                )

            Button(action: { commitCustomNameEntry() }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(
                            customNameDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                                ? Color.brand.opacity(0.45)
                                : Color.brand
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                customNameDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
            .accessibilityLabel("Use this name")
        }
    }

    private func beginCustomNameEntry() {
        Haptics.tap()
        customNameDraft = ""
        isEnteringCustomName = true
        customNameFieldFocused = true
    }

    private func commitCustomNameEntry() {
        let trimmed = customNameDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customNameFieldFocused = false
        isEnteringCustomName = false
        commitNameCorrection(trimmed)
    }

    /// Shared commit path for both chip taps and custom-name entry.
    /// Records that the user has accepted a correction (hides the
    /// uncertainty UI for the rest of this session), then hands the
    /// name to the parent for re-analysis. The parent's view model
    /// is what stamps `editedFoodName` and re-runs `/analyze`.
    private func commitNameCorrection(_ name: String) {
        Haptics.soft()
        hasAcceptedNameCorrection = true
        onFoodNameCorrected?(name)
    }

    // MARK: - Your Pattern zone

    /// Standalone card that summarizes how this meal fits inside the
    /// user's history. NEVER claims to adjust Gemini — both the copy
    /// and the data model are insight-only. Hidden when the insight
    /// has no content (e.g. a brand-new food, or one that doesn't
    /// have enough priors to compare yet).
    @ViewBuilder
    private var yourPatternZone: some View {
        if let insight = patternInsight, insight.hasAnyContent {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                sectionEyebrow("Your Pattern")
                YourPatternCard(insight: insight)
            }
        }
    }

    // MARK: - Zone 2 — annotated hero photo

    /// Hero photo at the center of an editorial-infographic block. The
    /// photo renders at ~55% of the available width in a 4:5 portrait
    /// frame; six macro callouts sit in the ~22.5% gutters on each side
    /// (3 on left, 3 on right) connected to the photo's edge by dashed
    /// tethers ending in a small filled disc.
    ///
    /// Geometry is fully proportional off the container width, so the
    /// block scales cleanly across iPhone widths without hand-tuning.
    /// `GeometryReader` is wrapped in an outer container of exactly the
    /// same height as the photo, so the block participates in vertical
    /// flow rather than collapsing to zero / overlapping siblings.
    @ViewBuilder
    private var annotatedPhotoBlock: some View {
        // Layout constants. Photo is portrait (4:5) to give vertical
        // breathing room for the side callouts; the side gutters get
        // ~22.5% each, leaving 55% center for the photo.
        let photoAspectH: CGFloat = 1.25   // height = width * 1.25 (4:5)
        let photoFraction: CGFloat = 0.55
        let sideFraction: CGFloat = 0.225

        GeometryReader { geo in
            let totalWidth = geo.size.width
            let sideRegionWidth = totalWidth * sideFraction
            let photoWidth = totalWidth * photoFraction
            let photoHeight = photoWidth * photoAspectH
            let photoLeading = sideRegionWidth
            let photoTrailing = sideRegionWidth + photoWidth

            // Vertical anchor positions for the three rows of callouts,
            // expressed as fractions of photoHeight.
            let rowYs: [CGFloat] = [0.15, 0.50, 0.85]

            ZStack(alignment: .topLeading) {
                // --- Photo ---
                // `compositingGroup` + `drawingGroup` (in both branches)
                // rasterizes the clipped image + hairline border + card
                // shadow into a single GPU texture. Without this the shadow
                // recomputes on every scroll frame and the JPEG re-samples
                // through the rounded clip mask each pass — the prior
                // version's top jank source.
                //
                // Two structures, chosen by whether the morph is engaged for
                // this view. The fallback branch is byte-for-byte today's
                // tree (fixed frame + clip + shadow + `.offset`), so a
                // flag-off / Reduce-Motion render is unchanged.
                //
                // The morph branch decouples size from layout: a `Color.clear`
                // reserves the natural slot (photoWidth × photoHeight) while
                // the photo rides in an overlay carrying the matched-geometry
                // effect, so it can resize to the bubble during the morph (the
                // overlay overflows the slot) and animate back. It is also
                // positioned with `.padding(.leading)` rather than `.offset`:
                // matched geometry reads *layout* frames, so a render-only
                // `.offset` would mis-place the morph by `photoLeading`.
                if morphNamespace != nil {
                    Color.clear
                        .frame(width: photoWidth, height: photoHeight)
                        .overlay {
                            photoView
                                .clipShape(RoundedRectangle(cornerRadius: photoCornerRadius))
                                .overlay(
                                    RoundedRectangle(cornerRadius: photoCornerRadius)
                                        .strokeBorder(Color.borderHairline, lineWidth: 0.5)
                                )
                                .compositingGroup()
                                .appShadow(.shadowCard)
                                .drawingGroup(opaque: false)
                                .modifier(MealMorphMatch(
                                    namespace: morphNamespace,
                                    isSource: false
                                ))
                                .onAppear {
                                    guard !photoMorphSettled else { return }
                                    withAnimation(.appMorph) {
                                        photoMorphSettled = true
                                    }
                                }
                        }
                        .padding(.leading, photoLeading)
                } else {
                    photoView
                        .frame(width: photoWidth, height: photoHeight)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(Color.borderHairline, lineWidth: 0.5)
                        )
                        .compositingGroup()
                        .appShadow(.shadowCard)
                        .drawingGroup(opaque: false)
                        .offset(x: photoLeading, y: 0)
                }

                // --- Connector lines + endpoint discs ---
                // A single `Canvas` draws all 12 strokes / fills in one
                // GPU pass instead of 12 separate SwiftUI shape views.
                // The Canvas itself is wrapped in drawingGroup so the
                // result is cached as a texture across scroll frames.
                connectorLines(
                    photoLeading: photoLeading,
                    photoTrailing: photoTrailing,
                    photoHeight: photoHeight,
                    sideRegionWidth: sideRegionWidth,
                    rowYs: rowYs,
                    canvasSize: CGSize(width: totalWidth,
                                       height: photoHeight)
                )

                // --- Left callouts: CALORIES, CARBS, PROTEIN ---
                ForEach(Array(leftCallouts.enumerated()), id: \.offset) { idx, c in
                    calloutLabel(c, isLeftSide: true)
                        .frame(width: max(sideRegionWidth - 14, 0),
                               alignment: .trailing)
                        .offset(x: 0,
                                y: photoHeight * rowYs[idx] - calloutHalfHeight)
                }

                // --- Right callouts: SUGAR, FAT, FIBER ---
                ForEach(Array(rightCallouts.enumerated()), id: \.offset) { idx, c in
                    calloutLabel(c, isLeftSide: false)
                        .frame(width: max(sideRegionWidth - 14, 0),
                               alignment: .leading)
                        .offset(x: photoTrailing + 14,
                                y: photoHeight * rowYs[idx] - calloutHalfHeight)
                }
            }
            .frame(width: totalWidth, height: photoHeight, alignment: .topLeading)
        }
        // Reserve vertical space proportional to the parent width.
        // Without this, GeometryReader collapses and the block would
        // overlap neighbouring zones. Aspect = photoFraction * 1.25.
        .aspectRatio(1.0 / (photoFraction * photoAspectH), contentMode: .fit)
    }

    /// Approximate half-height of a callout's two-line text stack, used
    /// to vertically center the label on its row anchor. Empirically
    /// matches a 12pt eyebrow + 20pt value at default Dynamic Type — a
    /// pixel-perfect computation would require a measured geometry pass,
    /// which isn't worth the complexity for a decorative block.
    private var calloutHalfHeight: CGFloat { 22 }

    /// Photo content — prefers the downsampled bitmap cached on first
    /// appear so scrolling never re-decodes the full-resolution capture.
    /// Falls back to the source image until the downsample lands, then to
    /// a placeholder when nothing was passed in. `.interpolation(.medium)`
    /// keeps the resampling cost predictable; combined with the upstream
    /// `drawingGroup`, the photo renders once and then just translates
    /// during scroll.
    @ViewBuilder
    private var photoView: some View {
        ZStack {
            Rectangle()
                .fill(Color.bgSurfaceSoft)

            if let shown = displayImage ?? image {
                Image(uiImage: shown)
                    .resizable()
                    .interpolation(.medium)
                    .antialiased(true)
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.inkLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A single macro callout's data, used for left/right ForEach loops.
    private struct MacroCallout {
        let eyebrow: String
        let value: Double?
        let unit: String
    }

    private var leftCallouts: [MacroCallout] {
        [
            .init(eyebrow: "CALORIES", value: analysis.calories, unit: "kcal"),
            .init(eyebrow: "CARBS",    value: analysis.carbs,    unit: "g"),
            .init(eyebrow: "PROTEIN",  value: analysis.protein,  unit: "g"),
        ]
    }

    private var rightCallouts: [MacroCallout] {
        [
            .init(eyebrow: "SUGAR", value: analysis.sugar, unit: "g"),
            .init(eyebrow: "FAT",   value: analysis.fat,   unit: "g"),
            .init(eyebrow: "FIBER", value: analysis.fiber, unit: "g"),
        ]
    }

    /// Two-line label. Left-side labels flush right toward the photo;
    /// right-side labels flush left toward the photo. Missing macros
    /// render as an em-dash (Phase 21.9 contract) so the layout shape
    /// stays stable regardless of which fields came back.
    private func calloutLabel(_ c: MacroCallout,
                              isLeftSide: Bool) -> some View {
        let alignment: HorizontalAlignment = isLeftSide ? .trailing : .leading
        let baseline: HorizontalAlignment = isLeftSide ? .trailing : .leading

        return VStack(alignment: alignment, spacing: 2) {
            Text(c.eyebrow)
                .appFont(.labelEyebrow)
                .foregroundStyle(Color.brandDeep)
                .tracking(1.6)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let v = c.value, v.isFinite {
                    Text(formatMacro(v, isCalories: c.unit == "kcal"))
                        .appFont(.title2)
                        .foregroundStyle(Color.ink)
                } else {
                    Text("—")
                        .appFont(.title2)
                        .foregroundStyle(Color.inkLight)
                }
                Text(c.unit)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: baseline, vertical: .center))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            c.value.map { "\(c.eyebrow) \(Int($0.rounded())) \(c.unit)" }
                ?? "\(c.eyebrow) not available"
        )
    }

    /// Six dashed tethers + endpoint discs drawn into a single `Canvas`
    /// so the whole tether layer is one GPU pass — replaces the prior
    /// implementation that spawned 12 individual shape views (each with
    /// its own animation/layout participation). Combined with the outer
    /// `drawingGroup`, the layer rasterizes once and just translates
    /// during scroll, eliminating per-frame shape stroking.
    private func connectorLines(photoLeading: CGFloat,
                                photoTrailing: CGFloat,
                                photoHeight: CGFloat,
                                sideRegionWidth: CGFloat,
                                rowYs: [CGFloat],
                                canvasSize: CGSize) -> some View {
        let discRadius: CGFloat = 3
        let dashStyle = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3])
        // Snapshot Canvas-resolved color once; closure captures by value.
        let brand = Color.brand

        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            var tethers = Path()
            var discs = Path()
            for y0 in rowYs {
                let y = photoHeight * y0
                // Left tether.
                tethers.move(to: CGPoint(x: sideRegionWidth - 6, y: y))
                tethers.addLine(to: CGPoint(x: photoLeading + 4, y: y))
                discs.addEllipse(in: CGRect(
                    x: photoLeading + 4 - discRadius,
                    y: y - discRadius,
                    width: discRadius * 2,
                    height: discRadius * 2
                ))
                // Right tether.
                let rightEnd = photoTrailing + sideRegionWidth - 6
                tethers.move(to: CGPoint(x: photoTrailing - 4, y: y))
                tethers.addLine(to: CGPoint(x: rightEnd, y: y))
                discs.addEllipse(in: CGRect(
                    x: photoTrailing - 4 - discRadius,
                    y: y - discRadius,
                    width: discRadius * 2,
                    height: discRadius * 2
                ))
            }
            ctx.stroke(tethers, with: .color(brand), style: dashStyle)
            ctx.fill(discs, with: .color(brand))
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .drawingGroup(opaque: false)
        .allowsHitTesting(false)
    }

    /// Number formatter for callout values. Calories get an integer with
    /// a thousands separator ("1,050") at four-digit territory; macros
    /// render as integer when whole, one-decimal when fractional. Mirrors
    /// the formatting policy on the prior macro grid so saved totals
    /// elsewhere in the app read identically.
    private func formatMacro(_ value: Double, isCalories: Bool) -> String {
        if isCalories {
            if value >= 1000 {
                return NumberFormatter.localizedString(
                    from: NSNumber(value: Int(value.rounded())),
                    number: .decimal
                )
            }
            return "\(Int(value.rounded()))"
        }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    /// Displayed food name = correction (if any) → AI value → "Unknown".
    /// Drives both the read-only and the edit-mode renderings so the
    /// two paths can never disagree.
    private var displayedFoodName: String {
        if let override = foodNameOverride, !override.isEmpty {
            return override
        }
        return analysis.food ?? "Unknown"
    }

    /// Editable food name with a Duolingo-style morph between read and
    /// edit modes. The text itself stays at the *same* display2 weight
    /// (32pt, Nunito ExtraBold, kern -0.8) in both modes and wraps
    /// across as many lines as the name needs — what morphs is the
    /// brand-tinted card that materializes around the text. The field
    /// then grows and shrinks vertically with the typed content (no
    /// horizontal scroll, no truncation, no font-size jump).
    ///
    /// Animation: a single spring (response 0.45, dampingFraction 0.72)
    /// drives padding, background fill, and border opacity in unison so
    /// the box reads as "snapping into existence" around the text.
    /// Reduce Motion swaps to a flat 0.22s ease.
    ///
    /// Edits only surface when the parent supplied `onFoodNameEdited`.
    /// If a save-failed state renders without a callback wired, the
    /// name reads as static display.
    @ViewBuilder
    private var editableFoodName: some View {
        if onFoodNameEdited != nil {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                nameContainer

                if isEditingName {
                    editingActions
                        .transition(
                            .scale(scale: 0.92, anchor: .topLeading)
                                .combined(with: .opacity)
                        )
                } else {
                    editCTAButton
                        .transition(
                            .scale(scale: 0.92, anchor: .topLeading)
                                .combined(with: .opacity)
                        )
                }
            }
            .animation(morphSpring, value: isEditingName)
        } else {
            Text(displayedFoodName)
                .appFont(.display2)
                .foregroundStyle(Color.ink)
        }
    }

    /// Morph curve. Snappy spring (Duolingo principle: quick entry, a
    /// hair of overshoot, fast settle). The shorter response keeps
    /// the box from feeling like it's lagging behind the tap; the
    /// 0.78 damping limits overshoot to a single subtle pulse rather
    /// than a wobble. Reduce Motion swaps to a brief linear ease so
    /// the section never scales.
    private var morphSpring: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.36, dampingFraction: 0.78)
    }

    /// The text region. To keep the morph buttery-smooth we render a
    /// single persistent TextField across both modes — no `if/else`
    /// branch, no view-identity swap. The field is disabled in read
    /// mode (a clear overlay catches the tap-to-edit), enabled in
    /// edit mode. Same font + kerning + line wrapping in both states
    /// means the text never visibly moves.
    ///
    /// The morphing "card" is rendered as a `.background` with
    /// *negative* padding so it extends past the text bounds without
    /// affecting layout. Only opacity and a small scale (0.94 → 1.0)
    /// animate — both cheap GPU transforms, no layout recompute,
    /// 60fps even on long multi-line names. A `compositingGroup`
    /// flattens the fill + border + scale + opacity into a single
    /// render pass so the spring's overshoot doesn't show artifacts
    /// between layers.
    ///
    /// `TextField(axis: .vertical) + lineLimit(1...12)` lets the box
    /// grow and shrink with what the user types — add a line and the
    /// box tracks; delete back to a short name and it tightens.
    private var nameContainer: some View {
        TextField("Food name",
                  text: $editedNameDraft,
                  axis: .vertical)
            .font(AppFont.font(.display2))
            .kerning(-0.8)
            .foregroundStyle(Color.ink)
            .tint(Color.brand)
            .textFieldStyle(.plain)
            .lineLimit(1...12)
            .multilineTextAlignment(.leading)
            .submitLabel(.done)
            .autocorrectionDisabled(false)
            .textInputAutocapitalization(.sentences)
            .focused($foodNameFieldFocused)
            .disabled(!isEditingName)
            // Return-to-commit. Vertical-axis TextField defaults to
            // newline-on-return; catch the newline, strip it, route
            // through commit so Done matches the Save button.
            .onChange(of: editedNameDraft) { _, newValue in
                guard isEditingName else { return }
                if newValue.contains("\n") {
                    editedNameDraft = newValue
                        .replacingOccurrences(of: "\n", with: "")
                    commitFoodNameEdit()
                }
            }
            // Keep the field's text mirrored to the displayed name
            // while not editing, so the AI's value (or a prior
            // committed override) reads through identically.
            .onAppear { syncDraftIfIdle() }
            .onChange(of: foodNameOverride ?? "") { _, _ in syncDraftIfIdle() }
            .onChange(of: analysis.food ?? "") { _, _ in syncDraftIfIdle() }
            // Focus loss while still in edit mode = the user did
            // something outside the field (tap on whitespace, scroll
            // the keyboard down interactively, system dismissal).
            // Commit the edit — preserves what they typed instead of
            // losing it. Save/Cancel paths flip `isEditingName` first
            // so this branch is skipped for explicit button presses.
            .onChange(of: foodNameFieldFocused) { _, focused in
                if !focused, isEditingName {
                    commitFoodNameEdit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Morph box: extends past the text via negative
                // padding so it can fade in around the text without
                // shifting layout. Only opacity + scale animate.
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.brandSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(Color.brand.opacity(0.55),
                                          lineWidth: 1.5)
                    )
                    .padding(.horizontal, -AppSpacing.md)
                    .padding(.vertical, -AppSpacing.sm)
                    .compositingGroup()
                    .opacity(isEditingName ? 1 : 0)
                    .scaleEffect(isEditingName ? 1 : 0.94,
                                 anchor: .center)
            }
            .overlay {
                // Read-mode tap target. A disabled TextField won't
                // forward touches, so a clear overlay above it
                // catches the tap and routes to begin-edit. Removed
                // entirely in edit mode so the TextField gets the
                // touches it needs (cursor placement, selection).
                if !isEditingName {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { beginFoodNameEdit() }
                        .accessibilityLabel(
                            "Food name: \(displayedFoodName). Double-tap to edit."
                        )
                }
            }
    }

    /// While the user isn't actively editing, keep the field's bound
    /// text matched to the canonical displayed name. Prevents drift
    /// when the parent pushes a new `foodNameOverride` or the analysis
    /// reloads with a different `food`.
    private func syncDraftIfIdle() {
        if !isEditingName {
            editedNameDraft = displayedFoodName
        }
    }

    /// Read-mode CTA pill. Brand-tinted fill + outline + bold pencil
    /// glyph + "Edit name" copy — much more visible than the prior
    /// 14pt inline pencil. A small bounce nudge on first reveal draws
    /// the eye without becoming a constant distraction.
    private var editCTAButton: some View {
        Button(action: { beginFoodNameEdit() }) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .bold))
                    .symbolEffect(.bounce, value: ctaNudge)
                Text("Edit name")
                    .appFont(.captionStrong)
            }
            .foregroundStyle(Color.brandDeep)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.brandSoft)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.brand.opacity(0.65), lineWidth: 1.5)
            )
            .scaleEffect(ctaPressScale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit food name")
        .accessibilityHint("If the AI got the name wrong, fix it here.")
        .onAppear {
            // One-shot attention nudge after the cascade reveal: bounce
            // the pencil glyph once so testers see the affordance even
            // if they aren't scanning for it. Idempotent — the next
            // re-render keeps ctaNudge at 1 and won't replay.
            guard ctaNudge == 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                ctaNudge = 1
            }
        }
    }

    /// Edit-mode actions: Save (filled brand pill) + Cancel (ghost).
    /// Save mirrors the typewriter cascade's brand palette so the
    /// editing region reads as part of the same screen, not a system
    /// alert. Cancel disabled-on-empty matches the "empty = silent
    /// revert" contract from `commitFoodNameEdit`.
    private var editingActions: some View {
        let trimmed = editedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSave = !trimmed.isEmpty
        return HStack(spacing: AppSpacing.sm) {
            Button(action: { commitFoodNameEdit() }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                    Text("Save")
                        .appFont(.captionStrong)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(canSave ? Color.brand : Color.brand.opacity(0.45))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityLabel("Save food name")

            Button(action: { cancelFoodNameEdit() }) {
                Text("Cancel")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.inkMute)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.bgSurface))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel name edit")

            Spacer(minLength: 0)
        }
    }

    private func beginFoodNameEdit() {
        Haptics.tap()
        editedNameDraft = displayedFoodName
        // Focus first, flip state second — both land in the same
        // SwiftUI transaction so the morph and keyboard kick off
        // together rather than the morph waiting on a deferred
        // focus. Since the box morph is now pure opacity/scale (no
        // layout work), there's nothing for the keyboard to fight.
        foodNameFieldFocused = true
        isEditingName = true
    }

    private func commitFoodNameEdit() {
        let trimmed = editedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Order matters: flip `isEditingName` BEFORE clearing focus so
        // the `onChange(of: foodNameFieldFocused)` watcher (used to
        // catch tap-outside / scroll-to-dismiss) sees an already-false
        // edit state and skips its own commit. Otherwise commit would
        // fire twice — fine because it's idempotent, but noisy.
        isEditingName = false
        foodNameFieldFocused = false
        // Empty / unchanged submission = silent revert. No-op for parent.
        guard !trimmed.isEmpty, trimmed != displayedFoodName else { return }
        Haptics.soft()
        onFoodNameEdited?(trimmed)
    }

    private func cancelFoodNameEdit() {
        Haptics.tap()
        // Same ordering rationale as `commitFoodNameEdit`: clear edit
        // state first so the focus watcher doesn't reinterpret the
        // dismissal as a tap-outside commit.
        isEditingName = false
        foodNameFieldFocused = false
        // Restore the draft to the canonical name so a subsequent
        // re-open doesn't show stale typing from this aborted edit.
        editedNameDraft = displayedFoodName
    }

    /// Phase 15 — quiet "you've had this before" chip. Hidden until the
    /// query returns AND there's at least one prior. No "first time"
    /// branch — novelty messaging belongs to the Today → Patterns
    /// section, not here.
    @ViewBuilder
    private var repeatChip: some View {
        if let count = priorCount, count >= 1 {
            RepeatChip(
                text: repeatChipText(
                    count: count,
                    lastSeen: lastPriorDate,
                    daypart: timeOfDayCluster
                )
            )
        }
    }

    /// Tiered, deterministic copy. Tone scales with frequency, and a
    /// dominant time-of-day cluster (when 2+ priors share a daypart)
    /// adds a "around dinner" / "in the morning" tail to the 2–3 and 4+
    /// branches. Last-time suffix is dropped when the date hasn't
    /// loaded yet.
    ///
    /// Examples:
    ///   1            → "A familiar one — you logged this yesterday."
    ///   2–3, cluster → "You've had this 3 times — usually around dinner."
    ///   2–3, no cl.  → "You've had this 3 times. Last time: Monday."
    ///   4+, cluster  → "One of your regulars — usually around dinner."
    ///   4+, no cl.   → "One of your regulars — 5 logs so far."
    private func repeatChipText(count: Int,
                                lastSeen: Date?,
                                daypart: String?) -> String {
        if count >= 4 {
            if let daypart {
                return "One of your regulars — usually \(daypart)."
            }
            return "One of your regulars — \(count) logs so far."
        }
        if count == 1 {
            let head = "A familiar one — you logged this once before."
            guard let lastSeen else { return head }
            return "A familiar one — you logged this \(lastTimeLabel(lastSeen))."
        }
        if let daypart {
            return "You've had this \(count) times — usually \(daypart)."
        }
        let head = "You've had this \(count) times."
        guard let lastSeen else { return head }
        return "\(head) Last time: \(lastTimeLabel(lastSeen))."
    }

    /// Pure helper. Returns a daypart label ("in the morning", "around
    /// lunch", "around dinner", "late at night") iff 2+ of the supplied
    /// dates fall in the same 4-hour bucket. Buckets are conservative —
    /// a "lunch" cluster with one stray breakfast won't tip it the wrong
    /// way. Returns nil when there's no clear cluster so the chip copy
    /// stays honest.
    static func dominantDaypart(in dates: [Date],
                                calendar: Calendar = .current) -> String? {
        guard dates.count >= 2 else { return nil }
        var hist: [String: Int] = [:]
        for date in dates {
            let hour = calendar.component(.hour, from: date)
            let bucket: String
            switch hour {
            case 5..<11:   bucket = "in the morning"
            case 11..<14:  bucket = "around lunch"
            case 14..<17:  bucket = "in the afternoon"
            case 17..<21:  bucket = "around dinner"
            default:       bucket = "late at night"
            }
            hist[bucket, default: 0] += 1
        }
        guard let (label, count) = hist.max(by: { $0.value < $1.value }),
              count >= 2,
              // Dominance: cluster must hold at least 60% of priors to
              // count, so 4 priors split 2/2 across buckets stays silent.
              Double(count) / Double(dates.count) >= 0.6
        else { return nil }
        return label
    }

    /// "Today" / "Yesterday" / weekday name within the last week, then
    /// "Mar 14" beyond that. Mirrors the conversational tone of the
    /// chip itself.
    ///
    /// The two formatters are cached statically because `DateFormatter`
    /// allocation/parse is expensive (CFCalendar + ICU bootstrap) and
    /// this helper runs every time the result view re-renders.
    private func lastTimeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }

        if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()),
           date >= weekAgo {
            return Self.weekdayFormatter.string(from: date)
        }
        return Self.shortDateFormatter.string(from: date)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Day-aware impact line

    /// Goal-anchored standing block under the hero macros — the first beat
    /// of the "Strava for food" loop. Folds the just-analyzed meal's
    /// calories into the pre-scan day total to show, in real numbers, where
    /// saving this meal leaves you against today's goal: how much room is
    /// left, or — if it tips you over (and your goal is to lose/maintain) —
    /// a doable "earn it back" move estimated from your own weight. Hidden
    /// only when there's no usable pre-scan goal or no meal calories.
    @ViewBuilder
    private var goalStandingBlock: some View {
        if let status = dailyStatus, status.hasValidGoal,
           let cals = analysis.calories, cals.isFinite, cals >= 0 {
            let predicted = DailyCalorieGoalStatus.compute(
                consumed: status.consumed + cals,
                goal: status.goal
            )
            let isGain = goalDirection == .gain
            let over = predicted.exceededBy
            let showBurnOff = over > 0 && !isGain

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: showBurnOff
                          ? "exclamationmark.circle.fill" : "target")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(showBurnOff ? Color.error : Color.brandDeep)
                    Text(goalStandingText(predicted: predicted, isGain: isGain))
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showBurnOff {
                    let walk = ActivityBurnEstimator.walkMinutes(
                        toBurn: over, weightKg: bodyWeightKg)
                    let jog = ActivityBurnEstimator.jogMinutes(
                        toBurn: over, weightKg: bodyWeightKg)
                    HStack(spacing: 8) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.brandDeep)
                        Text("A \(walk)-min walk or \(jog)-min jog evens it out.")
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let eatLine = MealSuggestionEngine.compactLine(
                            remaining: predicted.remaining) {
                    // Inverse of the burn-off line: still under goal → a calm,
                    // one-line "what fits" nudge. The headline already shows
                    // the number, so this is just the size of meal that fits.
                    HStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.brandDeep)
                        Text(eatLine)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurfaceSoft)
            )
        }
    }

    /// Friendly, non-shaming standing line for the predicted post-save day.
    /// Numbers are rounded to the nearest 5 kcal for a calmer read.
    private func goalStandingText(predicted: DailyCalorieGoalStatus,
                                  isGain: Bool) -> String {
        let over = roundedCalories(predicted.exceededBy)
        let remaining = roundedCalories(predicted.remaining)
        if isGain {
            if predicted.exceededBy > 0 {
                return "Over maintenance — fuel for building."
            }
            return "\(remaining) kcal to go toward today's goal."
        }
        if predicted.exceededBy > 0 {
            return "\(over) kcal over today's goal."
        }
        if predicted.remaining <= 0 {
            return "Right at today's goal."
        }
        return "\(remaining) kcal left today after this."
    }

    /// Rounds a calorie figure to the nearest 5 for a calmer, less
    /// false-precise number.
    private func roundedCalories(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value / 5).rounded() * 5)
    }

    // MARK: - Zone 5 — insights helper

    /// True when at least one accordion has content. Drives whether the
    /// "Insights" section eyebrow renders at all — an empty section with
    /// only a kicker reads as a layout glitch.
    private var hasAnyInsights: Bool {
        !(analysis.nutrients ?? []).isEmpty
            || !(analysis.benefits  ?? []).isEmpty
            || !(analysis.drawbacks ?? []).isEmpty
    }

    // MARK: - Coach reaction bubble

    /// Tiny deterministic coach reaction that sits below the editorial
    /// quote — a quick second-beat reaction so the coach reads as a
    /// character, not just a one-line quote source. Pure-local copy
    /// keyed off the coach name + analysis state (no network call,
    /// no new model fields). Hidden when there's no coach.
    @ViewBuilder
    private var coachReactionBubble: some View {
        if let coach = response.coach, !coach.isEmpty {
            CoachReactionBubble(coach: coach, analysis: analysis)
        }
    }

    // MARK: - Editorial quote

    @ViewBuilder
    private var quoteBlock: some View {
        if let advice = analysis.coachAdvice, !advice.isEmpty {
            EditorialQuote(
                text: advice,
                attribution: response.coach,
                typewriter: true,
                startDelay: revealDelay + 0.4
            )
        }
    }

    // MARK: - Three category accordions
    //
    // Phase 14 typewriter restore: on first reveal, all three accordions
    // auto-expand and immediately start typing in parallel with a small
    // stagger so they don't all begin in the exact same frame. The page
    // reads as the AI filling in the entire analysis live, all at once.
    // Stagger budget (seconds, all relative to view appear):
    //   quote      : 0.4   (fires just after photo + hero land)
    //   nutrients  : 0.5
    //   benefits   : 0.7
    //   drawbacks  : 0.9
    // After typing completes the controllers go idle; collapsing/re-
    // expanding an accordion renders instantly because `didStart` latches.

    @ViewBuilder
    private var accordions: some View {
        let nutrients = analysis.nutrients ?? []
        let benefits  = analysis.benefits  ?? []
        let drawbacks = analysis.drawbacks ?? []

        VStack(spacing: AppSpacing.sm) {
            if !nutrients.isEmpty {
                CategoryAccordion(
                    kind: .nutrients,
                    title: "Nutrients",
                    items: nutrients,
                    startsExpanded: true,
                    typewriter: true,
                    startDelay: revealDelay + 0.5
                )
            }
            if !benefits.isEmpty {
                CategoryAccordion(
                    kind: .benefits,
                    title: "Benefits",
                    items: benefits,
                    startsExpanded: true,
                    typewriter: true,
                    startDelay: revealDelay + 0.7
                )
            }
            if !drawbacks.isEmpty {
                CategoryAccordion(
                    kind: .drawbacks,
                    title: "Drawbacks",
                    items: drawbacks,
                    startsExpanded: true,
                    typewriter: true,
                    startDelay: revealDelay + 0.9
                )
            }
        }
    }

    // MARK: - Save / discard

    private var saveBlock: some View {
        VStack(spacing: AppSpacing.md) {
            SaveRewardPill(phase: saveRewardPhase)
            PrimaryButton(
                title: isSaving ? "Saving…" : "Save to today",
                leadingSystemImage: isSaving ? nil : "checkmark.circle.fill",
                isLoading: isSaving,
                action: onSave
            )
            Button {
                Haptics.tap()
                onCancel()
            } label: {
                Text("Discard")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.inkMute)
                    .underline()
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .opacity(isSaving ? 0.4 : 1)
        }
        .padding(.top, AppSpacing.md)
    }
}

// MARK: - Save reward pill

/// Inline reward pill above the PrimaryButton. Visibility and copy are
/// keyed off `SaveRewardPhase` so the pill cannot claim success before
/// the meal actually lands:
///   - `.idle`   → hidden (covers `.ready` and `.saveFailed`)
///   - `.saving` → "Adding to today…", subtle progress dot, no stamp
///   - `.saved`  → "Added to today", checkmark stamps in + brand glow
///
/// Polish elements (saved only):
///   - checkmark glyph scale-stamps from 0.6 → 1.0
///   - one-shot brand glow expanding behind the checkmark
///   - soft success haptic when the phase transitions saving→saved so
///     the tactile beat lands with the visual
///
/// Reduce Motion path: opacity-only fade, no overshoot, no glow pulse.
/// No retained Tasks — animation is purely state-driven via
/// `.onChange(of: phase)`, so there's nothing to cancel on disappear.
private struct SaveRewardPill: View {
    let phase: SaveRewardPhase

    @State private var stamped: Bool = false
    @State private var glow: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        phase != .idle
    }

    private var isSaved: Bool {
        phase == .saved
    }

    private var copyText: String {
        switch phase {
        case .idle, .saving: return "Adding to today…"
        case .saved:         return "Added to today"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // Brand glow halo: only kicks in for `.saved`; while
                // `.saving` it stays at rest behind the icon and is
                // invisible (`glow` only animates after a saved
                // transition).
                Circle()
                    .fill(Color.brand.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .scaleEffect(glow ? 1.5 : 0.6)
                    .opacity(glow ? 0 : (isSaved ? 0.6 : 0))

                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.brandDeep)
                        .scaleEffect(stamped ? 1 : 0.6)
                        .transition(.opacity)
                } else {
                    // Saving: a quiet progress indicator. The dot
                    // gently pulses (handled by SwiftUI default
                    // ProgressView animation), no overshoot.
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.brandDeep)
                        .transition(.opacity)
                }
            }
            Text(copyText)
                .appFont(.captionStrong)
                .foregroundStyle(Color.ink)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.brandSoft)
        )
        .overlay(
            Capsule().strokeBorder(Color.brand.opacity(0.45), lineWidth: 1)
        )
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.94)
        .animation(
            reduceMotion ? .appReduced : .motionReveal,
            value: isVisible
        )
        .animation(
            reduceMotion ? .appReduced : .motionBase,
            value: isSaved
        )
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .idle:
                stamped = false
                glow = false
            case .saving:
                // Reset stamp state in case we're transitioning
                // failed→retry→saving and the previous stamp was up.
                stamped = false
                glow = false
            case .saved:
                runStamp()
            }
        }
        .accessibilityHidden(!isVisible)
        .accessibilityLabel(copyText)
    }

    private func runStamp() {
        if reduceMotion {
            stamped = true
            return
        }
        withAnimation(.appStamp) { stamped = true }
        withAnimation(.easeOut(duration: 0.55)) { glow = true }
        // Tactile beat aligned with the visual stamp. `SavedConfirmationSheet`
        // still owns the larger `Haptics.success()` when its checkmark
        // lands — this `.soft` is the smaller pre-beat so the inline
        // pill doesn't change phases silently.
        Haptics.soft()
    }
}

// MARK: - Repeat chip

/// Small inline "you've had this before" chip with a subtle reveal:
/// fades in and lifts a few points on first appearance, then settles.
/// Reduce Motion drops the lift to a flat opacity fade. The chip itself
/// is keyed by its text so a count change (very rare during a single
/// view lifetime) replays the reveal cleanly rather than snapping.
private struct RepeatChip: View {
    let text: String
    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .appFont(.captionStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.inkMute)
        .padding(.top, 2)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 4)
        .onAppear {
            guard !revealed else { return }
            let anim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(anim.delay(0.45)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Your Pattern card

/// Multi-line card surfacing local pattern insights — never an
/// adjusted estimate. Each row is a bullet-style line describing how
/// this meal compares to the user's history; the underlying
/// `FoodPatternInsight` decides which lines exist. Card hides itself
/// entirely when no insight can be drawn (`hasAnyContent == false`),
/// so a first-time food never sees an empty stub.
///
/// Visual register: a soft brand-tinted card with a hairline border
/// and the "Your Pattern" section eyebrow rendered by the parent
/// (Zone 4b in `AnalysisResultView`). The card body owns:
///   - header row: similar-meal count + confidence dot
///   - bullet rows: user-average / typical-meal / repeated / mood
///
/// Tap target is non-interactive on purpose — pattern is enrichment;
/// it doesn't gate any new flow.
private struct YourPatternCard: View {
    let insight: FoodPatternInsight

    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var confidenceLabel: String { insight.confidence.label }

    /// Tone the confidence dot to match the label so the card stays
    /// honest about how much weight the user should place on it.
    private var confidenceDotColor: Color {
        switch insight.confidence {
        case .low:    return Color.inkLight
        case .medium: return Color.brand
        case .high:   return Color.brandDeep
        }
    }

    /// Mirror copy used by the header — pluralizes correctly for
    /// 1 vs. N priors. `similarMealCount` already excludes the
    /// current scan (we count before save).
    private var headerCopy: String {
        let n = insight.similarMealCount
        if n <= 1 { return "1 similar meal so far" }
        return "\(n) similar meals so far"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            header
            bulletLines
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.35), lineWidth: 1)
        )
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 6)
        .onAppear {
            guard !revealed else { return }
            let anim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(anim.delay(0.5)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCopy)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 12, weight: .bold))
            Text(headerCopy)
                .appFont(.captionStrong)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Circle()
                    .fill(confidenceDotColor)
                    .frame(width: 6, height: 6)
                Text(confidenceLabel)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .foregroundStyle(Color.brandDeep)
    }

    @ViewBuilder
    private var bulletLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = insight.comparisonToUserAverage?.copy {
                bullet(line)
            }
            if let line = insight.comparisonToTypicalMeal?.copy {
                bullet(line)
            }
            if let line = insight.repeatedFoodNote {
                bullet(line)
            }
            if let line = insight.moodNote {
                bullet(line)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.brand)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(text)
                .appFont(.caption)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    private var accessibilityCopy: String {
        var parts: [String] = ["Your pattern card, \(confidenceLabel) confidence", headerCopy]
        if let s = insight.comparisonToUserAverage?.copy { parts.append(s) }
        if let s = insight.comparisonToTypicalMeal?.copy { parts.append(s) }
        if let s = insight.repeatedFoodNote { parts.append(s) }
        if let s = insight.moodNote { parts.append(s) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Coach reaction bubble

/// Small inline reaction line under the editorial quote. Deterministic
/// off the coach name + analysis state — no per-render randomness, no
/// network, no new model field. Animation is opacity + a few points of
/// upward drift; Reduce Motion drops the drift.
private struct CoachReactionBubble: View {
    let coach: String
    let analysis: GeminiAnalysis

    @State private var revealed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Match coach name into a small set of known characters. The
    /// server is free to send any string here; everything that doesn't
    /// match falls through to the neutral default.
    private enum Persona {
        case einstein, cleopatra, shakespeare, neutral
    }

    private var persona: Persona {
        let normalized = coach.lowercased()
        if normalized.contains("einstein") { return .einstein }
        if normalized.contains("cleopatra") { return .cleopatra }
        if normalized.contains("shakespeare") { return .shakespeare }
        return .neutral
    }

    /// One sentence, deterministic. Persona drives the voice; the
    /// "indulgent" branch only kicks in when there's something to
    /// note (>= 600 kcal or sugar > 25g), so light meals get the
    /// calmer line instead of an unearned warning.
    private var reactionText: String {
        let heavy = (analysis.calories ?? 0) >= 600
            || (analysis.sugar ?? 0) > 25
        switch persona {
        case .einstein:
            return heavy
                ? "Relatively rich — but the numbers still matter."
                : "Relatively reasonable — but the numbers still matter."
        case .cleopatra:
            return heavy
                ? "A royal feast. Keep your balance."
                : "A royal choice. Keep your balance."
        case .shakespeare:
            return heavy
                ? "A bold plate — moderation enters stage left."
                : "A worthy plate, though moderation enters stage left."
        case .neutral:
            return "Nice log. Here's what this means for your day."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
                .padding(.top, 2)
            Text(reactionText)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft)
        )
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 6)
        .onAppear {
            guard !revealed else { return }
            let anim: Animation = reduceMotion ? .appReduced : .motionReveal
            withAnimation(anim.delay(0.6)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(coach) reaction: \(reactionText)")
    }
}

/// Minimal flow layout for the uncertainty-aware name suggestion chips.
/// SwiftUI's HStack would clip on iPhone widths when alternatives are
/// long ("Ppyeo-haejangguk (pork bone soup)"); this wraps onto a second
/// row instead. iOS 17+ `Layout` protocol — no third-party dep.
fileprivate struct NameSuggestionFlow: Layout {
    var spacing: CGFloat = 8
    var runSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            let wouldFit = (rowWidth == 0)
                || (rowWidth + spacing + size.width <= maxWidth)
            if wouldFit {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            } else {
                totalHeight += rowHeight + runSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : totalWidth,
            height: totalHeight
        )
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview("AnalysisResultView — full") {
    let sample = AnalyzeResponse(
        analysis: GeminiAnalysis(
            fallback: nil,
            food: "Margherita Pizza",
            calories: 285,
            carbs: 35,
            sugar: 4,
            protein: 12,
            fat: 14,
            fiber: 3,
            benefits: [
                "Provides calcium for bone health",
                "Contains lycopene from tomato sauce",
                "Source of protein from cheese"
            ],
            drawbacks: [
                "High in refined carbs",
                "Sodium content can be elevated",
                "Consider whole-grain crust"
            ],
            nutrients: [
                "Calcium: bone health",
                "Lycopene: antioxidant",
                "Protein: muscle synthesis"
            ],
            coachAdvice: "E = mc²… and a slice of pizza ≈ 285 kcal. Pace thyself.",
            portionAmbiguousItems: nil,
            nameConfidence: nil,
            nameAlternatives: nil
        ),
        coach: "Albert Einstein"
    )
    return ScrollView {
        AnalysisResultView(
            image: nil,
            response: sample,
            onSave: { print("save tapped") },
            onCancel: { print("cancel tapped") }
        )
        .padding(.horizontal, AppSpacing.lg)
    }
    .background(Color.bgCanvas)
}
#endif
