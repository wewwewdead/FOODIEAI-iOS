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
///
/// Phase 13: segment switching uses an asymmetric directional transition
/// (Today→Week→Month slides in from trailing; reverse slides in from
/// leading) under `.appSegmentSwitch`. Selection-change haptic fires once
/// per user-driven change.
struct TrackerView: View {
    @StateObject private var todayVM = TrackerViewModel()
    @StateObject private var weekVM  = WeekViewModel()
    @StateObject private var monthVM = MonthViewModel()

    @State private var segment: TrackerSegment = .today
    /// Tracks the segment we're transitioning *from*, for asymmetric
    /// directional intelligence.
    @State private var previousSegment: TrackerSegment = .today

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                segmentedHeader
                content
            }
        }
    }

    private var segmentedHeader: some View {
        AppSegmentedControl<TrackerSegment>(
            selection: $segment,
            titleProvider: { $0.rawValue }
        )
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
        .onChange(of: segment) { oldValue, _ in
            previousSegment = oldValue
            // Haptics fire inside AppSegmentedControl's tap handler.
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch segment {
            case .today: TodayView(viewModel: todayVM)
            case .week:  WeekView(viewModel: weekVM)
            case .month: MonthView(viewModel: monthVM)
            }
        }
        .id(segment)
        .transition(transition(forwards: forwards))
        .animation(.appSegmentSwitch, value: segment)
    }

    /// True when moving forward through the segment order
    /// (today → week → month). Drives directional slide.
    private var forwards: Bool {
        segment.orderIndex >= previousSegment.orderIndex
    }

    private func transition(forwards: Bool) -> AnyTransition {
        let insertEdge: Edge = forwards ? .trailing : .leading
        let removeEdge: Edge = forwards ? .leading  : .trailing
        return .asymmetric(
            insertion: .move(edge: insertEdge).combined(with: .opacity),
            removal:   .move(edge: removeEdge).combined(with: .opacity)
        )
    }
}

private extension TrackerSegment {
    var orderIndex: Int {
        switch self {
        case .today: 0
        case .week:  1
        case .month: 2
        }
    }
}

#if DEBUG
#Preview("TrackerView — segmented") {
    TrackerView()
        .environmentObject(ProfileStore())
}
#endif
