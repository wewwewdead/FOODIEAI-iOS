import SwiftUI

// Extracted from CaptureView.swift (2026-07) to shrink the file.
// The daily-quest Home card, its button style, and the completion
// celebration modal. Types are module-scoped so CaptureView still
// references them.

// MARK: - Daily quest card (Phase 21.5)

/// One playful prompt per day, rendered on Home above the photo card.
/// Whole card is a Button so a tap anywhere opens the action sheet
/// that routes to Scan or Manual Log. The completion state swaps
/// the title to the reward copy and surfaces a "✨ done" pill, but
/// keeps the card tappable — some users want to continue logging
/// after the quest is satisfied.
struct DailyQuestCard: View {
    let quest: DailyQuest
    let completed: Bool
    /// Phase 21.10 — non-nil when the user *just* completed the quest
    /// (within the current session). Triggers the live morph
    /// animation. nil means render the resting state for whichever
    /// `completed` value is current (no animation).
    let completionMoment: CaptureViewModel.DailyQuestCompletionMoment?
    let onTap: () -> Void

    // Phase 21.10 — driven by the morph sequence. Start at the
    // values appropriate for "no animation pending":
    //   - `washOpacity = 0`        no overlay tint
    //   - `pillScale` depends on `completed` (set in .onAppear)
    //   - `titleScale = 1`         no pop
    @State private var washOpacity: Double = 0
    @State private var pillScale: CGFloat = 0
    @State private var titleScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayedTitle: String {
        completed ? quest.kind.rewardCopy : quest.kind.copy
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                // Persistent quest identity badge. The leaf marks the
                // card as "today's healthy choice" regardless of which
                // prompt the engine picked. On completion it swaps to
                // a checkmark in-place so the slot itself confirms the
                // day's quest is done; the trailing greenSave pill
                // still fires as the celebratory beat.
                ZStack {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 36, height: 36)
                    Image(systemName: completed ? "checkmark" : "leaf.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .id(completed ? "check" : "leaf")
                        .transition(.opacity.combined(with: .scale))
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Eyebrow row — brandDeep ink (not gray) gives
                    // the card its own voice. The check-circle pill
                    // on the right carries the celebratory signal
                    // when completion fires.
                    HStack(alignment: .center) {
                        Text("HEALTHY CHOICE FOR TODAY")
                            .appFont(.captionStrong)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(Color.brandDeep)
                        Spacer()
                        if completed {
                            // Trailing affirmative pill — greenSave
                            // disc with a brandCreamSoft check reads
                            // confidently against the brandSoft card
                            // surface (different green family,
                            // unambiguous).
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .regular))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.brandCreamSoft, Color.greenSave)
                                .scaleEffect(pillScale)
                                .opacity(pillScale)
                        }
                    }

                    Text(displayedTitle)
                        .appFont(.title2)
                        .foregroundStyle(completed ? Color.brandDeep : Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .scaleEffect(titleScale, anchor: .leading)
                        // .id forces SwiftUI to treat the post-morph
                        // text as a *new* view so `.transition(.opacity)`
                        // crossfades instead of snap-replacing.
                        .id(displayedTitle)
                        .transition(.opacity)

                    if completed {
                        Text("Logged · back tomorrow")
                            .appFont(.caption)
                            .foregroundStyle(Color.brandDeep.opacity(0.70))
                            .padding(.top, 2)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 4) {
                            Text("Tap to log this")
                                .appFont(.caption)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.brandDeep)
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(questCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
            )
            .appShadow(.shadowCard)
        }
        // Press scale lives in a ButtonStyle so SwiftUI cancels the
        // pressed state the instant an ancestor ScrollView starts
        // panning. A `.simultaneousGesture(DragGesture(min: 0))` here
        // would claim the touch immediately, lose gesture arbitration
        // against the ScrollView, and fire onTap when the user was
        // trying to scroll.
        .buttonStyle(QuestCardButtonStyle())
        .onAppear {
            // Settle the badge into its resting state without
            // animating — re-entering Home with an already-completed
            // quest must show the check in place, not replay
            // yesterday's celebration.
            pillScale = completed ? 1 : 0
        }
        .onChange(of: completionMoment) { _, new in
            guard new != nil else { return }
            runCompletionAnimation()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            completed
            ? "Today's quest complete: \(quest.kind.rewardCopy). Tap to log more."
            : "Today's quest: \(quest.kind.copy). Tap to log it."
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Phase 21.10 morph sequence — runs when `completionMoment`
    /// arrives non-nil. Four beats:
    ///   1. wash overlay fades in + soft haptic
    ///   2. title crossfades to reward copy + pops + success haptic
    ///   3. check-circle badge scales in
    ///   4. wash recedes, card lands in its resting completed state
    ///
    /// Reduce Motion path: skip the choreography, snap the badge in,
    /// fire a single success haptic.
    private func runCompletionAnimation() {
        guard !reduceMotion else {
            withAnimation(.appReduced) { pillScale = 1 }
            Haptics.success()
            return
        }

        // Beat 1 — acknowledgment (0.00–0.25s). Lower opacity than
        // pre-redesign: the wash is now saturated `brand` over a
        // brandSoft base, so 0.30 reads as a confident flash without
        // overwhelming the title underneath.
        withAnimation(.easeOut(duration: 0.25)) {
            washOpacity = 0.30
        }
        Haptics.soft()

        Task { @MainActor in
            // Beat 2 — transformation (0.25–0.55s)
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                titleScale = 1.06
            }
            Haptics.success()
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                titleScale = 1.0
            }

            // Beat 3 — badge settles in (0.55–0.85s)
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.appStamp) {
                pillScale = 1
            }

            // Beat 4 — wash recedes, leaving the card clean
            // (0.85–1.15s). The persistent completion signal is the
            // badge + brand-tinted gradient; the wash is a moment,
            // not a state.
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                washOpacity = 0
            }
        }
    }

    // MARK: - Background composition

    /// Card background. Always `brandSoft` so the quest reads as a
    /// distinct, branded slot vs. the white surface cards stacked
    /// below it on Home. The completion morph layers a more saturated
    /// `brand` wash on top for Beat 1 → Beat 4 of the choreography,
    /// then recedes back to flat brandSoft as the resting completed
    /// state. The web design system fills brand surfaces with single
    /// solid colors (brandCream / brandIvory / brandSoft); the flat
    /// lime block is the moment.
    private var questCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandSoft)

            // Brand wash overlay — appears during Beat 1 of the
            // morph, fades back out at Beat 4. Resting is 0, so
            // the card looks identical whenever no animation runs.
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brand)
                .opacity(washOpacity)
        }
    }
}

/// Press-scale style for the quest card. Mirrors `MealCardButtonStyle`
/// — using a ButtonStyle (rather than a `.simultaneousGesture` on a
/// `.plain` button) lets the parent ScrollView win gesture
/// arbitration: SwiftUI flips `isPressed` back to `false` the instant
/// a pan is detected, so the tap action never fires on a scroll.
struct QuestCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

// MARK: - Quest celebration modal (Phase 21.11)

/// Center-screen celebration that fires when the user completes
/// today's daily quest. The modal makes the moment unmissable; the
/// underlying Phase 21.10 in-place card morph handles the persistent
/// state. Two complementary layers.
///
/// Design intent:
///   - Brief: enters fast, auto-dismisses ~2.5s after entry
///   - Center-emotionally: hero is the reward emoji, not the brand
///   - Respects context: backdrop dims to ~40%, user still sees Home
///   - Tap-to-dismiss for impatient users
///
/// Reduce Motion is honored — bouncy entry becomes a calm fade,
/// the success haptic stays so the completion still registers.
struct QuestCelebrationModal: View {
    let moment: CaptureViewModel.DailyQuestCompletionMoment
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var backdropOpacity: Double = 0
    @State private var cardScale: CGFloat = 0.6
    @State private var cardOpacity: Double = 0
    @State private var heroScale: CGFloat = 0.4
    @State private var heroRotation: Double = -15
    @State private var sparkleOpacity: Double = 0
    @State private var sparkleScale: CGFloat = 0.5
    @State private var rewardOpacity: Double = 0
    @State private var rewardOffset: CGFloat = 8
    @State private var didDismiss: Bool = false

    var body: some View {
        ZStack {
            // Backdrop dim — clear-color is no good for hit-testing
            // taps reliably; black at low opacity gives a real tap
            // target so tapping anywhere outside the card dismisses.
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            // Celebration card
            VStack(spacing: AppSpacing.lg) {
                // Hero: large emoji from the reward copy, with
                // sparkle accents fanning out behind it on beat 3.
                ZStack {
                    sparkleLayer
                        .opacity(sparkleOpacity)
                        .scaleEffect(sparkleScale)

                    Text(heroEmoji)
                        .font(.system(size: 76))
                        .scaleEffect(heroScale)
                        .rotationEffect(.degrees(heroRotation))
                        .accessibilityHidden(true)
                }
                .frame(width: 140, height: 140)

                VStack(spacing: AppSpacing.xs) {
                    Text("QUEST COMPLETE").eyebrow()
                        .foregroundStyle(Color.brandDeep)

                    Text(rewardHeadline)
                        .appFont(.display2)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(rewardOpacity)
                        .offset(y: rewardOffset)
                }
                .padding(.horizontal, AppSpacing.md)
            }
            .padding(.vertical, AppSpacing.xl)
            .padding(.horizontal, AppSpacing.lg)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(Color.bgSurface)
            )
            .overlay(
                // Subtle brand-tinted top edge — premium detail that
                // gives the card a small lift without color-flooding.
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.brand.opacity(0.35),
                                Color.brandSoft.opacity(0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .appShadow(.shadowElevated)
            .scaleEffect(cardScale)
            .opacity(cardOpacity)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl))
            .onTapGesture { dismiss() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Quest complete. \(rewardHeadline). Tap to dismiss.")
            .accessibilityAddTraits(.isButton)
        }
        .onAppear { play() }
    }

    // MARK: - Reward-copy parsing
    //
    // Phase 21 reward copies all start with an emoji (e.g.
    // "🍎 Fruit logged — small win"). We render the emoji at hero
    // size separately, and the rest as the headline. The `> 0x238C`
    // floor skips ASCII digits that `isEmoji` reports as true when
    // followed by the keycap sequence — none of our reward copies
    // use those, so the filter is purely defensive.

    private var heroEmoji: String {
        guard let first = moment.rewardCopy.first,
              first.unicodeScalars.contains(where: { scalar in
                  scalar.properties.isEmoji && scalar.value > 0x238C
              }) else {
            return "✨"
        }
        return String(first)
    }

    private var rewardHeadline: String {
        var copy = moment.rewardCopy
        if let first = copy.first,
           first.unicodeScalars.contains(where: { scalar in
               scalar.properties.isEmoji && scalar.value > 0x238C
           }) {
            copy.removeFirst()
        }
        return copy.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sparkle accents
    //
    // Six SF Symbol sparkles arranged on a circle around the hero.
    // Alternating sizes give visual rhythm; brand color keeps them
    // on-palette. They fade and scale in together at beat 3 so the
    // user reads them as "a celebration moment" rather than six
    // separate elements.
    @ViewBuilder
    private var sparkleLayer: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: i.isMultiple(of: 2) ? 14 : 10,
                                  weight: .heavy))
                    .foregroundStyle(Color.brand)
                    .offset(
                        x: cos(Double(i) * .pi / 3) * 62,
                        y: sin(Double(i) * .pi / 3) * 62
                    )
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Animation

    private func play() {
        if reduceMotion {
            // Calm fade-in. No spring, no rotation, no staggered
            // beats. Sparkles still appear (they're structural to
            // the layout) but without independent motion.
            withAnimation(.appReduced) {
                backdropOpacity = 0.4
                cardScale = 1
                cardOpacity = 1
                heroScale = 1
                heroRotation = 0
                rewardOpacity = 1
                rewardOffset = 0
                sparkleOpacity = 1
                sparkleScale = 1
            }
            Haptics.success()
            scheduleAutoDismiss()
            return
        }

        // Beat 1 (0.00–0.20s) — backdrop dims, card enters with spring
        withAnimation(.easeOut(duration: 0.20)) {
            backdropOpacity = 0.4
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
            cardScale = 1
            cardOpacity = 1
        }
        Haptics.soft()

        Task { @MainActor in
            // Beat 2 (0.20–0.45s) — hero springs in, rotation corrects
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) {
                heroScale = 1.1
                heroRotation = 0
            }

            // Beat 3 (0.45–0.70s) — hero settles, sparkles fan,
            // success haptic lands with the visual peak.
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                heroScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.4)) {
                sparkleOpacity = 1
                sparkleScale = 1
            }
            Haptics.success()

            // Beat 4 (0.70–1.05s) — reward copy rises into place
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                rewardOpacity = 1
                rewardOffset = 0
            }

            scheduleAutoDismiss()
        }
    }

    private func scheduleAutoDismiss() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !didDismiss { dismiss() }
        }
    }

    private func dismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        withAnimation(.easeIn(duration: 0.22)) {
            backdropOpacity = 0
            cardScale = 0.94
            cardOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            onDismiss()
        }
    }
}

