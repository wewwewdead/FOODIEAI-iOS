import Foundation
import HealthKit

// Reads today's step count straight from HealthKit, from *inside* the widget
// extension. This is the piece that keeps the Daily Loop's step ring moving
// even when the app has been force-quit: WidgetKit reloads the timeline on its
// own schedule, in its own process, independent of the app's lifecycle — and
// each reload calls this. The app-side `WidgetSnapshotUpdater` path only runs
// while the app is alive, so without this the ring freezes the moment the user
// swipes the app away.
//
// The widget CANNOT prompt for HealthKit access — an extension can't present
// the permission sheet. It relies entirely on the containing app having been
// authorized once (see `HealthActivityService.requestAuthorization`). The app
// and this extension share the same App Group + team, so that grant carries to
// the widget. If read access was never granted, the query returns no data and
// `todaySteps` yields nil (the caller then falls back to the last snapshot).
enum WidgetHealthSteps {
    private static let store = HKHealthStore()

    /// Today's cumulative step total for the device's local day, or nil when
    /// HealthKit is unavailable / unauthorized / has no samples yet. The
    /// completion is ALWAYS invoked exactly once so `getTimeline` never hangs.
    static func todaySteps(timeZone: TimeZone = .current,
                           completion: @escaping (Int?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            completion(nil)
            return
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate)

        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, stats, _ in
            let steps = stats?.sumQuantity()?.doubleValue(for: .count())
            completion(steps.map { Int($0) })
        }
        store.execute(query)
    }
}
