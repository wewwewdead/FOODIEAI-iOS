import Foundation

/// Drives the Tracker tab: loads today's `food_logs` for the signed-in user
/// (in their local time zone, per Phase 0 Q2), computes totals, and surfaces
/// loading / empty / loaded / failed states.
///
/// Refresh policy: caller invokes `refresh()` from `.task` on appear and from
/// `.refreshable` (pull-to-refresh). v1 doesn't subscribe to a save-event
/// publisher; switching to the tab always re-fetches, accepting a brief
/// flicker on tab switch in exchange for not having to plumb a shared
/// `EnvironmentObject`.
@MainActor
final class TrackerViewModel: ObservableObject {
    enum State {
        case loading
        case empty
        case loaded(logs: [FoodLog], totals: LocalDailyTotals)
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    /// Phase 15 — observations surfaced under "PATTERNS" on the Today
    /// screen. Loaded alongside today's logs by `refresh()`. Empty
    /// array (the default) hides the section entirely; we never
    /// manufacture filler.
    @Published private(set) var patterns: [Pattern] = []

    /// Phase 16 — active coach observation card for the Today screen.
    /// `nil` means no card to render (no patterns, dismissed, or the
    /// account is too new — see `accountAgeDays` guard in `refresh`).
    @Published private(set) var activeObservation: CoachObservation? = nil

    /// Phase 17 — most recent weekly recap, used to render the
    /// "This week" affordance on Today. `nil` until we've generated
    /// at least one recap. Loaded alongside today's logs but never
    /// blocks the refresh path.
    @Published private(set) var latestRecap: WeeklyRecap? = nil

    private let logService: FoodLogService
    private let history: MealHistoryService
    private let observations: CoachObservationService
    private let profileService: ProfileService
    private let recapService: WeeklyRecapService
    private let timeZone: TimeZone

    /// Re-entrancy guard. `refresh()` is called from `.task` and
    /// `.refreshable`; rapid tab switches + pull-to-refresh can stack
    /// concurrent requests against the same Supabase session. Drop the
    /// duplicate rather than racing two writes into `state`.
    private var isRefreshing = false

    /// Phase 16. Account age threshold (in days) below which we don't
    /// generate or surface observations. Avoids pre-loading editorial
    /// cards onto a fresh account before the user has earned any
    /// patterns. Exposed for tests.
    static let observationMinAccountAgeDays: Int = 3

    init(logService: FoodLogService = FoodLogService(),
         history: MealHistoryService = MealHistoryService(),
         observations: CoachObservationService = CoachObservationService(),
         profileService: ProfileService = ProfileService(),
         recapService: WeeklyRecapService = WeeklyRecapService(),
         timeZone: TimeZone = .current) {
        self.logService = logService
        self.history = history
        self.observations = observations
        self.profileService = profileService
        self.recapService = recapService
        self.timeZone = timeZone
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Don't flash `.loading` over an existing loaded state — pull-to-refresh
        // should keep the rows visible while the new fetch is in flight.
        if case .loaded = state {
            // keep showing prior data until the new query settles
        } else {
            state = .loading
        }

        // Run today's logs, pattern detection, the active-observation
        // lookup, and the latest-recap lookup in parallel. Each
        // side-channel is wrapped in `try?` so a single failure doesn't
        // poison the whole tracker view.
        async let logsTask = logService.todaysLogs(timeZone: timeZone)
        async let patternsTask: [Pattern]? = try? history.patternsForToday()
        async let observationTask: CoachObservation? = try? observations.todaysObservation()
        async let latestRecapTask: WeeklyRecap? = try? recapService.latest()

        do {
            let logs = try await logsTask
            let resolvedPatterns = await patternsTask ?? []
            let observation = await observationTask

            #if DEBUG
            NSLog("[Tracker] todaysLogs=%d patterns=%d activeObservation=%@ (tz=%@)",
                  logs.count, resolvedPatterns.count,
                  observation?.id.uuidString ?? "<nil>",
                  timeZone.identifier)
            #endif

            self.patterns = resolvedPatterns
            self.activeObservation = observation
            self.latestRecap = await latestRecapTask
            if logs.isEmpty {
                state = .empty
            } else {
                state = .loaded(logs: logs, totals: LocalDailyTotals.sum(logs))
            }

            // If there's no card today AND we have patterns, kick off a
            // best-effort generation in the background. Wrapped in
            // Task.detached so the view can finish rendering without
            // waiting on the model round-trip; the new card lands on
            // the next refresh.
            await scheduleObservationGenerationIfNeeded(
                patterns: resolvedPatterns,
                hasExisting: observation != nil
            )
        } catch is CancellationError {
            // SwiftUI cancelled `.task` (segment switch / tab churn).
            // Leave `state` and side-channel arrays alone — a follow-up
            // refresh will reconcile. Painting `.failed(CancellationError)`
            // here would flash a fake error banner.
            return
        } catch {
            #if DEBUG
            NSLog("[Tracker] refresh FAILED: %@", "\(error)")
            #endif
            // Preserve whatever side-channel results came back so the
            // observation/patterns sections don't flash empty just
            // because today's-logs failed.
            self.patterns = await patternsTask ?? []
            self.activeObservation = await observationTask
            self.latestRecap = await latestRecapTask
            state = .failed(error)
        }
    }

    /// Delete a saved meal (DB row + storage objects), then refresh so
    /// the totals/ring/macro bars settle to the new state. Errors are
    /// surfaced via the standard `.failed` state by way of `refresh()`
    /// re-running on the next pull-to-refresh; we don't currently
    /// alert here because deletion is initiated from a confirmation
    /// dialog, which is its own commitment surface.
    func deleteLog(_ log: FoodLog) async {
        do {
            try await logService.delete(log)
        } catch {
            #if DEBUG
            NSLog("[Tracker] delete FAILED for %@: %@",
                  log.id.uuidString, "\(error)")
            #endif
        }
        await refresh()
    }

    /// Phase 16. Mark the active observation as dismissed and clear it
    /// from the view. Local clear is optimistic — if the network call
    /// fails the next refresh will re-surface the card.
    func dismissActiveObservation() async {
        guard let observation = activeObservation else { return }
        self.activeObservation = nil
        do {
            try await observations.dismiss(observation.id)
        } catch {
            #if DEBUG
            NSLog("[Tracker] dismiss FAILED for %@: %@",
                  observation.id.uuidString, "\(error)")
            #endif
            // Restore so the user can retry; refresh will reconcile.
            self.activeObservation = observation
        }
    }

    // MARK: - Observation generation orchestration

    /// Decides whether to fire a background generate. Keeps the policy
    /// in one place so the verification doc has a single rule to point
    /// at: "generate when there are patterns, no active card today,
    /// and the account is past the warmup window."
    private func scheduleObservationGenerationIfNeeded(patterns: [Pattern],
                                                       hasExisting: Bool) async {
        guard !hasExisting else { return }
        guard !patterns.isEmpty else { return }

        // Account age guard. Pulling profile inline keeps this honest —
        // we only generate after the user has lived in the app long
        // enough to have some context for the coach to speak about.
        let profile = try? await profileService.currentProfile()
        let ageDays = profile.map { Self.daysSince($0.createdAt) } ?? 0
        guard ageDays >= Self.observationMinAccountAgeDays else {
            #if DEBUG
            NSLog("[Tracker] skip generate — account age %d < %d days",
                  ageDays, Self.observationMinAccountAgeDays)
            #endif
            return
        }

        let preferred = profile?.preferredCoaches ?? []
        let observations = self.observations
        // Phase 18 — gather mood context alongside; failure is silent
        // and resolves to an empty array (the empty-array path keeps
        // the request body byte-identical to Phase-16 shape).
        let recentMoods = (try? await history.recentMoodsForCoachContext()) ?? []

        // Detached Task — fire-and-forget. The dedup guardrails inside
        // generateIfNeeded keep this safe to call repeatedly.
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let generated = try await observations.generateIfNeeded(
                    patterns: patterns,
                    preferredCoaches: preferred,
                    recentMoods: recentMoods
                )
                if let generated {
                    await MainActor.run {
                        // Surface the new card in place — no need for a
                        // second tab visit. The detached generation
                        // races completion with whatever the user is
                        // doing now; if they've already dismissed an
                        // older card mid-flight, prefer the freshly
                        // generated one.
                        self.activeObservation = generated
                    }
                }
            } catch {
                #if DEBUG
                NSLog("[Tracker] generateIfNeeded FAILED: %@", "\(error)")
                #endif
            }
        }
    }

    private static func daysSince(_ date: Date,
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.day], from: date, to: now)
        return max(comps.day ?? 0, 0)
    }
}
