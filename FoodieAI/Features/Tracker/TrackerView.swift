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
    let isActive: Bool

    @StateObject private var todayVM = TrackerViewModel()
    @StateObject private var weekVM  = WeekViewModel()
    @StateObject private var monthVM = MonthViewModel()

    @State private var segment: TrackerSegment = .today
    /// Tracks the segment we're transitioning *from*, for asymmetric
    /// directional intelligence.
    @State private var previousSegment: TrackerSegment = .today

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

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
            case .today:   TodayView(viewModel: todayVM, isActive: isActive)
            case .records: RecordsView(viewModel: todayVM, isActive: isActive)
            case .history: HistoryView(weekVM: weekVM, monthVM: monthVM,
                                       isActive: isActive)
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
        case .today:   0
        case .records: 1
        case .history: 2
        }
    }
}

// MARK: - History (Week / Month, with an inner toggle)

/// Hosts the two history views behind a sub-segment toggle. Keeps the
/// top-level Tracker segments to three clear categories while preserving the
/// existing Week bar chart and Month calendar untouched.
struct HistoryView: View {
    @ObservedObject var weekVM: WeekViewModel
    @ObservedObject var monthVM: MonthViewModel
    let isActive: Bool

    @State private var mode: Mode = .week

    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case week  = "Week"
        case month = "Month"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSegmentedControl<Mode>(
                selection: $mode,
                titleProvider: { $0.rawValue }
            )
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.sm)

            Group {
                switch mode {
                case .week:  WeekView(viewModel: weekVM, isActive: isActive)
                case .month: MonthView(viewModel: monthVM, isActive: isActive)
                }
            }
            .id(mode)
            .transition(.opacity)
            .animation(.appReduced, value: mode)
        }
    }
}

#if DEBUG
#Preview("TrackerView — segmented") {
    TrackerView()
        .environmentObject(ProfileStore())
}
#endif
