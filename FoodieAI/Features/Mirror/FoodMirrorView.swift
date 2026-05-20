import SwiftUI

/// Food Mirror tab — a soft reflection of the user's recent eating
/// patterns, derived entirely from their saved `food_logs`. Read-only.
/// Renders only the cards that have meaningful content; everything
/// else stays hidden.
struct FoodMirrorView: View {
    @StateObject private var viewModel = FoodMirrorViewModel()

    @EnvironmentObject private var notifRouter: NotificationRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tracks whether the user has seen Mirror in `.ready` state this
    /// session. Used to fire a one-shot celebration when the surface
    /// crosses learning → ready. Session-scoped only; no persistence.
    @State private var hasSeenReadyThisSession = false
    @State private var celebrate = false

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
            backgroundBlobs

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    hero
                    content
                        .transition(
                            .scale(scale: 0.96).combined(with: .opacity)
                        )
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl2)
                .animation(
                    reduceMotion ? .appReduced : .appMorph,
                    value: viewModel.state
                )
            }
            .refreshable {
                await viewModel.refresh()
            }

            if celebrate {
                celebrationOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .allowsHitTesting(false)
            }
        }
        .task {
            await viewModel.refresh()
            checkForFirstReady()
        }
        .onChange(of: viewModel.state) { _, _ in
            checkForFirstReady()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .foodLogDidChange)
        ) { _ in
            Task { await viewModel.refresh() }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                Text("YOUR FOOD MIRROR")
                    .eyebrow()
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
                MirrorHeroOrb(reduceMotion: reduceMotion)
            }
            Text("Your Food Mirror")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
            Text(heroSubtitle)
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, AppSpacing.xs)
    }

    private var heroSubtitle: String {
        switch viewModel.state {
        case .loaded(let summary):
            if let identity = summary.eatingIdentity { return identity }
            return "A living reflection of how you eat."
        case .empty:
            return "A living reflection of how you eat — sharpening with every meal."
        default:
            return "A living reflection of how you eat."
        }
    }

    // MARK: - Background

    /// Soft brand-tinted blobs that drift behind the content. Pure
    /// decoration; no hit-testing. Disabled motion is fine — the
    /// blobs are static even without Reduce Motion since the scroll
    /// itself already supplies parallax via the layered content.
    private var backgroundBlobs: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.brandSoft.opacity(0.55))
                    .frame(width: geo.size.width * 0.9)
                    .blur(radius: 60)
                    .offset(x: -geo.size.width * 0.25,
                            y: -geo.size.height * 0.15)
                Circle()
                    .fill(Color.catBenefits.opacity(0.35))
                    .frame(width: geo.size.width * 0.7)
                    .blur(radius: 60)
                    .offset(x: geo.size.width * 0.35,
                            y: geo.size.height * 0.25)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            loadingView
        case .empty(let progress):
            learningStateCard(progress)
        case .failed(let message):
            failedCard(message: message)
        case .loaded(let summary):
            loadedContent(summary)
        }
    }

    private var loadingView: some View {
        VStack(spacing: AppSpacing.md) {
            ProgressView()
            Text("Looking at your meals…")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.xl2)
    }

    // MARK: - Learning state

    /// Premium learning-state card. Shows the headline that matches
    /// the user's current bucket, a soft explanation, a custom
    /// gradient progress capsule with the "X of 8" label, and the
    /// fixed CTA copy.
    private func learningStateCard(_ progress: LearningProgress) -> some View {
        MirrorContentCard(
            badge: .init(symbol: "sparkles", tint: .brandDeep, bg: .brandSoft),
            eyebrow: "STILL LEARNING"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(progress.state.headline)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(progress.state.explanation)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.textBody)
                    .fixedSize(horizontal: false, vertical: true)

                MirrorProgressCapsule(
                    value: progress.mealsLoggedInWindow,
                    total: progress.target,
                    reduceMotion: reduceMotion
                )
                .frame(height: 10)
                .padding(.top, AppSpacing.xs)

                HStack(alignment: .firstTextBaseline) {
                    Text(progress.progressText)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                    Spacer(minLength: AppSpacing.md)
                    Button {
                        Haptics.tap()
                        notifRouter.requestTab(0)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Keep logging")
                                .appFont(.captionStrong)
                                .foregroundStyle(Color.brandDeep)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Color.brandDeep)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Keep logging"))
                    .accessibilityHint(Text("Opens Home so you can log or snap a meal."))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private func failedCard(message: String) -> some View {
        MirrorContentCard(
            badge: .init(symbol: "exclamationmark.bubble.fill",
                         tint: .accentWarm, bg: .catDrawbacks),
            eyebrow: "HICCUP"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Couldn't load your mirror")
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                Text(message)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Button {
                    Haptics.tap()
                    Task { await viewModel.refresh() }
                } label: {
                    Text("Try again")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.brandDeep)
                }
                .padding(.top, AppSpacing.xs)
            }
        }
    }

    // MARK: - Loaded content (staggered entrance)

    @ViewBuilder
    private func loadedContent(_ summary: FoodMirrorSummary) -> some View {
        // Story-shaped layout: a small group of "headline" cards (today's
        // nudge + what changed this week) is what the user reads first;
        // the longer-tail patterns sit under a quieter "Patterns"
        // section header below. The identity sentence already lives in
        // the hero subtitle, so no separate card here — keeps the story
        // tight: identity → nudge → change → patterns.
        let headline = headlineCards(for: summary)
        let patterns = patternCards(for: summary)

        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            ForEach(Array(headline.enumerated()), id: \.offset) { index, card in
                card.transition(staggeredTransition(for: index))
            }

            if !patterns.isEmpty {
                patternsSectionHeader
                    .padding(.top, AppSpacing.md)
                    .transition(staggeredTransition(for: headline.count))

                ForEach(Array(patterns.enumerated()), id: \.offset) { index, card in
                    card.transition(staggeredTransition(for: headline.count + 1 + index))
                }
            }

            if !summary.hasAnyContent {
                learningStateCard(summary.learningProgress)
            }
        }
    }

    /// Top-of-story cards: the single most useful thing today, plus
    /// the most recent week-over-week shift. Each is optional; both
    /// can be absent on quiet weeks.
    private func headlineCards(for summary: FoodMirrorSummary) -> [AnyView] {
        var cards: [AnyView] = []
        if let nudge = summary.todaysGentleNudge {
            cards.append(AnyView(
                sectionCard(
                    badge: .init(symbol: "leaf.fill",
                                 tint: .brandDeep, bg: .brandSoft),
                    eyebrow: "TODAY'S NUDGE",
                    title: nudge,
                    body: nil,
                    evidence: evidenceLine(for: summary)
                )
            ))
        }
        if let changed = summary.thisWeekChanged {
            cards.append(AnyView(
                sectionCard(
                    badge: .init(symbol: "chart.line.uptrend.xyaxis",
                                 tint: .catBenefitsInk, bg: .catBenefits),
                    eyebrow: "THIS WEEK CHANGED",
                    title: changed,
                    body: nil,
                    evidence: nil
                )
            ))
        }
        return cards
    }

    /// Lower-weight pattern cards. Grouped under a quiet section
    /// header so the eye reads them as supporting evidence rather
    /// than competing headlines.
    private func patternCards(for summary: FoodMirrorSummary) -> [AnyView] {
        var cards: [AnyView] = []
        if let weekly = summary.weeklySummary {
            cards.append(AnyView(
                sectionCard(
                    badge: .init(symbol: "calendar",
                                 tint: .accentCool, bg: .catBenefits),
                    eyebrow: "THIS WEEK",
                    title: weekly,
                    body: nil,
                    evidence: nil
                )
            ))
        }
        if !summary.mostCommonFoods.isEmpty {
            cards.append(AnyView(mostCommonFoodsCard(summary.mostCommonFoods)))
        }
        if let mood = summary.moodInsight {
            cards.append(AnyView(
                sectionCard(
                    badge: .init(symbol: "heart.fill",
                                 tint: .accentWarm, bg: .catDrawbacks),
                    eyebrow: "MOOD & FOOD",
                    title: mood,
                    body: nil,
                    evidence: nil
                )
            ))
        }
        if let timing = summary.timingInsight {
            cards.append(AnyView(
                sectionCard(
                    badge: .init(symbol: "clock.fill",
                                 tint: .accentCool, bg: .catBenefits),
                    eyebrow: "MEAL TIMING",
                    title: timing,
                    body: nil,
                    evidence: nil
                )
            ))
        }
        if let experiment = summary.suggestedExperiment {
            cards.append(AnyView(experimentCard(experiment)))
        }
        return cards
    }

    /// Quiet section header that introduces the lower-weight pattern
    /// cards. Reads as a kicker, not a competing title.
    private var patternsSectionHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("PATTERNS")
                .eyebrow()
                .foregroundStyle(Color.brandDeep)
            Text("Things your meals keep showing.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Honest evidence line keyed off the 30-day log count, so a card
    /// never overclaims. Mirrors the helper inside HomeMirrorPreview.
    private func evidenceLine(for summary: FoodMirrorSummary) -> String? {
        let count = summary.thirtyDayLogCount
        if count >= 20 { return "Based on 30 days of meals." }
        if count >= summary.learningProgress.target {
            let meals = count == 1 ? "meal" : "meals"
            return "Based on \(count) \(meals) logged."
        }
        return nil
    }

    /// Builds a single section card with a small icon badge, eyebrow
    /// label, and one or two strings of copy. Body is optional;
    /// evidence is an extra soft caption beneath the body.
    private func sectionCard(badge: MirrorBadge,
                             eyebrow: String,
                             title: String,
                             body: String?,
                             evidence: String?) -> some View {
        MirrorContentCard(badge: badge, eyebrow: eyebrow) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(title)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let body {
                    Text(body)
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let evidence {
                    Text(evidence)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .padding(.top, AppSpacing.xs)
                }
            }
        }
    }

    private func mostCommonFoodsCard(_ foods: [FoodMirrorSummary.FoodCount]) -> some View {
        MirrorContentCard(
            badge: .init(symbol: "fork.knife",
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "MOST COMMON FOODS"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("The meals you keep coming back to.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.textBody)
                    .padding(.bottom, AppSpacing.xs)
                ForEach(Array(foods.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .center, spacing: AppSpacing.sm) {
                        Text("\(index + 1)")
                            .appFont(.captionStrong)
                            .foregroundStyle(Color.brandDeep)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle().fill(Color.brandSoft)
                            )
                        Text(entry.name)
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.ink)
                        Spacer(minLength: AppSpacing.sm)
                        Text("\(entry.count)×")
                            .appFont(.chipNumber)
                            .foregroundStyle(Color.brandDeep)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func experimentCard(_ text: String) -> some View {
        MirrorContentCard(
            badge: .init(symbol: "wand.and.stars",
                         tint: .catBenefitsInk, bg: .catBenefits),
            eyebrow: "A SMALL EXPERIMENT"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(text)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Patterns shift slowly — small experiments work best.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .padding(.top, AppSpacing.xs)
            }
        }
    }

    // MARK: - First-time-ready celebration

    /// Fires a one-shot soft celebration the first time we observe
    /// `.loaded` state during this session — captures the
    /// "intelligence has unlocked" moment without inventing
    /// persistence. Skipped under Reduce Motion.
    private func checkForFirstReady() {
        guard !hasSeenReadyThisSession else { return }
        guard case .loaded = viewModel.state else { return }
        hasSeenReadyThisSession = true
        guard !reduceMotion else { return }
        Haptics.soft()
        withAnimation(.motionCelebration) { celebrate = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.motionBase) { celebrate = false }
        }
    }

    private var celebrationOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.brandDeep)
                Text("Your mirror is ready.")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brandDeep)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .background(
                Capsule().fill(Color.bgSurface)
            )
            .overlay(
                Capsule().strokeBorder(Color.brand.opacity(0.4), lineWidth: 1)
            )
            .appShadow(.shadowFloating)
            .padding(.bottom, AppSpacing.xl2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Staggered entrance

    private func staggeredTransition(for index: Int) -> AnyTransition {
        // Reduce Motion users still see opacity changes (no spatial
        // motion). Everyone else gets a soft scale+opacity reveal.
        if reduceMotion {
            return .opacity
        }
        return .scale(scale: 0.96).combined(with: .opacity)
    }
}

// MARK: - Reusable bits

/// Small icon badge consumed by `MirrorContentCard`.
struct MirrorBadge {
    let symbol: String
    let tint: Color
    let bg: Color
}

/// Premium content card for the Mirror tab. Layered surface
/// (bgSurface + hairline border + soft shadow), a small SF Symbol
/// badge at the top-leading corner, an UPPERCASE eyebrow, then the
/// caller's own content.
struct MirrorContentCard<Content: View>: View {
    let badge: MirrorBadge
    let eyebrow: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(badge.bg)
                        .frame(width: 36, height: 36)
                    Image(systemName: badge.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(badge.tint)
                }
                Text(eyebrow)
                    .eyebrow()
                    .foregroundStyle(Color.inkMute)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }
}

/// Gradient progress capsule used by the Mirror's learning state.
/// Animates fill on value change with `.motionProgressFill`; falls
/// back to `.appReduced` when the user has enabled Reduce Motion.
struct MirrorProgressCapsule: View {
    let value: Int
    let total: Int
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.bgSurfaceSoft)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.brand, Color.brandDeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(
                            14,
                            geo.size.width
                                * CGFloat(value)
                                / CGFloat(max(total, 1))
                        )
                    )
                    .animation(
                        reduceMotion ? .appReduced : .motionProgressFill,
                        value: value
                    )
            }
        }
    }
}

/// Larger orb badge for the Mirror tab hero. Same idea as the Home
/// preview's `MirrorOrb` but tuned to sit at display-text scale.
private struct MirrorHeroOrb: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.brandSoft,
                            Color.brandSoft.opacity(0.6)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 28
                    )
                )
                .frame(width: 44, height: 44)
                .overlay(
                    Circle()
                        .strokeBorder(Color.brand.opacity(0.4), lineWidth: 1)
                )
                .scaleEffect(pulse ? 1.07 : 1.0)
                .shadow(color: Color.brand.opacity(0.22),
                        radius: pulse ? 14 : 8, x: 0, y: 3)
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
    }
}

#if DEBUG
#Preview("FoodMirrorView") {
    FoodMirrorView()
}
#endif
