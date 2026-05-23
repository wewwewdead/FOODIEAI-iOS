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

    // MARK: - Story mode state

    /// Whether the full-screen Wrapped-style story is currently
    /// presented. The Mirror tab itself just shows the hero + a
    /// prominent entry card; tapping the entry card flips this true,
    /// which presents `FoodMirrorStoryView` in a `.fullScreenCover`.
    @State private var showingStory = false

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
        .onReceive(Self.freshnessTicker) { now in
            freshnessNow = now
        }
        .onDisappear {
            viewModel.cancelPendingRefresh()
        }
        .fullScreenCover(isPresented: $showingStory) {
            storyCover
        }
    }

    /// Body of the full-screen story cover. Computed so we can read
    /// the current loaded summary out of the view model at the moment
    /// of presentation; if the state has slipped back to non-loaded
    /// (e.g. a background refresh failed) we fall back to a graceful
    /// close so the cover is never stuck on stale or missing content.
    @ViewBuilder
    private var storyCover: some View {
        if case .loaded(let summary) = viewModel.state,
           summary.hasAnyContent {
            let pages = storyPageKinds(for: summary)
            FoodMirrorStoryView(
                pages: pages,
                renderPage: { kind in
                    AnyView(storyPageView(kind, summary: summary))
                },
                renderAlbumThumbnail: { kind in
                    AnyView(albumThumbnail(kind, summary: summary))
                },
                albumAccessibilityLabel: { kind in
                    albumCardMeta(kind, summary: summary).eyebrow
                },
                onClose: { showingStory = false }
            )
        } else {
            // Defensive: shouldn't normally render because the entry
            // card only shows in .loaded + hasAnyContent, but if the
            // state changes while the cover is up, close gracefully.
            Color.clear.onAppear { showingStory = false }
        }
    }

    /// Rolls the freshness caption forward without a network refresh.
    /// One tick per minute is plenty — the captions only switch on
    /// minute-resolution boundaries ("just now" → "1 min ago" etc.).
    /// Stored as `static let` to avoid the same publisher-recreation
    /// trap that the story ticker used to fall into.
    private static let freshnessTicker = Timer.publish(
        every: 60,
        on: .main,
        in: .common
    ).autoconnect()

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
        // The Mirror tab itself is the *entry point* into the Wrapped-
        // style story. The hero header above stays put; below it we
        // show an at-a-glance stats strip and a single rich "entry
        // card" that invites the user to open the full-screen story.
        //
        // The learning-state fallback (when we're in `.loaded` but the
        // summary has nothing content-bearing to say) keeps the
        // existing inline card aesthetic — the story only kicks in
        // when there's enough to actually narrate.
        if summary.hasAnyContent {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                quickStatsStrip(for: summary)
                    .transition(staggeredTransition(for: 0))
                storyEntryCard(for: summary)
                    .transition(staggeredTransition(for: 1))
            }
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                quickStatsStrip(for: summary)
                    .transition(staggeredTransition(for: 0))
                learningStateCard(summary.learningProgress)
                    .transition(staggeredTransition(for: 1))
            }
        }
    }

    // MARK: - Story entry card

    /// The invitation that lives on the Mirror tab and opens the
    /// full-screen story when tapped. Designed as a hero-style card
    /// (brand gradient surface, sparkle badge, headline, a peek at
    /// the moment title, and a "Tap to view" chevron) so it reads as
    /// a single deliberate next-step affordance rather than a passive
    /// preview tile.
    private func storyEntryCard(for summary: FoodMirrorSummary) -> some View {
        let pageCount = storyPageKinds(for: summary)
            .filter { $0 != .album }
            .count
        let momentTitle = viewModel.currentMoment.flatMap { moment in
            moment.kind == .learning ? nil : moment.title
        }
        let peekTitle = momentTitle
            ?? summary.todaysGentleNudge
            ?? summary.thisWeekChanged
            ?? summary.weeklySummary
            ?? "A few things FoodieAI noticed about how you eat."

        return Button {
            Haptics.tap()
            showingStory = true
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(alignment: .center, spacing: AppSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(Color.brandSoft)
                            .frame(width: 44, height: 44)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.brandDeep)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR STORY · TAP TO OPEN")
                            .eyebrow()
                            .foregroundStyle(Color.brandDeep)
                        if pageCount > 0 {
                            Text(pageCount == 1
                                 ? "1 moment ready"
                                 : "\(pageCount) moments ready")
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Color.brandDeep)
                }

                Text("See what FoodieAI noticed.")
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(peekTitle)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.textBody)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.brandDeep)
                    Text("Tap to view")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.brandDeep)
                    Spacer(minLength: 0)
                }
                .padding(.top, AppSpacing.xs)
            }
            .padding(AppSpacing.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.bgSurface,
                                Color.brandSoft.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(Color.brand.opacity(0.22), lineWidth: 1)
            )
            .appShadow(.shadowCard)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open your Mirror story"))
        .accessibilityHint(Text("Opens the full-screen story experience."))
    }

    // MARK: - Story page list

    /// Enumerates the story pages we can build from a loaded summary.
    /// Used both to render the carousel and to know the page count
    /// for the progress-bar row, so they can never disagree.
    fileprivate enum StoryPageKind: String, Identifiable, CaseIterable {
        case quickStats
        case moment
        case todaysNudge
        case thisWeekChanged
        case weeklySummary
        case mostCommonFoods
        case moodInsight
        case timingInsight
        case suggestedExperiment
        /// Terminal recap grid appended after the last content page
        /// when the story has more than one card. Lets the user
        /// revisit any card via a tappable thumbnail grid.
        case album
        var id: String { rawValue }
    }

    /// Order of pages mirrors the old scroll order so users who used
    /// the previous Mirror still see the same content first.
    private func storyPageKinds(for summary: FoodMirrorSummary) -> [StoryPageKind] {
        var pages: [StoryPageKind] = []
        let hasQuickStats =
            summary.sevenDayLogCount > 0 ||
            summary.thirtyDayLogCount > 0 ||
            summary.moodLogCount > 0
        if hasQuickStats { pages.append(.quickStats) }
        if let moment = viewModel.currentMoment,
           moment.kind != .learning {
            pages.append(.moment)
        }
        if summary.todaysGentleNudge   != nil { pages.append(.todaysNudge) }
        if summary.thisWeekChanged     != nil { pages.append(.thisWeekChanged) }
        if summary.weeklySummary       != nil { pages.append(.weeklySummary) }
        if !summary.mostCommonFoods.isEmpty   { pages.append(.mostCommonFoods) }
        if summary.moodInsight         != nil { pages.append(.moodInsight) }
        if summary.timingInsight       != nil { pages.append(.timingInsight) }
        if summary.suggestedExperiment != nil { pages.append(.suggestedExperiment) }
        // Append the album as a terminal page when there's more
        // than one content card to revisit. A single-card story
        // doesn't need a recap grid.
        if pages.count > 1 { pages.append(.album) }
        return pages
    }

    // MARK: - Story: per-page rendering

    @ViewBuilder
    private func storyPageView(_ kind: StoryPageKind,
                               summary: FoodMirrorSummary) -> some View {
        switch kind {
        case .quickStats:
            storyQuickStatsPage(summary)
        case .moment:
            if let moment = viewModel.currentMoment {
                storyMomentPage(moment)
            }
        case .todaysNudge:
            if let nudge = summary.todaysGentleNudge {
                storyHeadlinePage(
                    badge: .init(symbol: "leaf.fill",
                                 tint: .brandDeep, bg: .brandSoft),
                    eyebrow: "TODAY'S NUDGE",
                    title: nudge,
                    evidence: evidenceLine(for: summary)
                )
            }
        case .thisWeekChanged:
            if let changed = summary.thisWeekChanged {
                storyHeadlinePage(
                    badge: .init(symbol: "chart.line.uptrend.xyaxis",
                                 tint: .catBenefitsInk, bg: .catBenefits),
                    eyebrow: "THIS WEEK CHANGED",
                    title: changed,
                    evidence: nil
                )
            }
        case .weeklySummary:
            if let weekly = summary.weeklySummary {
                storyHeadlinePage(
                    badge: .init(symbol: "calendar",
                                 tint: .accentCool, bg: .catBenefits),
                    eyebrow: "THIS WEEK",
                    title: weekly,
                    evidence: nil
                )
            }
        case .mostCommonFoods:
            storyMostCommonFoodsPage(summary.mostCommonFoods)
        case .moodInsight:
            if let mood = summary.moodInsight {
                storyHeadlinePage(
                    badge: .init(symbol: "heart.fill",
                                 tint: .accentWarm, bg: .catDrawbacks),
                    eyebrow: "MOOD & FOOD",
                    title: mood,
                    evidence: nil
                )
            }
        case .timingInsight:
            if let timing = summary.timingInsight {
                storyHeadlinePage(
                    badge: .init(symbol: "clock.fill",
                                 tint: .accentCool, bg: .catBenefits),
                    eyebrow: "MEAL TIMING",
                    title: timing,
                    evidence: nil
                )
            }
        case .suggestedExperiment:
            if let experiment = summary.suggestedExperiment {
                storyHeadlinePage(
                    badge: .init(symbol: "wand.and.stars",
                                 tint: .catBenefitsInk, bg: .catBenefits),
                    eyebrow: "A SMALL EXPERIMENT",
                    title: experiment,
                    evidence: "Patterns shift slowly — small experiments work best."
                )
            }
        case .album:
            // The album page is rendered by `FoodMirrorStoryView`
            // itself (full-screen grid), not by the per-page
            // renderer — this branch only exists so the switch is
            // exhaustive and is never hit in practice.
            EmptyView()
        }
    }

    /// Opening "your week at a glance" page. Three big stat tiles in
    /// a column with bolder type than the inline strip; reads as the
    /// title page of the story.
    private func storyQuickStatsPage(_ summary: FoodMirrorSummary) -> some View {
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

        return StoryShell(
            badge: .init(symbol: "sparkles",
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "YOUR WEEK AT A GLANCE"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("Here's where you are right now.")
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: AppSpacing.sm) {
                    ForEach(tiles) { tile in
                        StoryStatRow(tile: tile)
                    }
                }
                .padding(.top, AppSpacing.xs)
            }
        }
    }

    /// FoodOS moment as a story page. Uses the same body+evidence
    /// layout as the inline moment card but with bolder spacing.
    /// Crucially, the feedback chips remain Buttons so they consume
    /// their own taps and the carousel doesn't advance under them.
    private func storyMomentPage(_ moment: FoodOSMoment) -> some View {
        StoryShell(
            badge: .init(symbol: momentBadgeSymbol(for: moment),
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "FOR YOU · FOODOS MOMENT"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(moment.title)
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
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
                }
                if FoodOSStoryBuilder.shouldRenderActionLabel(moment),
                   let action = moment.actionLabel {
                    foodOSMomentActionChip(action)
                }
                if FoodOSMomentFeedbackPolicy.showsControls(for: moment) {
                    FoodOSMomentFeedbackView(
                        moment: moment,
                        recordedFeedback: viewModel.lastFeedbackForCurrentMoment,
                        onTap: { feedback in
                            viewModel.recordFeedback(feedback)
                        }
                    )
                }
            }
        }
    }

    /// Generic large-type "one idea per card" page.
    private func storyHeadlinePage(badge: MirrorBadge,
                                   eyebrow: String,
                                   title: String,
                                   evidence: String?) -> some View {
        StoryShell(badge: badge, eyebrow: eyebrow) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(title)
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
                if let evidence {
                    Text(evidence)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Most-common-foods rendered as a story page. Reuses the bar
    /// visualisation from the inline card but in a more spacious
    /// vertical rhythm to suit a single-idea page.
    private func storyMostCommonFoodsPage(_ foods: [FoodMirrorSummary.FoodCount]) -> some View {
        let maxCount = max(foods.map { $0.count }.max() ?? 1, 1)
        return StoryShell(
            badge: .init(symbol: "fork.knife",
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "MOST COMMON FOODS"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("The meals you keep coming back to.")
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(Array(foods.enumerated()), id: \.offset) {
                        index, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: AppSpacing.sm) {
                                Text("\(index + 1)")
                                    .appFont(.captionStrong)
                                    .foregroundStyle(Color.brandDeep)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.brandSoft))
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
                            .padding(.leading, 30)
                        }
                    }
                }
                .padding(.top, AppSpacing.xs)
            }
        }
    }

    // MARK: - Album recap

    /// Display metadata for an album thumbnail. Mirrors the badge/
    /// eyebrow/title language of each content page so a thumbnail
    /// reads as a miniature of the card it came from.
    fileprivate struct AlbumCardMeta {
        let badge: MirrorBadge
        let eyebrow: String
        let shortTitle: String
    }

    /// Maps each content `StoryPageKind` to the badge/eyebrow/title
    /// trio used by its full-size card, so the album thumbnails
    /// stay in lockstep with `storyPageView` without trying to
    /// scale the full layout down (which would look broken).
    private func albumCardMeta(_ kind: StoryPageKind,
                               summary: FoodMirrorSummary) -> AlbumCardMeta {
        switch kind {
        case .quickStats:
            return .init(
                badge: .init(symbol: "sparkles",
                             tint: .brandDeep, bg: .brandSoft),
                eyebrow: "YOUR WEEK",
                shortTitle: "Where you are right now."
            )
        case .moment:
            let moment = viewModel.currentMoment
            return .init(
                badge: .init(
                    symbol: moment.map(momentBadgeSymbol(for:)) ?? "sparkles",
                    tint: .brandDeep, bg: .brandSoft
                ),
                eyebrow: "FOODOS MOMENT",
                shortTitle: moment?.title ?? "A moment for you."
            )
        case .todaysNudge:
            return .init(
                badge: .init(symbol: "leaf.fill",
                             tint: .brandDeep, bg: .brandSoft),
                eyebrow: "TODAY'S NUDGE",
                shortTitle: summary.todaysGentleNudge ?? ""
            )
        case .thisWeekChanged:
            return .init(
                badge: .init(symbol: "chart.line.uptrend.xyaxis",
                             tint: .catBenefitsInk, bg: .catBenefits),
                eyebrow: "THIS WEEK CHANGED",
                shortTitle: summary.thisWeekChanged ?? ""
            )
        case .weeklySummary:
            return .init(
                badge: .init(symbol: "calendar",
                             tint: .accentCool, bg: .catBenefits),
                eyebrow: "THIS WEEK",
                shortTitle: summary.weeklySummary ?? ""
            )
        case .mostCommonFoods:
            let names = summary.mostCommonFoods.prefix(2)
                .map { $0.name }
                .joined(separator: ", ")
            return .init(
                badge: .init(symbol: "fork.knife",
                             tint: .brandDeep, bg: .brandSoft),
                eyebrow: "MOST COMMON",
                shortTitle: names.isEmpty
                    ? "Meals you keep coming back to."
                    : names
            )
        case .moodInsight:
            return .init(
                badge: .init(symbol: "heart.fill",
                             tint: .accentWarm, bg: .catDrawbacks),
                eyebrow: "MOOD & FOOD",
                shortTitle: summary.moodInsight ?? ""
            )
        case .timingInsight:
            return .init(
                badge: .init(symbol: "clock.fill",
                             tint: .accentCool, bg: .catBenefits),
                eyebrow: "MEAL TIMING",
                shortTitle: summary.timingInsight ?? ""
            )
        case .suggestedExperiment:
            return .init(
                badge: .init(symbol: "wand.and.stars",
                             tint: .catBenefitsInk, bg: .catBenefits),
                eyebrow: "A SMALL EXPERIMENT",
                shortTitle: summary.suggestedExperiment ?? ""
            )
        case .album:
            // Never rendered as a thumbnail (filtered out of the
            // grid), but the enum is exhaustive so we still need
            // a case. Empty values make the bug obvious if it
            // ever does slip through.
            return .init(
                badge: .init(symbol: "square.grid.2x2.fill",
                             tint: .brandDeep, bg: .brandSoft),
                eyebrow: "",
                shortTitle: ""
            )
        }
    }

    /// Compact tile for one content page in the album grid. Shows
    /// the page's badge, eyebrow, and a short title clipped to
    /// three lines so the grid stays uniform regardless of which
    /// pages happened to be in the story.
    private func albumThumbnail(_ kind: StoryPageKind,
                                summary: FoodMirrorSummary) -> some View {
        let meta = albumCardMeta(kind, summary: summary)
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ZStack {
                Circle()
                    .fill(meta.badge.bg)
                    .frame(width: 32, height: 32)
                Image(systemName: meta.badge.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(meta.badge.tint)
            }
            Text(meta.eyebrow)
                .eyebrow()
                .foregroundStyle(Color.brandDeep.opacity(0.85))
                .lineLimit(1)
            Text(meta.shortTitle)
                .appFont(.captionStrong)
                .foregroundStyle(Color.ink)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .frame(height: 130, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.15), lineWidth: 1)
        )
        .appShadow(.shadowCard)
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
        case .revelation:  return "sparkles"
        case .learning:    return "hourglass"
        case .reflection:  return "heart.fill"
        }
    }

    /// Honest evidence line keyed off the 30-day log count, so a card
    /// never overclaims. Delegates to the shared presentation helper
    /// so the Mirror tab and Home preview phrase evidence identically.
    private func evidenceLine(for summary: FoodMirrorSummary) -> String? {
        FoodMirrorPresentation.evidenceLine(for: summary)
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

/// Story-page shell used by every page in the Wrapped-style
/// carousel. Mirrors the badge + eyebrow language of
/// `MirrorContentCard` but is laid out as a full-bleed page —
/// generous internal padding, larger badge, content vertically
/// centred so a single headline reads as the page's whole idea.
/// No outer card chrome of its own; the parent story container
/// supplies the rounded "stage" background.
struct StoryShell<Content: View>: View {
    let badge: MirrorBadge
    let eyebrow: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            // Pinned header — badge + eyebrow stay at the top of
            // the card, outside the scrollable region, so they're
            // always the first thing the user sees on a tall page.
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(badge.bg)
                        .frame(width: 44, height: 44)
                    Image(systemName: badge.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(badge.tint)
                }
                Text(eyebrow)
                    .eyebrow()
                    .foregroundStyle(Color.brandDeep)
                Spacer(minLength: 0)
            }

            // Scrollable content. The inner Spacers vertically
            // centre short content within the available space, but
            // collapse to zero when the content is tall enough to
            // scroll — so the moment card (title + body + evidence
            // + action chip + feedback chips) can no longer spill
            // past the 500pt container into the hero above.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    content()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity,
                       minHeight: 0,
                       alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity,
               maxHeight: .infinity,
               alignment: .topLeading)
    }
}

/// Single row used by the opening "your week at a glance" story
/// page. Larger than the inline `QuickStatView` tile because each
/// stat now gets the full width of a story page.
struct StoryStatRow: View {
    let tile: QuickStatTile

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.brandSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: tile.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tile.value)")
                    .appFont(.title1)
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
                Text(tile.label)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(tile.value) \(tile.label)"))
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
fileprivate struct FoodMirrorStoryView: View {
    /// Ordered list of pages to show, including a trailing `.album`
    /// page when there's more than one content card to revisit.
    let pages: [FoodMirrorView.StoryPageKind]
    /// Renders a single non-album content page. The caller is
    /// responsible for matching kind → page renderer (so the cover
    /// stays decoupled from the view model that owns the moment,
    /// summary etc.). Called with `AnyView` so the cover can hold a
    /// uniform child type regardless of which page is showing.
    let renderPage: (FoodMirrorView.StoryPageKind) -> AnyView
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
    /// Flag flipped by `onChange(of: index)` so the inserted card can
    /// run its scale+opacity entrance animation. Reset to `false`
    /// just before each card change and back to `true` on the next
    /// run loop, which produces a clean spring-in on every advance.
    @State private var contentAppeared: Bool = true
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
        .onChange(of: index) { _, _ in
            // Reset the entrance flag so the new card runs the
            // spring-in animation on appear. The async hop ensures
            // SwiftUI registers the false → true transition as an
            // animatable change instead of collapsing them into a
            // single frame.
            contentAppeared = false
            DispatchQueue.main.async {
                withAnimation(
                    reduceMotion
                        ? .none
                        : .spring(response: 0.4, dampingFraction: 0.85)
                ) {
                    contentAppeared = true
                }
            }
        }
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
    /// asymmetric slide (trailing → leading) and runs a subtle
    /// scale+opacity entrance for the "premium" feel — Duolingo-style
    /// without per-element stagger (intentional V1 simplification,
    /// see the decisions log in the task description).
    @ViewBuilder
    private var cardArea: some View {
        let kind = currentKind
        Group {
            if let kind, kind == .album {
                albumGrid
                    .id("album")
            } else if let kind {
                cardSurface {
                    renderPage(kind)
                }
                .id("card-\(kind.rawValue)-\(index)")
                .modifier(
                    StoryCardEntrance(
                        appeared: contentAppeared,
                        reduceMotion: reduceMotion
                    )
                )
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
            renderPage(kind)
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
                    .foregroundStyle(.white)
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
        if reduceMotion {
            index = next
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                index = next
            }
        }
    }
}

/// Subtle scale + opacity entrance applied to each card as it
/// becomes the current page. The whole-card spring reads as "the
/// next idea just landed" without requiring the per-element stagger
/// that would have to thread through every page renderer.
private struct StoryCardEntrance: ViewModifier {
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                (appeared || reduceMotion) ? 1.0 : 0.96
            )
            .opacity(
                (appeared || reduceMotion) ? 1.0 : 0.0
            )
    }
}

#if DEBUG
#Preview("FoodMirrorView") {
    FoodMirrorView()
}
#endif
