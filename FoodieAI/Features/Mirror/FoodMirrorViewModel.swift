import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted on the main queue right after a successful `food_logs`
    /// write — insert (analyze save, manual log, quick re-log) or
    /// mood patch on an existing row. FoodMirrorView and the Home
    /// preview both subscribe to this and refresh so Mirror insights
    /// stay live after any change the user makes elsewhere in the app.
    static let foodLogDidChange = Notification.Name("FoodieAI.foodLogDidChange")
}

/// Narrow seam over the food-log read path used by Mirror surfaces.
/// `FoodLogService` conforms; tests inject a stub so view-model
/// behavior (cancellation, refresh tokens, error preservation) is
/// exercisable without a live Supabase client.
protocol FoodLogsFetching: Sendable {
    func logs(from: Date, to: Date) async throws -> [FoodLog]
}

extension FoodLogService: FoodLogsFetching {}

/// View model for the Food Mirror tab. Pulls the user's 7- and 30-day
/// log windows from Supabase via `FoodLogService` and asks the pure
/// `FoodMirrorInsightService` to turn them into a `FoodMirrorSummary`.
///
/// Never talks to Gemini. Never writes anything — read-only enrichment.
///
/// Production-grade refresh behavior:
///   - First refresh with no prior content shows `.loading`.
///   - Refreshes that already have content keep that content visible
///     and flip `isRefreshing` instead, so the page never blanks.
///   - Real failures with prior content preserve the content and
///     surface a non-blocking `refreshErrorMessage` for the view to
///     render as a small banner.
///   - `CancellationError` is treated as a no-op — never surfaced as
///     a failure card or banner.
@MainActor
final class FoodMirrorViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case loaded(FoodMirrorSummary)
        /// Progressive "Mirror is learning" state. Carries the
        /// progress payload so the view can render the headline /
        /// explanation / "X of 8 meals logged" line without going
        /// back to the summary.
        case empty(LearningProgress)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// True while a refresh is in flight *and* we already have prior
    /// content. Drives pull-to-refresh affordances without replacing
    /// the page with a spinner.
    @Published private(set) var isRefreshing: Bool = false

    /// Wall-clock time of the last successful refresh. The view's
    /// freshness caption ("Updated 5 min ago") reads this; nil means
    /// we've never completed a refresh in this session and the line
    /// stays hidden.
    @Published private(set) var lastUpdatedAt: Date?

    /// Non-blocking transient-error message. Set when a refresh fails
    /// but prior content survives; cleared on the next successful
    /// refresh. The view renders this as a small inline banner — the
    /// failed card is reserved for first-load failures.
    @Published private(set) var refreshErrorMessage: String?

    /// The single "FoodOS Moment" the engine chose for this refresh.
    /// Computed from the same logs that produced `state`, so it
    /// reflects the same substrate the rest of the surface does.
    /// Preserved across transient errors and never cleared by
    /// cancellation — only replaced by a fresher successful refresh.
    @Published private(set) var currentMoment: FoodOSMoment?

    /// Feedback the user already tapped against `currentMoment`.
    /// Cleared whenever a new moment replaces the current one so the
    /// chip row reappears for each fresh moment.
    @Published private(set) var lastFeedbackForCurrentMoment: FoodOSMomentFeedback?

    /// Mood-paired-belief revelation as its own card in the deck.
    /// Independent of `currentMoment` and `valueRevelation`: each
    /// appears only when its own signal qualifies, so a flat-mood
    /// user can see the value card without a mood card and vice
    /// versa. Cleared between refreshes when no mood signal qualifies.
    @Published private(set) var moodRevelation: FoodOSMoment?

    /// Week-over-week value revelation (macro / calorie / consistency /
    /// variety). Mood-independent — fires for flat-mood users where
    /// the paired-belief surface stays silent.
    @Published private(set) var valueRevelation: FoodOSMoment?

    /// Per-revelation feedback state. Independent so tapping Helpful
    /// on one card doesn't dismiss the other's chip row.
    @Published private(set) var lastFeedbackForMoodRevelation: FoodOSMomentFeedback?
    @Published private(set) var lastFeedbackForValueRevelation: FoodOSMomentFeedback?

    private let foodLogs: any FoodLogsFetching
    private let feedbackStore: FoodOSMomentFeedbackStore

    /// Per-revelation suppression keys. Tracked separately so the
    /// mood card and value card each refuse to repeat their own
    /// previous subject back-to-back without interfering with each
    /// other.
    private var lastMoodRevelationKey: String?
    private var lastValueRevelationKey: String?

    init(foodLogs: any FoodLogsFetching = FoodLogService(),
         feedbackStore: FoodOSMomentFeedbackStore = .shared) {
        self.foodLogs = foodLogs
        self.feedbackStore = feedbackStore
    }

    /// Monotonic refresh token. Each `refresh()` call captures the
    /// token it started with; if a newer refresh has since begun (or
    /// the task was cancelled), it bails out instead of overwriting
    /// state. Prevents a slow refresh from clobbering a faster newer
    /// one and stops cancelled refreshes from flashing the failed card.
    private var refreshToken: UInt64 = 0

    /// Debounce task fired in response to bursts of `.foodLogDidChange`
    /// notifications. Owned here so the view can hand the timing to
    /// the model without managing a free-floating Task<Void, Never>?.
    private var debounceTask: Task<Void, Never>?
    private var lastSuccessfulRefreshAt: Date?
    private var isDirty: Bool = true
    private let automaticRefreshFreshness: TimeInterval = 25

    /// True when the surface currently has user-facing content we
    /// shouldn't blank out during a refresh. Loading and idle don't
    /// count; failed states do not either (the failed card is itself
    /// an "already showing something" surface, but the spec says
    /// transient errors should only suppress the failed card when
    /// real content is on screen).
    private var hasContent: Bool {
        switch state {
        case .loaded, .empty: return true
        case .idle, .loading, .failed: return false
        }
    }

    /// Refresh the summary. Idempotent; calling while loading is safe
    /// but will simply re-issue the queries. Swift cancellation
    /// (task cancellation, .refreshable abort, tab switch) is treated
    /// as a no-op — never surfaced as a failure to the user.
    @discardableResult
    func refresh(reason: RefreshReason = .pullToRefresh,
                 now: Date = Date(),
                 timeZone: TimeZone = .current,
                 tab: AppTab? = nil) async -> Bool {
        guard shouldRefresh(reason: reason, now: now) else { return false }

        if let tab {
            TabPerformanceProbe.refreshStarted(tab)
        }
        defer {
            if let tab {
                TabPerformanceProbe.refreshEnded(tab)
            }
        }

        #if DEBUG
        let refreshStart = Date()
        defer {
            NSLog("[Perf] FoodMirror refresh %.2fms",
                  Date().timeIntervalSince(refreshStart) * 1000)
        }
        #endif

        refreshToken &+= 1
        let myToken = refreshToken
        let previousState = state
        let hadContent = hasContent

        if hadContent {
            isRefreshing = true
        } else {
            state = .loading
        }

        let (sevenStart, sevenEnd)   = Self.window(daysBack: 7,  now: now, timeZone: timeZone)
        let (thirtyStart, thirtyEnd) = Self.window(daysBack: 30, now: now, timeZone: timeZone)
        // Previous-week window is [-13d, -7d) — the 7-day window
        // immediately before the current one. It always sits inside
        // the 30-day fetch, so we derive it client-side instead of
        // issuing a third query.
        let prevSevenStart = sevenStart.addingTimeInterval(-7 * 24 * 60 * 60)
        let prevSevenEnd   = sevenStart

        do {
            // Issue both queries concurrently — the windows overlap
            // but PostgREST is happier with two narrow ranges than
            // one big one plus client-side filtering.
            async let sevenTask  = foodLogs.logs(from: sevenStart,  to: sevenEnd)
            async let thirtyTask = foodLogs.logs(from: thirtyStart, to: thirtyEnd)

            let sevenLogs  = try await sevenTask
            let thirtyLogs = try await thirtyTask

            if Task.isCancelled || myToken != refreshToken {
                if myToken == refreshToken {
                    state = previousState
                    isRefreshing = false
                }
                return true
            }

            // Slice the previous 7 days from the 30-day pull. No
            // extra round-trip; RLS already scoped both fetches.
            let prevSevenLogs = thirtyLogs.filter {
                $0.eatenAt >= prevSevenStart && $0.eatenAt < prevSevenEnd
            }

            let summary = FoodMirrorInsightService.compute(
                thirtyDayLogs:        thirtyLogs,
                sevenDayLogs:         sevenLogs,
                previousSevenDayLogs: prevSevenLogs,
                now:                  now,
                timeZone:             timeZone
            )

            // Reuse the same three log windows for the FoodOS Moment
            // — no extra Supabase fetches. The engine is pure and
            // synchronous so this adds a few microseconds of CPU at
            // most. Wrapping it in the same token gate as the summary
            // keeps an older slow refresh from clobbering a newer
            // moment.
            // Feed the bandit's learned per-tag preferences into the
            // engine so high-confidence positive/negative feedback
            // can gently shift which moment surfaces first. With an
            // empty store this is a no-op (test #8 in the feedback
            // suite guards that invariant).
            let moment = FoodOSMomentEngine.compute(
                thirtyDayLogs:        thirtyLogs,
                sevenDayLogs:         sevenLogs,
                previousSevenDayLogs: prevSevenLogs,
                now:                  now,
                timeZone:             timeZone,
                preferences:          feedbackStore.preferences,
                lastRevelationRepeatKey: lastMoodRevelationKey
            )

            // Dedicated revelation cards — computed independently from
            // the same log windows. The mood revelation here mirrors
            // whatever the priority chain produced (same suppression
            // key, same `revelationMoment`), so the two stay in lock-
            // step; the value revelation is new and mood-independent.
            let revs = FoodOSMomentEngine.revelations(
                thirtyDayLogs:      thirtyLogs,
                thisWeekLogs:       sevenLogs,
                lastWeekLogs:       prevSevenLogs,
                timeZone:           timeZone,
                now:                now,
                lastMoodRepeatKey:  lastMoodRevelationKey,
                lastValueRepeatKey: lastValueRevelationKey
            )

            guard myToken == refreshToken else { return true }

            if summary.hasEnoughData {
                state = .loaded(summary)
            } else {
                state = .empty(summary.learningProgress)
            }
            // Replacing the moment clears any feedback the user gave
            // against the previous one — chips reappear for the
            // fresh moment.
            if currentMoment != moment {
                lastFeedbackForCurrentMoment = nil
            }
            currentMoment = moment

            if moodRevelation != revs.mood {
                lastFeedbackForMoodRevelation = nil
            }
            if valueRevelation != revs.value {
                lastFeedbackForValueRevelation = nil
            }
            moodRevelation         = revs.mood
            valueRevelation        = revs.value
            lastMoodRevelationKey  = revs.moodRepeatKey
            lastValueRevelationKey = revs.valueRepeatKey
            isRefreshing = false
            lastUpdatedAt = now
            lastSuccessfulRefreshAt = now
            isDirty = false
            refreshErrorMessage = nil
            return true
        } catch is CancellationError {
            if myToken == refreshToken {
                state = previousState
                isRefreshing = false
            }
            return true
        } catch {
            if Task.isCancelled {
                if myToken == refreshToken {
                    state = previousState
                    isRefreshing = false
                }
                return true
            }
            guard myToken == refreshToken else { return true }
            isRefreshing = false
            if hadContent {
                // Keep the previously-loaded surface visible. The
                // banner copy is deliberately warm and never echoes
                // the underlying networking error verbatim.
                state = previousState
                refreshErrorMessage = "Couldn't refresh. Showing your latest saved mirror."
            } else {
                refreshErrorMessage = nil
                state = .failed(error.localizedDescription)
            }
            return true
        }
    }

    func markDirty() {
        isDirty = true
    }

    /// Coalesce bursts of `.foodLogDidChange` notifications into a
    /// single refresh. Save → mood pulse → quick re-log → manual log
    /// can fire in quick succession during one user gesture; without
    /// debouncing we'd start 3-4 overlapping Supabase fetches and
    /// race the last one to commit. ~300ms is short enough to feel
    /// instantaneous, long enough to bundle a chain of writes.
    ///
    /// Pull-to-refresh and the initial `.task` load skip this path
    /// and call `refresh()` directly.
    func scheduleDebouncedRefresh(
        reason: RefreshReason = .foodLogChanged,
        delay: Duration = .milliseconds(300)
    ) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refresh(reason: reason, tab: .mirror)
        }
    }

    /// Cancel any pending debounced refresh. Called when the view
    /// disappears so we don't fire a network request seconds after
    /// the user has navigated away.
    func cancelPendingRefresh() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func shouldRefresh(reason: RefreshReason, now: Date) -> Bool {
        if reason.isUserInitiated || reason == .foodLogChanged || isDirty {
            return true
        }
        guard let lastSuccessfulRefreshAt else { return true }
        return now.timeIntervalSince(lastSuccessfulRefreshAt) >= automaticRefreshFreshness
    }

    /// Record the user's reaction to the current FoodOS Moment.
    /// Writes a local event, updates the per-tag preference, and
    /// flips `lastFeedbackForCurrentMoment` so the card swaps in its
    /// confirmation row. Does not trigger a Supabase refresh — the
    /// bandit gets to influence the *next* natural refresh instead.
    ///
    /// V2: tapping "I'll try this" also arms an active experiment
    /// for the moment's tag. The next mood note the user records
    /// (photo flow or manual log path) resolves the experiment back
    /// into a positive/negative mood-after-try signal, which the
    /// engine can later use to surface a "worked before" moment.
    func recordFeedback(_ feedback: FoodOSMomentFeedback) {
        guard let moment = currentMoment else { return }
        recordFeedback(feedback, for: moment)
    }

    /// Per-moment feedback entry point. The story deck now hosts up
    /// to three rateable moments (currentMoment + moodRevelation +
    /// valueRevelation); each rates against its own tag bucket and
    /// updates its own confirmation row so chips on one card don't
    /// vanish when the user taps a chip on another.
    func recordFeedback(_ feedback: FoodOSMomentFeedback,
                        for moment: FoodOSMoment) {
        feedbackStore.record(feedback: feedback, for: moment)
        if feedback == .willTry {
            feedbackStore.startExperiment(from: moment)
        }
        if moment == currentMoment {
            lastFeedbackForCurrentMoment = feedback
        }
        if moment == moodRevelation {
            lastFeedbackForMoodRevelation = feedback
        }
        if moment == valueRevelation {
            lastFeedbackForValueRevelation = feedback
        }
    }

    /// Returns `[start, end)` where `end` is exclusive, both expressed
    /// in the user's local calendar. The 30-day window is "today plus
    /// the previous 29 days" — i.e., logs from 30 distinct calendar
    /// days ending at the end of today, local.
    static func window(daysBack: Int,
                       now: Date,
                       timeZone: TimeZone) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfToday = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: startOfToday) ?? startOfToday
        return (start, end)
    }
}
