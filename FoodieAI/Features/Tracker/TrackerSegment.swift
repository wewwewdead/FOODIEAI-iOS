import Foundation

/// Three categories the Tracker tab can show:
///   - Today:   the live daily scoreboard (TodayView).
///   - Records: the "how am I doing over time" surface — streak, weekly
///              challenge, 30-day record (RecordsView).
///   - History: past data, with an inner Week/Month toggle (HistoryView).
enum TrackerSegment: String, CaseIterable, Identifiable {
    case today   = "Today"
    case records = "Records"
    case history = "History"

    var id: String { rawValue }
}
