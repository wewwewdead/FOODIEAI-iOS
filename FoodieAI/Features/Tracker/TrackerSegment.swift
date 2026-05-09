import Foundation

/// Three views the Tracker tab can show. Phase 9 splits the original Tracker
/// into Today (Phase 6 behavior, unchanged), Week (bar chart), and Month
/// (calendar grid).
enum TrackerSegment: String, CaseIterable, Identifiable {
    case today = "Today"
    case week  = "Week"
    case month = "Month"

    var id: String { rawValue }
}
