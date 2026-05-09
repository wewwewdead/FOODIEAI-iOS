import SwiftUI

/// Tracker tab host. Phase 9 introduces a segmented control with three views:
///   - Today: Phase 6 behavior (TodayView).
///   - Week:  bar chart of daily calories for the current week (WeekView).
///   - Month: calendar grid with logged days highlighted (MonthView).
///
/// Each segment owns its own view model so its data can survive segment
/// switching and refresh independently. Switching to the tab triggers
/// `.task` on the active segment's view, which re-fetches — accepting a
/// brief flicker on segment switch in exchange for not plumbing a shared
/// save-event publisher (matches the Phase 6 v1 sync model).
struct TrackerView: View {
    @StateObject private var todayVM = TrackerViewModel()
    @StateObject private var weekVM  = WeekViewModel()
    @StateObject private var monthVM = MonthViewModel()

    @State private var segment: TrackerSegment = .today

    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()

            VStack(spacing: 0) {
                segmentedHeader
                content
            }
        }
    }

    private var segmentedHeader: some View {
        Picker("View", selection: $segment) {
            ForEach(TrackerSegment.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .today: TodayView(viewModel: todayVM)
        case .week:  WeekView(viewModel: weekVM)
        case .month: MonthView(viewModel: monthVM)
        }
    }
}

#if DEBUG
#Preview("TrackerView — segmented") {
    TrackerView()
}
#endif
