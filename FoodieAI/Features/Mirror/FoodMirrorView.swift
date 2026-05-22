import Combine
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

    /// Ticks once a minute so the freshness caption rolls from
    /// "Updated just now" to "Updated 5 min ago" without a refresh.
    /// Bound through a Timer publisher; the value is only used as
    /// SwiftUI's `now` parameter for the caption computation.
    @State private var freshnessNow: Date = Date()

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
            backgroundBlobs

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    hero
                    transientErrorBanner
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
            // Coalesce rapid bursts (save → mood pulse → re-log) so
            // we issue one refresh per gesture, not three overlapping
            // Supabase fetches racing each other to commit.
            viewModel.scheduleDebouncedRefresh()
        }
        .onReceive(freshnessTicker) { now in
            freshnessNow = now
        }
        .onDisappear {
            viewModel.cancelPendingRefresh()
        }
    }

    /// Rolls the freshness caption forward without a network refresh.
    /// One tick per minute is plenty — the captions only switch on
    /// minute-resolution boundaries ("just now" → "1 min ago" etc.).
    private var freshnessTicker: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    }

    // MARK: - Hero

    /// Hero is wrapped in a soft gradient surface card so the top of
    /// the Mirror reads as a premium "header" — like the now-cards
    /// at the top of Apple Fitness / Oura / Things — instead of plain
    /// text floating on the canvas. The orb floats at the top-trailing
    /// corner; the identity/subtitle/freshness flow down the leading
    /// edge. A tiny pulsing dot next to the eyebrow signals "live."
    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(alignment: .center, spacing: AppSpacing.xs) {
                    LiveDot(reduceMotion: reduceMotion)
                    Text("YOUR FOOD MIRROR")
                        .eyebrow()
                        .foregroundStyle(Color.brandDeep)
                }
                Text("Your Food Mirror")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .padding(.trailing, 56) // reserve room for the floating orb
                Text(heroSubtitle)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
                heroFreshnessRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.cardPad)

            MirrorHeroOrb(reduceMotion: reduceMotion)
                .padding(.top, AppSpacing.lg)
                .padding(.trailing, AppSpacing.lg)
                .accessibilityHidden(true)
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.brandSoft.opacity(0.85),
                            Color.bgSurface
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
    }

    /// Small "Based on X meals · Updated N min ago" caption beneath
    /// the hero subtitle. Stays calm (caption + inkMute) so it reads
    /// as trust text rather than UI chrome. Both halves are optional;
    /// the row hides entirely on a brand-new install.
    @ViewBuilder
    private var heroFreshnessRow: some View {
        let evidence = currentEvidenceLine
        let freshness = FoodMirrorPresentation.freshnessLine(
            updatedAt: viewModel.lastUpdatedAt,
            now: freshnessNow
        )
        if evidence != nil || freshness != nil {
            HStack(spacing: 6) {
                if let evidence {
                    Text(evidence)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                }
                if evidence != nil, freshness != nil {
                    Text("·")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute.opacity(0.6))
                }
                if let freshness {
                    Text(freshness)
                        .appFont(.caption)
                        .foregroundStyle(Color.brandDeep.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, AppSpacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    /// Evidence caption — pulled from the loaded summary when we
    /// have one, otherwise nil so the row hides instead of
    /// inventing a meal count.
    private var currentEvidenceLine: String? {
        if case .loaded(let summary) = viewModel.state {
            return FoodMirrorPresentation.evidenceLine(for: summary)
        }
        return nil
    }

    /// Soft inline banner shown when a background refresh fails but
    /// the previously-loaded content is still visible. Reserved for
    /// transient hiccups — first-load failures still surface the
    /// full failed card. Includes a "Try again" affordance.
    @ViewBuilder
    private var transientErrorBanner: some View {
        if let message = viewModel.refreshErrorMessage {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentWarm)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .appFont(.caption)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Haptics.tap()
                        Task { await viewModel.refresh() }
                    } label: {
                        Text("Try again")
                            .appFont(.captionStrong)
                            .foregroundStyle(Color.brandDeep)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Tries the refresh again."))
                }
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.catDrawbacks.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.accentWarm.opacity(0.35),
                                  lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
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

    /// Skeleton loading state — three stacked placeholder cards that
    /// shimmer until the first refresh resolves. Mirrors the eventual
    /// content shape (badge + eyebrow + title + body lines) so the
    /// transition into real content feels like the page filling in,
    /// not a hard swap. Reduces the perceived wait significantly vs.
    /// a centered spinner.
    private var loadingView: some View {
        VStack(spacing: AppSpacing.lg) {
            ForEach(0..<3, id: \.self) { _ in
                MirrorSkeletonCard(reduceMotion: reduceMotion)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Looking at your meals"))
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

    // MARK: - Quick stats strip

    /// Three small "at a glance" stats sitting just under the hero —
    /// gives the user immediate value before they read the cards.
    /// Each tile is a small surface card with a single number + label,
    /// monospaced digits so they don't dance during refresh. Tiles
    /// hide individually when their value is zero so a brand-new
    /// install never shows "0 / 0 / 0".
    @ViewBuilder
    private func quickStatsStrip(for summary: FoodMirrorSummary) -> some View {
        let tiles: [QuickStatTile] = [
            .init(symbol: "calendar",
                  value: summary.sevenDayLogCount,
                  label: "meals this week"),
            .init(symbol: "fork.knife",
                  value: summary.thirtyDayLogCount,
                  label: "meals in 30 days"),
            .init(symbol: "heart.fill",
                  value: summary.moodLogCount,
                  label: summary.moodLogCount == 1 ? "mood note" : "mood notes")
        ].filter { $0.value > 0 }

        if !tiles.isEmpty {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                ForEach(tiles) { tile in
                    QuickStatView(tile: tile)
                }
            }
            .frame(maxWidth: .infinity)
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
        // tight: moment → identity → nudge → change → patterns.
        //
        // The FoodOS Moment card sits above everything: it's the one
        // useful thing the engine chose for *right now*, so it earns
        // the top slot. We deliberately only render it in `.loaded`
        // — the empty state already has its own "still learning"
        // surface and a moment card would compete with that.
        let headline = headlineCards(for: summary)
        let patterns = patternCards(for: summary)

        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            // Quick "at-a-glance" stat strip — what the user wants to
            // see first when they open the tab. Compact enough to read
            // in one second, then the headline content takes over.
            quickStatsStrip(for: summary)
                .transition(staggeredTransition(for: 0))

            if let moment = viewModel.currentMoment,
               moment.kind != .learning {
                foodOSMomentCard(moment)
                    .transition(staggeredTransition(for: 1))
            }
            ForEach(Array(headline.enumerated()), id: \.offset) { index, card in
                card.transition(staggeredTransition(for: index + 2))
            }

            if !patterns.isEmpty {
                patternsSectionHeader(count: patterns.count)
                    .padding(.top, AppSpacing.md)
                    .transition(staggeredTransition(for: headline.count + 2))

                ForEach(Array(patterns.enumerated()), id: \.offset) { index, card in
                    card.transition(staggeredTransition(for: headline.count + 3 + index))
                }
            }

            if !summary.hasAnyContent {
                learningStateCard(summary.learningProgress)
            }
        }
    }

    /// FoodOS Moment card — the one useful thing the local engine
    /// chose for this refresh. Uses the same `MirrorContentCard`
    /// scaffold as the other Mirror cards so it sits in the
    /// existing visual language, just with a distinctive eyebrow
    /// ("FOODOS MOMENT") and a sparkle badge.
    ///
    /// Body and evidence are both optional — the engine guarantees
    /// at least a title, and the safety pass guarantees the copy
    /// is non-bossy / non-medical / non-shaming.
    private func foodOSMomentCard(_ moment: FoodOSMoment) -> some View {
        PremiumMirrorCard(
            badge: .init(symbol: momentBadgeSymbol(for: moment),
                         tint: .brandDeep,
                         bg: .brandSoft),
            eyebrow: "FOR YOU · FOODOS MOMENT"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(moment.title)
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = moment.body {
                    Text(body)
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let evidence = moment.evidenceLine {
                    Text(evidence)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .padding(.top, AppSpacing.xs)
                }
                // The action prompt completes the CLAIM → EVIDENCE →
                // ACTION arc. Rendered as a calm chip rather than a
                // CTA button — the tap target is the feedback chip
                // ("I'll try this") just below, so the action line is
                // copy, not a button.
                if FoodOSStoryBuilder.shouldRenderActionLabel(moment),
                   let action = moment.actionLabel {
                    foodOSMomentActionChip(action)
                }
                if FoodOSMomentFeedbackPolicy.showsControls(for: moment) {
                    FoodOSMomentFeedbackView(
                        moment: moment,
                        recordedFeedback: viewModel.lastFeedbackForCurrentMoment,
                        onTap: { viewModel.recordFeedback($0) }
                    )
                }
            }
        }
    }

    /// Calm "next-step" chip rendered between evidence and feedback.
    /// brandSoft fill + brandDeep ink + hairline brand border matches
    /// the language of the surrounding Mirror cards; deliberately not
    /// a button — the action is performed by tapping "I'll try this"
    /// in the feedback row beneath.
    private func foodOSMomentActionChip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "arrow.forward.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
                .padding(.top, 2)
            Text(text)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.brandDeep)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(Color.brandSoft.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(Color.brand.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Suggested next step: \(text)"))
    }

    /// Picks an SF Symbol that reads true to the moment's flavor.
    /// Sparkles for the default flavor; specific symbols where the
    /// shape carries meaning (calendar for change, leaf for nudge,
    /// heart for mood-driven reflection).
    private func momentBadgeSymbol(for moment: FoodOSMoment) -> String {
        switch moment.kind {
        case .change:      return "chart.line.uptrend.xyaxis"
        case .celebration: return "sparkles"
        case .recognition: return "fork.knife"
        case .nudge:       return "leaf.fill"
        case .experiment:  return "wand.and.stars"
        case .learning:    return "hourglass"
        case .reflection:  return "heart.fill"
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
    /// cards. Reads as a kicker, not a competing title. A small
    /// count chip ("4 patterns") sits to the right so the user knows
    /// how much is below at a glance.
    private func patternsSectionHeader(count: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                Text("PATTERNS")
                    .eyebrow()
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
                Text(count == 1 ? "1 pattern" : "\(count) patterns")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.brandSoft))
                    .overlay(
                        Capsule().strokeBorder(
                            Color.brand.opacity(0.3), lineWidth: 1
                        )
                    )
            }
            Text("Things your meals keep showing.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Honest evidence line keyed off the 30-day log count, so a card
    /// never overclaims. Delegates to the shared presentation helper
    /// so the Mirror tab and Home preview phrase evidence identically.
    private func evidenceLine(for summary: FoodMirrorSummary) -> String? {
        FoodMirrorPresentation.evidenceLine(for: summary)
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
        // Bars are normalized against the top entry so the most-eaten
        // meal always reads as a full bar. Visual scan beats reading
        // four counts in a row — premium-app affordance for a list
        // that's secretly a chart.
        let maxCount = max(foods.map { $0.count }.max() ?? 1, 1)
        return MirrorContentCard(
            badge: .init(symbol: "fork.knife",
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "MOST COMMON FOODS"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("The meals you keep coming back to.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.textBody)
                    .padding(.bottom, AppSpacing.xs)
                ForEach(Array(foods.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: 6) {
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
                                .lineLimit(1)
                            Spacer(minLength: AppSpacing.sm)
                            Text("\(entry.count)×")
                                .appFont(.chipNumber)
                                .foregroundStyle(Color.brandDeep)
                                .monospacedDigit()
                        }
                        MostCommonFoodBar(
                            fraction: Double(entry.count) / Double(maxCount),
                            reduceMotion: reduceMotion
                        )
                        .frame(height: 6)
                        .padding(.leading, 30) // align under the name
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

/// Premium variant of `MirrorContentCard` used for the FoodOS Moment.
/// Same structural language (badge + eyebrow + caller content) but
/// with a soft brandSoft → bgSurface gradient fill and a brand-tinted
/// shadow so it reads as the headline card of the page — the one
/// thing the engine chose for *right now*. Eyebrow leans brandDeep
/// (vs. inkMute on the base card) to reinforce that priority.
struct PremiumMirrorCard<Content: View>: View {
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
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.brandSoft.opacity(0.9),
                            Color.bgSurface
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.brand.opacity(0.25), lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .shadow(color: Color.brand.opacity(0.12),
                radius: 18, x: 0, y: 8)
    }
}

/// Small horizontal frequency bar used inside the "Most common foods"
/// card. Gradient fill matches the learning-state capsule so the
/// visual language of "this is a measurement" is consistent across
/// the Mirror.
struct MostCommonFoodBar: View {
    let fraction: Double
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
                        width: max(6, geo.size.width
                                   * CGFloat(max(0.0, min(fraction, 1.0))))
                    )
                    .animation(
                        reduceMotion ? .appReduced : .motionProgressFill,
                        value: fraction
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Skeleton placeholder used while the first refresh is in flight.
/// Shape mirrors `MirrorContentCard` (small circle badge, eyebrow
/// line, two body lines) so the swap to real content reads as the
/// page filling in rather than a hard replacement. Pulses opacity
/// on a slow loop; skipped entirely under Reduce Motion.
struct MirrorSkeletonCard: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Circle()
                    .fill(Color.bgSurfaceSoft)
                    .frame(width: 36, height: 36)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.bgSurfaceSoft)
                    .frame(width: 120, height: 10)
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgSurfaceSoft)
                .frame(height: 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgSurfaceSoft)
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgSurfaceSoft)
                .frame(height: 14)
                .frame(maxWidth: 220, alignment: .leading)
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
        .opacity(pulse ? 0.7 : 1.0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
    }
}

/// Tiny pulsing dot used in the hero eyebrow row to signal that the
/// Mirror is a live, always-updating surface. Inner brandDeep dot
/// with a soft brand halo that fades in/out under `.appBreathing`.
/// Static under Reduce Motion.
struct LiveDot: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.brand.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .opacity(pulse ? 0.0 : 0.7)
            Circle()
                .fill(Color.brandDeep)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) { pulse = true }
        }
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

/// Payload for a single tile in the Mirror's quick-stats strip.
/// Identifiable so it can be iterated inside a ForEach.
struct QuickStatTile: Identifiable {
    let symbol: String
    let value: Int
    let label: String
    var id: String { "\(symbol)-\(label)" }
}

/// Single tile used by the quick-stats strip. Compact surface card
/// with a small SF Symbol, a monospaced number, and a one-line
/// label. Fills its share of the row's available width so the
/// strip lays out evenly regardless of how many tiles are visible.
struct QuickStatView: View {
    let tile: QuickStatTile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
            }
            Text("\(tile.value)")
                .appFont(.chipNumber)
                .foregroundStyle(Color.ink)
                .monospacedDigit()
            Text(tile.label)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowFloating)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(tile.value) \(tile.label)"))
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
