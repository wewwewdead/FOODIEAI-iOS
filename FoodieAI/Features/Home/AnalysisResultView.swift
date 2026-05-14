import SwiftUI
import UIKit

/// Phase 14 redesign — magazine-style result page.
///
/// Layout matches mockup-2-result.svg:
///   1. ANALYSIS eyebrow centered (back chevron is provided by the
///      surrounding nav, not rendered here)
///   2. Photo card 4:3, radius-xl, shadow-card, with a bottom gradient
///      overlay so the floating CoachBadge stays readable
///   3. CoachBadge floating bottom-leading on the photo
///   4. DETECTED eyebrow (brand) + food name in display2
///   5. CALORIES eyebrow + HeroNumber 88pt + small ring (% of daily goal)
///   6. MacroChip row: 3 chips visible + "+N more" tap-to-expand
///   7. EditorialQuote for the coach advice
///   8. Three CategoryAccordions for nutrients/benefits/drawbacks.
///      Nutrients auto-expands on first appear after 0.5s for a moment
///      of visual interest; the other two stay collapsed by default.
///   9. PrimaryButton "Save to today" + Discard link, in-flow at the
///      bottom (not pinned at the screen edge — this view is hosted in
///      a ScrollView).
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
    /// Daily calorie goal used by the small progress arc next to the
    /// hero number. Defaults to 2,000 — Tier 4 can wire this through to
    /// the Profile model if desired.
    var dailyCalorieGoal: Double = 2_000
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var showingAllMacros: Bool = false
    /// Cascade reveal — set true on appear so the detected title and
    /// macro chips fade up in sequence after the photo card lands. Driven
    /// by a single state flag (not a per-element Task) so SwiftUI handles
    /// the timeline via per-modifier `.delay()`; nothing to cancel.
    @State private var cascadeOn: Bool = false
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

    private var analysis: GeminiAnalysis { response.analysis }

    /// Six possible macros — the first three (carbs/sugar/protein) are
    /// always shown; protein/fat/fiber move into the "+N more" expansion
    /// only when present.
    private var visibleMacros: [(label: String, value: Double, unit: String)] {
        var ms: [(String, Double, String)] = []
        ms.append(("CARBS",   analysis.carbs ?? 0, "g"))
        ms.append(("SUGAR",   analysis.sugar ?? 0, "g"))
        if let p = analysis.protein { ms.append(("PROTEIN", p, "g")) }
        return ms
    }

    private var hiddenMacros: [(label: String, value: Double, unit: String)] {
        var ms: [(String, Double, String)] = []
        if let f = analysis.fat   { ms.append(("FAT",   f, "g")) }
        if let f = analysis.fiber { ms.append(("FIBER", f, "g")) }
        return ms
    }

    /// Stable scroll target id used by `CaptureView`'s `ScrollViewReader`
    /// to focus the typewriter cascade once analyze succeeds. Always
    /// present in the view tree even when there's no coach advice, so
    /// scroll-to-anchor never misses.
    static let cascadeAnchorID = "analysisCascadeAnchor"

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            eyebrowHeader
            photoCard
            detectedBlock
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 10)
                .animation(cascadeAnim(delay: 0.15), value: cascadeOn)
            heroBlock
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 10)
                .animation(cascadeAnim(delay: 0.25), value: cascadeOn)
            macroChipsRow
                .opacity(cascadeOn ? 1 : 0)
                .offset(y: cascadeOn ? 0 : 8)
                .animation(cascadeAnim(delay: 0.35), value: cascadeOn)

            // Scroll anchor: CaptureView scrolls to this point when the
            // /analyze request returns, so the typewriter cascade fills
            // the viewport while the user reads it.
            Color.clear
                .frame(height: 0)
                .id(Self.cascadeAnchorID)

            quoteBlock
            coachReactionBubble
            accordions
            saveBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Idempotent: only flips on once, so re-renders (e.g. the
            // typewriter ticking) don't re-fire the cascade.
            guard !cascadeOn else { return }
            cascadeOn = true
        }
        .task(id: analysis.food ?? "") {
            await loadPriorOccurrences()
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

    // MARK: - Eyebrow header

    private var eyebrowHeader: some View {
        Text("Analysis").eyebrow()
            .foregroundStyle(Color.inkMute)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, AppSpacing.sm)
    }

    // MARK: - Photo card

    @ViewBuilder
    private var photoCard: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.bgSurfaceSoft)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // Image-shaped placeholder — happens when the parent
                // doesn't have the source image (e.g., reopening from
                // a saved meal). Subtle, doesn't apologize.
                Image(systemName: "photo")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(Color.inkLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Bottom-edge gradient so the floating badge stays readable
            // when the photo's bottom is bright. Lifted from the mockup
            // (mockup-2-result.svg #photoOverlay).
            LinearGradient(
                colors: [
                    Color.ink.opacity(0),
                    Color.ink.opacity(0.45)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Floating coach badge
            if let coach = response.coach, !coach.isEmpty {
                CoachBadge(name: coach)
                    .padding(AppSpacing.md)
            }
        }
        .aspectRatio(4/3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        .appShadow(.shadowCard)
    }

    // MARK: - Detected block

    private var detectedBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Detected").eyebrow()
                .foregroundStyle(Color.brand)
            Text(analysis.food ?? "Unknown")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
            repeatChip
        }
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

    // MARK: - Hero number + small progress arc

    private var heroBlock: some View {
        let calories = analysis.calories ?? 0
        let pct = dailyCalorieGoal > 0
            ? min(max(calories / dailyCalorieGoal, 0), 1)
            : 0

        return HStack(alignment: .center, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Calories").eyebrow()
                    .foregroundStyle(Color.inkMute)
                HeroNumber.RawDigits(value: calories)
            }
            Spacer(minLength: 0)
            DailyGoalArc(percentage: pct)
        }
    }

    // MARK: - Macro chips row

    @ViewBuilder
    private var macroChipsRow: some View {
        let allHiddenCount = hiddenMacros.count

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(visibleMacros, id: \.label) { m in
                    MacroChip(label: m.label, value: m.value, unit: m.unit)
                }
                if showingAllMacros {
                    ForEach(hiddenMacros, id: \.label) { m in
                        MacroChip(label: m.label, value: m.value, unit: m.unit)
                    }
                } else if allHiddenCount > 0 {
                    Button {
                        Haptics.tap()
                        withAnimation(.motionReveal) {
                            showingAllMacros = true
                        }
                    } label: {
                        MacroChip.more(count: allHiddenCount)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
                startDelay: 0.4
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
                    startDelay: 0.5
                )
            }
            if !benefits.isEmpty {
                CategoryAccordion(
                    kind: .benefits,
                    title: "Benefits",
                    items: benefits,
                    startsExpanded: true,
                    typewriter: true,
                    startDelay: 0.7
                )
            }
            if !drawbacks.isEmpty {
                CategoryAccordion(
                    kind: .drawbacks,
                    title: "Drawbacks",
                    items: drawbacks,
                    startsExpanded: true,
                    typewriter: true,
                    startDelay: 0.9
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

// MARK: - Hero raw-digits sub-view

extension HeroNumber {
    /// Inline raw-digit treatment for places where the parent already
    /// provides the eyebrow label (e.g., `AnalysisResultView.heroBlock`
    /// where the eyebrow leads the row before the number itself).
    /// Renders the 88pt M PLUS Black number with -3 kerning, count-up,
    /// `.motionHero` animation. No surrounding label or unit text.
    struct RawDigits: View {
        let value: Double
        @State private var displayed: Double = 0
        @State private var didAppear: Bool = false

        var body: some View {
            Text("\(Int(displayed.rounded()))")
                .monospacedDigit()
                .font(.custom(AppFont.PS.mplusBlack, size: 88))
                .kerning(-3)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: displayed))
                .onAppear {
                    guard !didAppear else { return }
                    didAppear = true
                    withAnimation(.motionHero) {
                        displayed = value
                    }
                }
                .onChange(of: value) { _, newValue in
                    withAnimation(.motionBase) {
                        displayed = newValue
                    }
                }
                .accessibilityLabel("\(Int(value.rounded())) calories")
        }
    }
}

// MARK: - Daily-goal arc

/// Small ring next to the hero number — shows the percentage of the
/// daily calorie goal this meal contributes. 68×68 outer, 6pt stroke.
/// Background hairline + brand-tinted progress arc with `.round` ends.
private struct DailyGoalArc: View {
    let percentage: Double

    @State private var arc: Double = 0

    private var pctLabel: String {
        "\(Int(round(percentage * 100)))%"
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let lineWidth: CGFloat = 6
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = (min(size.width, size.height) - lineWidth) / 2

                var bg = Path()
                bg.addArc(center: center, radius: radius,
                          startAngle: .degrees(0), endAngle: .degrees(360),
                          clockwise: false)
                context.stroke(
                    bg, with: .color(.borderHairline),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

                guard arc > 0 else { return }
                var fg = Path()
                fg.addArc(center: center, radius: radius,
                          startAngle: .degrees(-90),
                          endAngle: .degrees(-90 + 360 * arc),
                          clockwise: false)
                context.stroke(
                    fg, with: .color(.brand),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }

            VStack(spacing: 0) {
                Text(pctLabel)
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
                Text("of goal")
                    .font(.custom(AppFont.PS.nunitoBold, size: 9))
                    .foregroundStyle(Color.inkLight)
            }
        }
        .frame(width: 68, height: 68)
        .onAppear {
            withAnimation(.motionReveal) {
                arc = percentage
            }
        }
        .onChange(of: percentage) { _, new in
            withAnimation(.motionReveal) {
                arc = new
            }
        }
        .accessibilityLabel("\(pctLabel) of daily calorie goal")
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
            portionAmbiguousItems: nil
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
