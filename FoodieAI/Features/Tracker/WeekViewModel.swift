import Foundation

/// Drives the Week segment of the Tracker tab. Loads `food_logs` for the
/// week containing the anchor date (in the user's local time zone), buckets
/// them by day, and exposes loading / loaded / failed states.
///
/// The week boundaries come from `Calendar.current.dateInterval(of: .weekOfYear, for:)`,
/// which automatically respects the user's locale (e.g., Sunday-start in
/// the US, Monday-start elsewhere). Always 7 buckets in chronological order.
@MainActor
final class WeekViewModel: ObservableObject {
    enum State {
        case loading
        /// Always 7 buckets. `interval` is the half-open week range used for
        /// the query, kept around for the header's date label.
        case loaded(buckets: [DailyBucket], interval: DateInterval)
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    private let logService: FoodLogService
    private let calendar: Calendar
    private let timeZone: TimeZone

    init(logService: FoodLogService = FoodLogService(),
         calendar: Calendar = .current,
         timeZone: TimeZone = .current) {
        self.logService = logService
        var cal = calendar
        cal.timeZone = timeZone
        self.calendar = cal
        self.timeZone = timeZone
    }

    /// Refresh for the week containing `date` (defaults to now).
    func refresh(for date: Date = Date()) async {
        if case .loaded = state {
            // keep prior data visible during pull-to-refresh
        } else {
            state = .loading
        }

        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            state = .failed(WeekViewError.couldNotResolveWeek)
            return
        }

        do {
            let logs = try await logService.logs(from: interval.start, to: interval.end)
            #if DEBUG
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "MMM d"
            // interval.end is exclusive; subtract one day for human-readable label.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            NSLog("[Week] logs returned %d entries for %@ – %@",
                  logs.count, f.string(from: interval.start), f.string(from: lastDay))
            #endif
            let buckets = DailyBucketing.bucket(
                logs, from: interval.start, to: interval.end, calendar: calendar
            )
            state = .loaded(buckets: buckets, interval: interval)
        } catch {
            #if DEBUG
            NSLog("[Week] refresh FAILED: %@", "\(error)")
            #endif
            state = .failed(error)
        }
    }
}

enum WeekViewError: LocalizedError {
    case couldNotResolveWeek

    var errorDescription: String? {
        switch self {
        case .couldNotResolveWeek: "Couldn't determine the current week."
        }
    }
}
