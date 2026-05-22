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

    /// Wrapped-style story carousel state. Lives in this view because
    /// the pages are derived from the loaded summary + currentMoment,
    /// both of which already sit on this view's view model.
    @State private var storyIndex: Int = 0
    /// Wall-clock instant the current story page was first shown.
    /// Drives both the progress-bar fill (via a TimelineView scoped
    /// to the bar) and the elapsed-time auto-advance check, so we
    /// no longer need a 20Hz @State double thrashing the whole view.
    @State private var currentCardStartedAt: Date = Date()
    /// When the user pauses auto-advance (e.g. by tapping a feedback
    /// chip), we record how far the progress had got so the bar
    /// freezes at that fill instead of continuing to tick visually.
    /// nil = not paused; non-nil = bar frozen at this elapsed time.
    @State private var pausedAtElapsed: TimeInterval? = nil
    /// Latched true once the user interacts with the moment's
    /// feedback chips. Pauses auto-advance so they can sit on that
    /// card and read the confirmation; resets on manual page change.
    @State private var storyPaused: Bool = false
    /// Namespace for the album → expanded-card matchedGeometryEffect
    /// transition. Declared once on the view so both the thumbnail
    /// and the overlay can attach to the same identifier.
    @Namespace private var albumNamespace
    /// Which page (if any) the user has expanded out of the album
    /// grid. nil means the album is showing its thumbnail grid; a
    /// non-nil value shows that page full-size as an overlay.
    @State private var expandedCard: StoryPageKind? = nil
    /// Low-frequency auto-advance ticker. Stored as `static let` so
    /// there is exactly ONE publisher for the lifetime of the type —
    /// a stored `let` on the struct (or a computed property) would be
    /// re-created on every body re-evaluation, which used to leak a
    /// new autoconnected timer per redraw and caused progressively
    /// worsening lag. Frequency is intentionally coarse (0.25s):
    /// the smooth bar fill is driven by a TimelineView scoped to the
    /// bar, so this ticker only has to decide *whether* to advance.
    private static let storyTicker = Timer.publish(
        every: 0.25,
        on: .main,
        in: .common
    ).autoconnect()
    private static let storyAdvanceDuration: Double = 6.0

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
            // Treat each state transition as a fresh "card start" so
            // the first loaded card always gets a full advance window
            // — otherwise the timer would be measuring against view
            // construction time and could skip the first card.
            currentCardStartedAt = Date()
            pausedAtElapsed = nil
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
        .onReceive(Self.storyTicker) { _ in
            advanceStoryTick()
        }
        .onDisappear {
            viewModel.cancelPendingRefresh()
        }
    }

    /// Checks the elapsed time on the current story card and advances
    /// when it crosses the duration threshold. No-op when paused, in
    /// Reduce Motion, while a card is expanded out of the album, or
    /// when there's no story content. The smooth bar fill is owned by
    /// the TimelineView inside `storyProgressBars` — this function
    /// only decides *whether* to flip to the next card.
    private func advanceStoryTick() {
        guard !reduceMotion, !storyPaused else { return }
        guard expandedCard == nil else { return }
        guard case .loaded(let summary) = viewModel.state,
              summary.hasAnyContent else { return }
        let pageCount = storyPageKinds(for: summary).count
        guard pageCount > 0, storyIndex < pageCount - 1 else { return }
        let elapsed = Date().timeIntervalSince(currentCardStartedAt)
        if elapsed >= Self.storyAdvanceDuration {
            advanceStoryCard(by: 1, pageCount: pageCount, animated: true)
        }
    }

    /// Latch auto-advance and freeze the progress bar at the current
    /// elapsed position, so a feedback tap doesn't make the bar keep
    /// ticking visually while the carousel sits still.
    private func pauseAutoAdvance() {
        let elapsed = Date().timeIntervalSince(currentCardStartedAt)
        pausedAtElapsed = min(max(elapsed, 0), Self.storyAdvanceDuration)
        storyPaused = true
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
        // Wrapped-style story experience: the same cards that used to
        // stack as a scroll are now paged horizontally with auto-
        // advancing progress bars at the top. The hero header above
        // stays put; the tab bar below stays visible — the story is a
        // contained "stage," not a full-screen takeover.
        //
        // The learning-state fallback (when we're in `.loaded` but the
        // summary has nothing content-bearing to say) keeps the
        // existing card aesthetic — story mode only kicks in when
        // there's enough to actually narrate.
        if summary.hasAnyContent {
            storyContainer(for: summary)
                .transition(staggeredTransition(for: 0))
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                quickStatsStrip(for: summary)
                    .transition(staggeredTransition(for: 0))
                learningStateCard(summary.learningProgress)
                    .transition(staggeredTransition(for: 1))
            }
        }
    }

    // MARK: - Story container (Wrapped-style paged cards)

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

    /// Fixed-height contained "stage" that hosts the story pages.
    /// Sits inside the regular page padding so the hero header above
    /// and the tab bar below remain visible — this is NOT full-screen.
    private func storyContainer(for summary: FoodMirrorSummary) -> some View {
        let pages = storyPageKinds(for: summary)
        let pageCount = pages.count
        let clampedIndex = min(max(storyIndex, 0), max(pageCount - 1, 0))

        return VStack(spacing: AppSpacing.sm) {
            storyProgressBars(
                count: pageCount,
                current: clampedIndex
            )
            .padding(.horizontal, AppSpacing.md)
            .padding(.top, AppSpacing.md)

            GeometryReader { geo in
                TabView(selection: $storyIndex) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) {
                        index, kind in
                        storyPageView(kind, summary: summary)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.bottom, AppSpacing.lg)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // SpatialTapGesture attached to the TabView itself
                // (the parent of every card's content). With the
                // default `.gesture` priority, child Buttons — like
                // the moment's feedback chips — consume their own
                // taps first; only taps on non-interactive parts of
                // a card fall through to this gesture.
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            if event.location.x < geo.size.width * 0.4 {
                                advanceStoryCard(by: -1,
                                                 pageCount: pageCount,
                                                 animated: true)
                            } else {
                                advanceStoryCard(by: 1,
                                                 pageCount: pageCount,
                                                 animated: true)
                            }
                        }
                )
            }

            if pageCount > 0,
               clampedIndex == pageCount - 1,
               pages[clampedIndex] != .album {
                storyEndCaption
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.sm)
                    .transition(.opacity)
            }
        }
        .frame(height: 500)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.bgSurface,
                            Color.brandSoft.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.brand.opacity(0.18), lineWidth: 1)
        )
        .overlay(expandedCardOverlay(summary: summary))
        .appShadow(.shadowCard)
        .onChange(of: storyIndex) { _, _ in
            // Restart the per-card clock so the new card gets a
            // full advance window and the bar starts empty. The
            // TimelineView inside storyProgressBars reads this and
            // resets its periodic schedule automatically.
            currentCardStartedAt = Date()
            pausedAtElapsed = nil
            storyPaused = false
            // Any page change (including swiping back off the
            // album) collapses an expanded card so the overlay
            // never strands itself over the wrong page.
            if expandedCard != nil { expandedCard = nil }
        }
        .onChange(of: pageCount) { _, newCount in
            if storyIndex >= newCount {
                storyIndex = max(newCount - 1, 0)
            }
        }
    }

    /// Subtle "you're all caught up" affordance shown on the last page
    /// so the user understands auto-advance has stopped on purpose.
    private var storyEndCaption: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandDeep.opacity(0.75))
            Text("You're all caught up.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Story: progress bars

    /// Instagram-style segmented progress row. The high-frequency
    /// fill animation is owned by a TimelineView scoped to just this
    /// subtree, so the surrounding view (hero, blobs, story content)
    /// never re-evaluates body for the bar tick — only the bar does.
    /// Progress is derived from elapsed time, not from an @State
    /// counter, so there's nothing to drift or accumulate.
    private func storyProgressBars(count: Int,
                                   current: Int) -> some View {
        TimelineView(.periodic(from: currentCardStartedAt, by: 0.05)) { context in
            let progress: Double = {
                if reduceMotion { return 0 }
                if let frozen = pausedAtElapsed {
                    return min(frozen / Self.storyAdvanceDuration, 1.0)
                }
                let elapsed = context.date.timeIntervalSince(currentCardStartedAt)
                return min(max(elapsed, 0) / Self.storyAdvanceDuration, 1.0)
            }()
            HStack(spacing: 4) {
                ForEach(0..<max(count, 1), id: \.self) { i in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.brand.opacity(0.18))
                            Capsule()
                                .fill(Color.brandDeep)
                                .frame(
                                    width: storyBarFill(
                                        for: i,
                                        current: current,
                                        progress: progress,
                                        total: geo.size.width
                                    )
                                )
                        }
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func storyBarFill(for index: Int,
                              current: Int,
                              progress: Double,
                              total: CGFloat) -> CGFloat {
        if index < current { return total }
        if index > current { return 0 }
        if reduceMotion {
            // Without auto-advance, just show the current segment as
            // a thin chevron-style marker so users still see which
            // page they're on.
            return max(8, total * 0.15)
        }
        return total * CGFloat(max(0.0, min(progress, 1.0)))
    }

    // MARK: - Story: navigation

    /// Steps the carousel by +1 or -1 with bounds. Stops at the last
    /// card (no infinite loop) and clamps at zero on back-tap from
    /// the first card. Resets per-page progress so the bar restarts
    /// for the new page; clears the paused-by-feedback latch.
    private func advanceStoryCard(by delta: Int,
                                  pageCount: Int,
                                  animated: Bool) {
        guard pageCount > 0 else { return }
        let target = storyIndex + delta
        let clamped = min(max(target, 0), pageCount - 1)
        if clamped == storyIndex { return }
        Haptics.tap()
        if animated && !reduceMotion {
            withAnimation(.motionBase) { storyIndex = clamped }
        } else {
            storyIndex = clamped
        }
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
            storyAlbumPage(summary)
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
                            // Latch the carousel so it doesn't slide
                            // out from under the user mid-read, and
                            // freeze the progress bar at its current
                            // fill instead of letting it tick on.
                            pauseAutoAdvance()
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

    /// Terminal recap page. A header + 2-column grid of compact
    /// thumbnails, one per content card seen in the story. Tapping
    /// any thumbnail expands it into a full-size overlay via
    /// `matchedGeometryEffect`; tapping the dim background or the
    /// expanded card collapses it back to the grid.
    private func storyAlbumPage(_ summary: FoodMirrorSummary) -> some View {
        let contentPages = storyPageKinds(for: summary).filter { $0 != .album }

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
                        albumThumbnail(kind, summary: summary)
                            .matchedGeometryEffect(
                                id: kind.id,
                                in: albumNamespace
                            )
                            .contentShape(
                                RoundedRectangle(cornerRadius: AppRadius.lg)
                            )
                            .onTapGesture {
                                Haptics.tap()
                                pauseAutoAdvance()
                                if reduceMotion {
                                    expandedCard = kind
                                } else {
                                    withAnimation(
                                        .spring(response: 0.4,
                                                dampingFraction: 0.82)
                                    ) {
                                        expandedCard = kind
                                    }
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(
                                Text(albumCardMeta(kind, summary: summary).eyebrow)
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
        .frame(maxWidth: .infinity,
               maxHeight: .infinity,
               alignment: .topLeading)
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

    /// Full-size overlay shown while `expandedCard` is non-nil.
    /// Attached to the story container so it stays bounded inside
    /// the 500pt stage (no full-screen escape). The matched
    /// geometry id is the page kind's rawValue so the expansion
    /// reads as the thumbnail growing into the card.
    @ViewBuilder
    private func expandedCardOverlay(summary: FoodMirrorSummary) -> some View {
        if let kind = expandedCard, kind != .album {
            ZStack {
                Color.black.opacity(0.18)
                    .clipShape(
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                    )
                    .onTapGesture {
                        collapseExpandedCard()
                    }
                    .transition(.opacity)

                storyPageView(kind, summary: summary)
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 420)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                            .fill(Color.bgSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                            .strokeBorder(Color.brand.opacity(0.22),
                                          lineWidth: 1)
                    )
                    .appShadow(.shadowFloating)
                    .matchedGeometryEffect(
                        id: kind.id,
                        in: albumNamespace
                    )
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.xl)
                    .onTapGesture {
                        collapseExpandedCard()
                    }
                    .accessibilityAddTraits(.isModal)
            }
            .transition(.opacity)
        }
    }

    /// Collapse helper used by both the dim background and the
    /// expanded card itself. Centralises the animation choice so
    /// the spring matches what played on expand.
    private func collapseExpandedCard() {
        Haptics.tap()
        if reduceMotion {
            expandedCard = nil
        } else {
            withAnimation(
                .spring(response: 0.4, dampingFraction: 0.82)
            ) {
                expandedCard = nil
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
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
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

#if DEBUG
#Preview("FoodMirrorView") {
    FoodMirrorView()
}
#endif
