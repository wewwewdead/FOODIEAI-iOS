import Combine
import SwiftUI

/// Food Mirror tab — a soft reflection of the user's recent eating
/// patterns, derived entirely from their saved `food_logs`. Read-only.
/// Renders only the cards that have meaningful content; everything
/// else stays hidden.
struct FoodMirrorView: View {
    let isActive: Bool

    @StateObject private var viewModel = FoodMirrorViewModel()

    /// Reflection content relocated here from Today: the weekly recap entry,
    /// detected patterns, and the active coach observation. Loaded on its own
    /// (reads only) so Insights is the single home for "what the app notices."
    @StateObject private var reflection = ReflectionLoader()
    @State private var showingReflectionRecap = false

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
    ///
    /// We deliberately use `.fullScreenCover` (not an in-hierarchy
    /// `.overlay`) because the cover gives us three things for free
    /// that the overlay didn't: it renders as an opaque presentation
    /// surface (no home-screen / Mirror-tab bleed-through behind the
    /// story content during transitions), it hides the tab bar
    /// automatically, and it owns a clean dismissal animation. An
    /// earlier attempt at an `.overlay` + `matchedGeometryEffect`
    /// zoom-open looked broken on device (hard cut on open, semi-
    /// transparent backdrop) — that version is intentionally
    /// reverted. The "zoom open" feel now lives INSIDE the cover as
    /// a scale+fade on the story content (see `presented` flag in
    /// `FoodMirrorStoryView`), which renders reliably because the
    /// container around it is stable.
    @State private var showingStory = false
    @State private var automaticRefreshTask: Task<Void, Never>? = nil

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()
            backgroundBlobs

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    hero
                    transientErrorBanner
                    reflectionSection
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
                await viewModel.refresh(reason: .pullToRefresh, tab: .mirror)
                await reflection.load()
            }

            if celebrate {
                celebrationOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .allowsHitTesting(false)
            }
        }
        .task {
            guard isActive else { return }
            scheduleAutomaticRefresh(reason: .initialAppear)
        }
        .onChange(of: isActive) { _, active in
            if active {
                scheduleAutomaticRefresh(reason: .tabBecameActive)
            } else {
                automaticRefreshTask?.cancel()
                automaticRefreshTask = nil
                viewModel.cancelPendingRefresh()
            }
        }
        .onChange(of: viewModel.state) { _, _ in
            checkForFirstReady()
        }
        .onChange(of: notifRouter.requestedRecap) { _, requested in
            // A recap notification now lands on Insights — load and open it.
            guard requested else { return }
            Task {
                await reflection.load()
                if reflection.latestRecap != nil {
                    showingReflectionRecap = true
                }
                notifRouter.clearRecapRequest()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .foodLogDidChange)
        ) { _ in
            // Coalesce rapid bursts (save → mood pulse → re-log) so
            // we issue one refresh per gesture, not three overlapping
            // Supabase fetches racing each other to commit.
            viewModel.markDirty()
            if isActive {
                viewModel.scheduleDebouncedRefresh(reason: .foodLogChanged)
            }
        }
        .onReceive(Self.freshnessTicker) { now in
            if isActive {
                freshnessNow = now
            }
        }
        .onDisappear {
            viewModel.cancelPendingRefresh()
        }
        .fullScreenCover(isPresented: $showingStory) {
            storyCover
        }
        .sheet(isPresented: $showingReflectionRecap) {
            if let recap = reflection.latestRecap {
                NavigationStack {
                    RecapView(recap: recap)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingReflectionRecap = false }
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Reflection section (recap · patterns · coach)

    /// Surfaces the reflection content moved here from Today. Hidden entirely
    /// when there's nothing to say, so the Insights hero/story stays clean on
    /// a fresh account.
    @ViewBuilder
    private var reflectionSection: some View {
        let hasRecap = reflection.latestRecap != nil
        let hasPatterns = !reflection.patterns.isEmpty
        let hasObservation = reflection.activeObservation != nil
        if hasRecap || hasPatterns || hasObservation {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if let recap = reflection.latestRecap {
                    WeeklyRecapBanner(recap: recap) {
                        Haptics.tap()
                        showingReflectionRecap = true
                    }
                }
                if hasPatterns {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("Patterns").eyebrow()
                            .foregroundStyle(Color.inkMute)
                        ForEach(reflection.patterns) { pattern in
                            PatternCard(pattern: pattern)
                        }
                    }
                }
                if let observation = reflection.activeObservation {
                    CoachObservationCard(
                        observation: observation,
                        onDismiss: {
                            Haptics.tap()
                            Task { await reflection.dismissObservation() }
                        }
                    )
                }
            }
        }
    }

    private func scheduleAutomaticRefresh(reason: RefreshReason) {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor in
            TabPerformanceProbe.appeared(.mirror)
            await Task.yield()
            guard !Task.isCancelled, isActive else { return }
            TabPerformanceProbe.firstFrameYielded(.mirror)
            await viewModel.refresh(reason: reason, tab: .mirror)
            await reflection.load()
            checkForFirstReady()
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
                renderPage: { kind, appeared in
                    AnyView(storyPageView(kind,
                                          summary: summary,
                                          appeared: appeared))
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
            return "A living reflection of how you eat, sharpening with every meal."
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
        // Perf: previously each Circle had its own `.blur(radius: 60)`,
        // which is two separate offscreen blur passes per frame.
        // Wrapping the inner ZStack with a single `.blur(radius: 50)`
        // collapses the work into one blur pass that composites both
        // circles together — visually equivalent at this scale, ~2x
        // cheaper. Circles' fill opacities were bumped slightly to
        // preserve the same perceived intensity after the single-pass
        // blur softens them less aggressively than two stacked passes.
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.brandSoft.opacity(0.65))
                    .frame(width: geo.size.width * 0.9)
                    .offset(x: -geo.size.width * 0.25,
                            y: -geo.size.height * 0.15)
                Circle()
                    .fill(Color.catBenefits.opacity(0.42))
                    .frame(width: geo.size.width * 0.7)
                    .offset(x: geo.size.width * 0.35,
                            y: geo.size.height * 0.25)
            }
            .blur(radius: 50)
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
    enum StoryPageKind: String, Identifiable, CaseIterable {
        case quickStats
        case moment
        case moodRevelation
        case valueRevelation
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
        // Dedicated revelation cards — each independent, each gated
        // only by its own signal. A flat-mood user with a real
        // macro shift sees the value card without a mood card; a
        // mixed-mood user whose macros also moved sees both as
        // separate pages.
        if viewModel.moodRevelation != nil  { pages.append(.moodRevelation) }
        if viewModel.valueRevelation != nil { pages.append(.valueRevelation) }
        if let moment = viewModel.currentMoment,
           moment.kind != .learning,
           // Dedup: when the priority chain returned the mood
           // revelation, the dedicated `.moodRevelation` card is its
           // canonical home — skip the generic `.moment` page so the
           // same revelation doesn't appear twice in the deck.
           moment.kind != .revelation {
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
                               summary: FoodMirrorSummary,
                               appeared: Bool) -> some View {
        switch kind {
        case .quickStats:
            storyQuickStatsPage(summary, appeared: appeared)
        case .moment:
            if let moment = viewModel.currentMoment {
                storyMomentPage(
                    moment,
                    eyebrow: "FOR YOU · FOODOS MOMENT",
                    recordedFeedback: viewModel.lastFeedbackForCurrentMoment,
                    appeared: appeared
                )
            }
        case .moodRevelation:
            if let moment = viewModel.moodRevelation {
                storyMomentPage(
                    moment,
                    eyebrow: "MOOD REVELATION",
                    recordedFeedback: viewModel.lastFeedbackForMoodRevelation,
                    appeared: appeared
                )
            }
        case .valueRevelation:
            if let moment = viewModel.valueRevelation {
                storyMomentPage(
                    moment,
                    eyebrow: "WHAT CHANGED",
                    recordedFeedback: viewModel.lastFeedbackForValueRevelation,
                    appeared: appeared
                )
            }
        case .todaysNudge:
            if let nudge = summary.todaysGentleNudge {
                storyHeadlinePage(
                    badge: .init(symbol: "leaf.fill",
                                 tint: .brandDeep, bg: .brandSoft),
                    eyebrow: "TODAY'S NUDGE",
                    title: nudge,
                    evidence: evidenceLine(for: summary),
                    appeared: appeared
                )
            }
        case .thisWeekChanged:
            if let changed = summary.thisWeekChanged {
                storyHeadlinePage(
                    badge: .init(symbol: "chart.line.uptrend.xyaxis",
                                 tint: .catBenefitsInk, bg: .catBenefits),
                    eyebrow: "THIS WEEK CHANGED",
                    title: changed,
                    evidence: nil,
                    appeared: appeared
                )
            }
        case .weeklySummary:
            if let weekly = summary.weeklySummary {
                storyHeadlinePage(
                    badge: .init(symbol: "calendar",
                                 tint: .accentCool, bg: .catBenefits),
                    eyebrow: "THIS WEEK",
                    title: weekly,
                    evidence: nil,
                    appeared: appeared
                )
            }
        case .mostCommonFoods:
            storyMostCommonFoodsPage(summary.mostCommonFoods,
                                     appeared: appeared)
        case .moodInsight:
            if let mood = summary.moodInsight {
                storyHeadlinePage(
                    badge: .init(symbol: "heart.fill",
                                 tint: .accentWarm, bg: .catDrawbacks),
                    eyebrow: "MOOD & FOOD",
                    title: mood,
                    evidence: nil,
                    appeared: appeared
                )
            }
        case .timingInsight:
            if let timing = summary.timingInsight {
                storyHeadlinePage(
                    badge: .init(symbol: "clock.fill",
                                 tint: .accentCool, bg: .catBenefits),
                    eyebrow: "MEAL TIMING",
                    title: timing,
                    evidence: nil,
                    appeared: appeared
                )
            }
        case .suggestedExperiment:
            if let experiment = summary.suggestedExperiment {
                storyHeadlinePage(
                    badge: .init(symbol: "wand.and.stars",
                                 tint: .catBenefitsInk, bg: .catBenefits),
                    eyebrow: "A SMALL EXPERIMENT",
                    title: experiment,
                    evidence: "Patterns shift slowly, small experiments work best.",
                    appeared: appeared
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
    ///
    /// Each tile is a separate `elements` entry so they cascade in
    /// one-by-one through `StoryShell`'s `FlyIn` — headline first,
    /// then meals-this-week, then 30-day, then mood notes. Matches
    /// the per-line Duolingo rhythm rather than slamming the whole
    /// tile column in as a block.
    private func storyQuickStatsPage(_ summary: FoodMirrorSummary,
                                     appeared: Bool) -> some View {
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

        var elements: [AnyView] = [
            AnyView(
                Text("Here's where you are right now.")
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            )
        ]
        for tile in tiles {
            elements.append(AnyView(StoryStatRow(tile: tile)))
        }

        return StoryShell(
            badge: .init(symbol: "sparkles",
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "YOUR WEEK AT A GLANCE",
            appeared: appeared,
            reduceMotion: reduceMotion,
            elements: elements
        )
    }

    /// FoodOS moment as a story page. Uses the same body+evidence
    /// layout as the inline moment card but with bolder spacing.
    /// Crucially, the feedback chips remain Buttons so they consume
    /// their own taps and the carousel doesn't advance under them.
    ///
    /// `eyebrow` and `recordedFeedback` are passed in so a single
    /// renderer covers all three rateable moments — the priority-
    /// chain pick, the dedicated mood revelation, and the dedicated
    /// value revelation — without each one needing its own near-
    /// duplicate body.
    private func storyMomentPage(_ moment: FoodOSMoment,
                                 eyebrow: String,
                                 recordedFeedback: FoodOSMomentFeedback?,
                                 appeared: Bool) -> some View {
        // Each visible piece of content becomes one element in the
        // shell's cascade. The order matches the visual rhythm:
        // title → reveal (if any) → body → evidence → action chip →
        // feedback chips. Conditional pieces are appended only when
        // present, so a moment with no body doesn't leave a hole in
        // the sequence — the cascade closes ranks naturally.
        var elements: [AnyView] = [
            AnyView(
                Text(moment.title)
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
            )
        ]
        // Two-bar reveal stays a SINGLE element so the cascade reads
        // as "title arrives, THEN the chart arrives" — not "title,
        // before-bar, after-bar, delta-pill". The reveal's internal
        // bar-grow + count-up still runs off `appeared`, so the
        // signature animation fires once the block flies in.
        if let reveal = moment.reveal {
            elements.append(AnyView(
                twoBarReveal(reveal, appeared: appeared)
                    .padding(.vertical, AppSpacing.xs)
            ))
        }
        if let body = moment.body {
            elements.append(AnyView(
                Text(body)
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.textBody)
                    .fixedSize(horizontal: false, vertical: true)
            ))
        }
        if let evidence = moment.evidenceLine {
            elements.append(AnyView(
                Text(evidence)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            ))
        }
        if FoodOSStoryBuilder.shouldRenderActionLabel(moment),
           let action = moment.actionLabel {
            elements.append(AnyView(foodOSMomentActionChip(action)))
        }
        if FoodOSMomentFeedbackPolicy.showsControls(for: moment) {
            elements.append(AnyView(
                FoodOSMomentFeedbackView(
                    moment: moment,
                    recordedFeedback: recordedFeedback,
                    onTap: { feedback in
                        viewModel.recordFeedback(feedback, for: moment)
                    }
                )
            ))
        }

        return StoryShell(
            badge: .init(symbol: momentBadgeSymbol(for: moment),
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: eyebrow,
            appeared: appeared,
            reduceMotion: reduceMotion,
            elements: elements
        )
    }

    // MARK: - Two-bar reveal (Direction B value cards)

    /// Vertical before/after bars with the raw numbers above and
    /// "LAST WEEK" / "THIS WEEK" labels below. Proportional heights:
    /// the taller value owns `maxBarHeight`, the other scales relative
    /// to it. The signed-delta pill sits to the right with an arrow
    /// matching the direction.
    ///
    /// When `appeared` flips false → true the bars grow from a
    /// hairline baseline to their full height and the numbers count
    /// up from 0 to their target — the card's signature beat. Reduce
    /// Motion makes both instant.
    private func twoBarReveal(_ reveal: FoodOSMoment.Reveal,
                              appeared: Bool) -> some View {
        let maxVal = max(reveal.before, reveal.after, 1)
        let maxBarHeight: CGFloat = 120
        let beforeFull = maxBarHeight * CGFloat(reveal.before / maxVal)
        let afterFull  = maxBarHeight * CGFloat(reveal.after  / maxVal)
        let dropped    = reveal.deltaPercent < 0

        return HStack(alignment: .bottom, spacing: AppSpacing.lg) {
            twoBarColumn(
                target:     reveal.before,
                unit:       reveal.unit,
                valueFont:  .captionStrong,
                valueColor: Color.inkMute,
                barColor:   Color.inkMute.opacity(0.28),
                fullHeight: beforeFull,
                appeared:   appeared,
                label:      "LAST WEEK",
                labelColor: Color.inkMute
            )
            twoBarColumn(
                target:     reveal.after,
                unit:       reveal.unit,
                valueFont:  .title1,
                valueColor: Color.brandDeep,
                barColor:   Color.brand,
                fullHeight: afterFull,
                appeared:   appeared,
                label:      "THIS WEEK",
                labelColor: Color.brandDeep
            )
            deltaPill(percent: reveal.deltaPercent, dropped: dropped)
                .padding(.bottom, 30)
        }
        .frame(height: maxBarHeight + 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            "Last week \(formatBarValue(reveal.before, unit: reveal.unit)), "
            + "this week \(formatBarValue(reveal.after, unit: reveal.unit)), "
            + "\(dropped ? "down" : "up") "
            + "\(abs(reveal.deltaPercent)) percent."
        ))
    }

    /// One column of the two-bar reveal: counting number on top, a
    /// growing rounded bar in the middle, label below. The HStack
    /// containing both columns is `.bottom`-aligned, so animating the
    /// bar's frame height visually rises from the baseline.
    private func twoBarColumn(target: Double,
                              unit: String,
                              valueFont: AppFont.Style,
                              valueColor: Color,
                              barColor: Color,
                              fullHeight: CGFloat,
                              appeared: Bool,
                              label: String,
                              labelColor: Color) -> some View {
        VStack(spacing: AppSpacing.xs) {
            CountingNumber(
                target:       target,
                unit:         unit,
                valueFont:    valueFont,
                valueColor:   valueColor,
                appeared:     appeared,
                reduceMotion: reduceMotion
            )
            UnevenRoundedRectangle(
                topLeadingRadius:     10,
                bottomLeadingRadius:  0,
                bottomTrailingRadius: 0,
                topTrailingRadius:    10,
                style: .continuous
            )
            .fill(barColor)
            .frame(
                height: appeared || reduceMotion
                    ? max(4, fullHeight)
                    : 0
            )
            .animation(
                reduceMotion ? .appReduced : .appMorph.delay(0.15),
                value: appeared
            )
            Text(label)
                .appFont(.labelEyebrow)
                .foregroundStyle(labelColor)
        }
        .frame(maxWidth: .infinity)
    }

    /// Small chip showing the signed percent change. Arrow points down
    /// when the value dropped, up when it climbed. Brand-soft fill keeps
    /// it value-neutral — "dropped" is not framed as bad.
    private func deltaPill(percent: Int, dropped: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: dropped ? "arrow.down" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
            Text("\(abs(percent))%")
                .appFont(.captionStrong)
                .monospacedDigit()
        }
        .foregroundStyle(Color.brandDeep)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.brandSoft)
        )
        .overlay(
            Capsule().strokeBorder(Color.brand.opacity(0.25), lineWidth: 1)
        )
    }

    /// "44g" / "1860kcal" / "18 meals" / "7 foods". Counts read better
    /// with a space before the noun; mass/energy units are typeset
    /// flush to the number per nutrition-label convention.
    private func formatBarValue(_ value: Double, unit: String) -> String {
        let n = Int(value.rounded())
        switch unit {
        case "meals", "foods": return "\(n) \(unit)"
        default:               return "\(n)\(unit)"
        }
    }

    /// Generic large-type "one idea per card" page.
    private func storyHeadlinePage(badge: MirrorBadge,
                                   eyebrow: String,
                                   title: String,
                                   evidence: String?,
                                   appeared: Bool) -> some View {
        var elements: [AnyView] = [
            AnyView(
                Text(title)
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
            )
        ]
        if let evidence {
            elements.append(AnyView(
                Text(evidence)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            ))
        }
        return StoryShell(
            badge: badge,
            eyebrow: eyebrow,
            appeared: appeared,
            reduceMotion: reduceMotion,
            elements: elements
        )
    }

    /// Most-common-foods rendered as a story page. Reuses the bar
    /// visualisation from the inline card but in a more spacious
    /// vertical rhythm to suit a single-idea page.
    ///
    /// Each ranked food row is a separate element so the cascade
    /// counts down the leaderboard: #1 flies in, then #2, then #3.
    /// More satisfying than a single block reveal, and the per-row
    /// bar inside still grows from the `MostCommonFoodBar`'s own
    /// internal animation.
    private func storyMostCommonFoodsPage(
        _ foods: [FoodMirrorSummary.FoodCount],
        appeared: Bool
    ) -> some View {
        let maxCount = max(foods.map { $0.count }.max() ?? 1, 1)
        var elements: [AnyView] = [
            AnyView(
                Text("The meals you keep coming back to.")
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            )
        ]
        for (index, entry) in foods.enumerated() {
            elements.append(AnyView(
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
            ))
        }

        return StoryShell(
            badge: .init(symbol: "fork.knife",
                         tint: .brandDeep, bg: .brandSoft),
            eyebrow: "MOST COMMON FOODS",
            appeared: appeared,
            reduceMotion: reduceMotion,
            elements: elements
        )
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
        case .moodRevelation:
            let moment = viewModel.moodRevelation
            return .init(
                badge: .init(
                    symbol: moment.map(momentBadgeSymbol(for:)) ?? "sparkles",
                    tint: .brandDeep, bg: .brandSoft
                ),
                eyebrow: "MOOD REVELATION",
                shortTitle: moment?.title ?? "A pattern in how meals land."
            )
        case .valueRevelation:
            let moment = viewModel.valueRevelation
            return .init(
                badge: .init(
                    symbol: "chart.line.uptrend.xyaxis",
                    tint: .catBenefitsInk, bg: .catBenefits
                ),
                eyebrow: "WHAT CHANGED",
                shortTitle: moment?.title ?? "A real shift this week."
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

// MARK: - Reflection loader (recap · patterns · coach)

/// Read-only loader for the reflection content shown on Insights — the
/// weekly recap, detected patterns, and the active coach observation. These
/// used to ride along on `TrackerViewModel`; relocating the *display* here
/// keeps "what the app notices" in one tab. Observation *generation* still
/// happens on the Tracker refresh (it writes to the DB); this just reads the
/// stored results, so there's no extra generation work and no new egress
/// beyond the three reads that used to run on Today.
@MainActor
final class ReflectionLoader: ObservableObject {
    @Published private(set) var patterns: [Pattern] = []
    @Published private(set) var activeObservation: CoachObservation?
    @Published private(set) var latestRecap: WeeklyRecap?

    private let history: MealHistoryService
    private let observations: CoachObservationService
    private let recapService: WeeklyRecapService
    private let profileService: ProfileService

    /// Account age (days) below which we don't generate or surface
    /// observations — avoids editorial cards on a brand-new account.
    static let observationMinAccountAgeDays: Int = 3

    init(history: MealHistoryService = MealHistoryService(),
         observations: CoachObservationService = CoachObservationService(),
         recapService: WeeklyRecapService = WeeklyRecapService(),
         profileService: ProfileService = ProfileService.shared) {
        self.history = history
        self.observations = observations
        self.recapService = recapService
        self.profileService = profileService
    }

    func load() async {
        async let inputs: (patterns: [Pattern], logs: [FoodLog])? =
            try? history.reflectionInputsForToday()
        async let o: CoachObservation? = try? observations.todaysObservation()
        async let r: WeeklyRecap? = try? recapService.latest()
        let resolved = await inputs ?? ([], [])
        let observation = await o
        self.patterns = resolved.patterns
        self.activeObservation = observation
        self.latestRecap = await r
        await generateObservationIfNeeded(patterns: resolved.patterns,
                                          logs: resolved.logs,
                                          hasExisting: observation != nil)
    }

    /// Optimistic dismiss — clears locally, restores on failure.
    func dismissObservation() async {
        guard let observation = activeObservation else { return }
        activeObservation = nil
        do {
            try await observations.dismiss(observation.id)
        } catch {
            activeObservation = observation
        }
    }

    /// Best-effort background generation: when there are patterns, no active
    /// card, and the account is past the warmup window, generate a fresh
    /// observation. Dedup guardrails live inside `generateIfNeeded`, so it's
    /// safe to call repeatedly. Relocated here from the Tracker so reflection
    /// loads + generates in exactly one place.
    private func generateObservationIfNeeded(patterns: [Pattern],
                                             logs: [FoodLog],
                                             hasExisting: Bool) async {
        guard !hasExisting else { return }
        let profile = try? await profileService.currentProfile()
        let ageDays = profile.map { Self.daysSince($0.createdAt) } ?? 0
        guard ageDays >= Self.observationMinAccountAgeDays else { return }

        // Multi-day calorie-trend card takes precedence over the editorial
        // pattern card: a sustained drift from the user's goal ("you'll slowly
        // lose on a maintain plan") is more actionable than "you've had pizza a
        // lot", and both share the single daily coach slot. Computed locally
        // (pure) so it's cheap to check before deciding whether to pay the
        // model round-trip the pattern card needs.
        let trendVerdict: CalorieTrendAnalyzer.Verdict? = {
            guard let profile, profile.dailyCalorieGoal > 0 else { return nil }
            let daily = CalorieTrendAnalyzer.loggedDayCalories(from: logs)
            return CalorieTrendAnalyzer.verdict(
                loggedDayCalories: daily,
                goal: Double(profile.dailyCalorieGoal),
                direction: profile.weightGoalDirection
            )
        }()

        guard !patterns.isEmpty || trendVerdict != nil else { return }

        let preferred = profile?.preferredCoaches ?? []
        let observations = self.observations
        let recentMoods = (try? await history.recentMoodsForCoachContext()) ?? []

        Task.detached { [weak self, observations, patterns, preferred, recentMoods, trendVerdict] in
            do {
                // Try the local trend card first; fall back to the server-voiced
                // pattern card when there's no trend (or it was deduped today).
                let generated: CoachObservation?
                if let trendVerdict,
                   let trendCard = try await observations.generateCalorieTrendIfNeeded(
                       verdict: trendVerdict, preferredCoaches: preferred) {
                    generated = trendCard
                } else if !patterns.isEmpty {
                    generated = try await observations.generateIfNeeded(
                        patterns: patterns,
                        preferredCoaches: preferred,
                        recentMoods: recentMoods
                    )
                } else {
                    generated = nil
                }
                if let generated {
                    await MainActor.run { [weak self] in
                        self?.activeObservation = generated
                    }
                }
            } catch {
                #if DEBUG
                NSLog("[Insights] generate observation FAILED: %@", "\(error)")
                #endif
            }
        }
    }

    private static func daysSince(_ date: Date,
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> Int {
        max(calendar.dateComponents([.day], from: date, to: now).day ?? 0, 0)
    }
}



#if DEBUG
#Preview("FoodMirrorView") {
    FoodMirrorView()
}
#endif
