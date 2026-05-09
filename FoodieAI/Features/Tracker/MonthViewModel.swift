import Foundation

/// Drives the Month segment of the Tracker tab. Loads logs for the calendar
/// month containing `anchor`, buckets them by local day, and supports
/// previous/next-month navigation.
///
/// `next` is gated so the user can't browse into the future — there's no
/// data, and rendering disabled cells still beats a confusing blank view.
@MainActor
final class MonthViewModel: ObservableObject {
    enum State {
        case loading
        case loaded(buckets: [DailyBucket], monthInterval: DateInterval)
        case failed(Error)
    }

    @Published private(set) var state: State = .loading
    /// Any date inside the displayed month. Mutated by goToPrevious/Next.
    @Published private(set) var anchor: Date = Date()

    private let logService: FoodLogService
    private let calendar: Calendar

    init(logService: FoodLogService = FoodLogService(),
         calendar: Calendar = .current,
         timeZone: TimeZone = .current) {
        self.logService = logService
        var cal = calendar
        cal.timeZone = timeZone
        self.calendar = cal
    }

    /// Refresh for the month containing `anchor`.
    func refresh() async {
        if case .loaded = state {
            // keep prior data visible during pull-to-refresh
        } else {
            state = .loading
        }

        guard let interval = calendar.dateInterval(of: .month, for: anchor) else {
            state = .failed(MonthViewError.couldNotResolveMonth)
            return
        }

        do {
            let logs = try await logService.logs(from: interval.start, to: interval.end)
            #if DEBUG
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "MMM yyyy"
            NSLog("[Month] logs returned %d entries for %@",
                  logs.count, f.string(from: interval.start))
            #endif
            let buckets = DailyBucketing.bucket(
                logs, from: interval.start, to: interval.end, calendar: calendar
            )
            state = .loaded(buckets: buckets, monthInterval: interval)
        } catch {
            #if DEBUG
            NSLog("[Month] refresh FAILED: %@", "\(error)")
            #endif
            state = .failed(error)
        }
    }

    func goToPreviousMonth() async {
        guard let prev = calendar.date(byAdding: .month, value: -1, to: anchor) else { return }
        anchor = prev
        await refresh()
    }

    /// Disabled if it would advance past the current month.
    func goToNextMonth() async {
        guard !isCurrentMonth, let next = calendar.date(byAdding: .month, value: 1, to: anchor) else { return }
        anchor = next
        await refresh()
    }

    var isCurrentMonth: Bool {
        guard let anchorMonth = calendar.dateInterval(of: .month, for: anchor),
              let nowMonth    = calendar.dateInterval(of: .month, for: Date()) else {
            return true // fail safe: treat as current to disable next nav
        }
        return anchorMonth.start == nowMonth.start
    }
}

enum MonthViewError: LocalizedError {
    case couldNotResolveMonth

    var errorDescription: String? {
        switch self {
        case .couldNotResolveMonth: "Couldn't determine the displayed month."
        }
    }
}
