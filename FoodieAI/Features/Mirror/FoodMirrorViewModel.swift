import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted on the main queue right after a successful `food_logs`
    /// insert (analyze save, manual log, or quick re-log). FoodMirrorView
    /// subscribes to this and triggers a refresh so the tab feels live
    /// after the user logs a meal anywhere else in the app.
    ///
    /// Deliberately not posted for mood updates — mood patches an
    /// existing row, doesn't change the 7d/30d log count, and the
    /// dominant-mood thresholds rarely shift on a single label.
    static let foodLogDidChange = Notification.Name("FoodieAI.foodLogDidChange")
}

/// View model for the Food Mirror tab. Pulls the user's 7- and 30-day
/// log windows from Supabase via `FoodLogService` and asks the pure
/// `FoodMirrorInsightService` to turn them into a `FoodMirrorSummary`.
///
/// Never talks to Gemini. Never writes anything — read-only enrichment.
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

    private let foodLogs: FoodLogService

    init(foodLogs: FoodLogService = FoodLogService()) {
        self.foodLogs = foodLogs
    }

    /// Refresh the summary. Idempotent; calling while loading is safe
    /// but will simply re-issue the queries.
    func refresh(now: Date = Date(),
                 timeZone: TimeZone = .current) async {
        state = .loading

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

            if summary.hasEnoughData {
                state = .loaded(summary)
            } else {
                state = .empty(summary.learningProgress)
            }
        } catch {
            state = .failed(error.localizedDescription)
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
