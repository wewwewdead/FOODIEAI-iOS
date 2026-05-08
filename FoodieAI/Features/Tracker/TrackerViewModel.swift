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

    private let logService: FoodLogService
    private let timeZone: TimeZone

    init(logService: FoodLogService = FoodLogService(),
         timeZone: TimeZone = .current) {
        self.logService = logService
        self.timeZone = timeZone
    }

    func refresh() async {
        // Don't flash `.loading` over an existing loaded state — pull-to-refresh
        // should keep the rows visible while the new fetch is in flight.
        if case .loaded = state {
            // keep showing prior data until the new query settles
        } else {
            state = .loading
        }

        do {
            let logs = try await logService.todaysLogs(timeZone: timeZone)
            #if DEBUG
            NSLog("[Tracker] todaysLogs returned %d entries (tz=%@)",
                  logs.count, timeZone.identifier)
            #endif
            if logs.isEmpty {
                state = .empty
            } else {
                state = .loaded(logs: logs, totals: LocalDailyTotals.sum(logs))
            }
        } catch {
            #if DEBUG
            NSLog("[Tracker] refresh FAILED: %@", "\(error)")
            #endif
            state = .failed(error)
        }
    }
}
