import Foundation

/// Tiny, Codable snapshot the app writes to a shared App Group container so
/// the home-screen widget can render the daily loop without its own network
/// access. Dependency-free (Foundation only) on purpose so the SAME file
/// compiles into both the app and the widget-extension targets.
///
/// See `WIDGET_SETUP.md` for the one-time Xcode setup (App Group capability +
/// widget target) this depends on.
struct WidgetSnapshot: Codable, Equatable {
    var streakDays: Int
    var caloriesConsumed: Int
    var calorieGoal: Int
    var steps: Int
    var stepGoal: Int
    var updatedAt: Date
    /// Pre-computed coach line from the app: burn-off ("a 15-min walk evens it
    /// out") when over, eat-to-goal ("room for a balanced meal") when under.
    /// Optional + last so old cached snapshots still decode.
    var suggestion: String? = nil

    static let empty = WidgetSnapshot(
        streakDays: 0, caloriesConsumed: 0, calorieGoal: 0,
        steps: 0, stepGoal: 0, updatedAt: Date(timeIntervalSince1970: 0)
    )

    /// Fraction of the calorie goal consumed, clamped to 0…1 for the ring.
    var calorieProgress: Double {
        guard calorieGoal > 0 else { return 0 }
        return min(max(Double(caloriesConsumed) / Double(calorieGoal), 0), 1)
    }

    /// True when this snapshot was captured during `date`'s local day. The
    /// per-day figures (steps, calories consumed) only describe the day they
    /// were written; once the day rolls over they must read 0 until the app
    /// writes fresh numbers. Uses the device's current calendar/timezone so the
    /// boundary is local midnight.
    func isFromSameDay(as date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(updatedAt, inSameDayAs: date)
    }

    /// A view of this snapshot for rendering at `date`. If the snapshot is from
    /// an earlier day, the daily progress (steps + calories consumed + the
    /// coach line that was computed from them) resets to 0/nil while the
    /// carry-over fields (streak, goals) stay. This is what makes the widget —
    /// and any same-day app fallback — zero out at local midnight even when the
    /// app isn't opened.
    func rolledOver(to date: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        guard !isFromSameDay(as: date, calendar: calendar) else { return self }
        var copy = self
        copy.caloriesConsumed = 0
        copy.steps = 0
        copy.suggestion = nil
        return copy
    }
}

/// Shared constants + read/write helpers for the App Group bridge. The app
/// writes (see `WidgetSnapshotUpdater`); the widget reads. Both reference the
/// same suite name, which MUST match the App Group added in Xcode for BOTH
/// the app and the widget extension targets.
enum WidgetBridge {
    /// CHANGE THIS to match the App Group id you create in Signing &
    /// Capabilities (identical string on both targets). `UserDefaults(suiteName:)`
    /// returns nil until that capability exists, so everything below no-ops
    /// harmlessly before setup.
    static let appGroupID = "group.com.thefoodieai.app"
    static let snapshotKey = "widget.snapshot.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Persist the latest snapshot. No-op when the App Group isn't configured.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Read the latest snapshot, or `.empty` when none / not configured.
    static func read() -> WidgetSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snap
    }
}
