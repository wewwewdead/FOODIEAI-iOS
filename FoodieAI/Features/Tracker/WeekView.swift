import SwiftUI
import Charts

/// Week segment of the Tracker tab. Renders a brand→brandBright gradient
/// header card with the week's date range and weekly totals, followed by a
/// 7-day bar chart of daily calories.
///
/// Tap-to-open: rather than wiring `chartOverlay` + `DragGesture` + proxy.value
/// (which is fiddly across iOS 17 SDK revisions), we render a row of seven
/// tappable day cells *below* the chart. Each cell shows the weekday letter
/// and is more discoverable than an in-chart tap target. The cells double as
/// the X-axis label row, so we strip the chart's own X-axis labels to avoid
/// duplication. (Decision documented in PHASE_9_VERIFICATION.md.)
struct WeekView: View {
    @ObservedObject var viewModel: WeekViewModel
    @State private var selectedBucket: DailyBucket?

    private let calendar: Calendar = {
        var c = Calendar.current
        c.timeZone = .current
        return c
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                content
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .refreshable { await viewModel.refresh() }
        .task { await viewModel.refresh() }
        .sheet(item: $selectedBucket) { bucket in
            DayDetailSheet(bucket: bucket, onDeleted: {
                Task { await viewModel.refresh() }
            })
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            // Phase 13: skeleton header card + chart placeholder.
            VStack(spacing: AppSpacing.lg) {
                SkeletonShape(cornerRadius: AppRadius.lg)
                    .frame(height: 220)
                SkeletonShape(cornerRadius: AppRadius.lg)
                    .frame(height: 280)
            }
        case .loaded(let buckets, let interval):
            headerCard(buckets: buckets, interval: interval)
            chartCard(buckets: buckets)
        case .failed(let error):
            VStack(spacing: AppSpacing.md) {
                Text("Couldn't load this week")
                    .appFont(.displayMD)
                    .foregroundStyle(Color.redError)
                    .multilineTextAlignment(.center)
                Text(error.localizedDescription)
                    .appFont(.meta)
                    .foregroundStyle(Color.textMeta)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try again", variant: .outline) {
                    Task { await viewModel.refresh() }
                }
                .padding(.top, AppSpacing.sm)
            }
            .padding(.top, AppSpacing.xl)
        }
    }

    // MARK: - Header card

    private func headerCard(buckets: [DailyBucket], interval: DateInterval) -> some View {
        let totals = buckets.reduce(into: LocalDailyTotals.empty) { acc, b in
            acc.entries       += b.totals.entries
            acc.totalCalories += b.totals.totalCalories
            acc.totalCarbs    += b.totals.totalCarbs
            acc.totalSugar    += b.totals.totalSugar
            acc.totalProtein  += b.totals.totalProtein
            acc.totalFat      += b.totals.totalFat
            acc.totalFiber    += b.totals.totalFiber
        }
        let loggedDays = buckets.filter { $0.hasLogs }.count
        let avg: Double = loggedDays > 0
            ? (totals.totalCalories / Double(loggedDays)).rounded()
            : 0

        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(weekRangeLabel(interval: interval))
                .appFont(.displayMD)
                .fontWeight(.heavy)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    AnimatedNumber(value: totals.totalCalories,
                                   formatter: AnimatedNumber.integerFormatter)
                        .font(AppFont.font(.kcal))
                        .fontWeight(.black)
                        .foregroundStyle(.white)
                    Text("calories this week")
                        .appFont(.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("Average: \(format(avg)) cal/day across \(loggedDays) day\(loggedDays == 1 ? "" : "s")")
                    .appFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Group {
                    TotalLine(label: "Total sugar",   value: totals.totalSugar)
                    TotalLine(label: "Total carbs",   value: totals.totalCarbs)
                    TotalLine(label: "Total protein", value: totals.totalProtein)
                    TotalLine(label: "Total fat",     value: totals.totalFat)
                    TotalLine(label: "Total fiber",   value: totals.totalFiber)
                }
                .font(AppFont.font(.body))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(
                    LinearGradient(
                        colors: [.brand, .brandBright],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
        )
    }

    // MARK: - Chart card

    private func chartCard(buckets: [DailyBucket]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Daily calories")
                .appFont(.bodyLG)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)

            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Day", bucket.date, unit: .day),
                    y: .value("Calories", bucket.totals.totalCalories)
                )
                .foregroundStyle(Color.brand)
                .opacity(bucket.hasLogs ? 1.0 : 0.3)
                .cornerRadius(4)
            }
            .chartXAxis(.hidden) // replaced by tappable day-cell row below
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.textMeta.opacity(0.2))
                    AxisValueLabel()
                        .font(AppFont.font(.meta))
                        .foregroundStyle(Color.textMeta)
                }
            }
            .frame(height: 200)

            // Tappable day cells — also serve as the X-axis label row.
            HStack(spacing: AppSpacing.xs) {
                ForEach(buckets) { bucket in
                    dayCell(for: bucket)
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 2)
        )
    }

    private func dayCell(for bucket: DailyBucket) -> some View {
        let isToday = calendar.isDateInToday(bucket.date)
        return Button {
            selectedBucket = bucket
        } label: {
            VStack(spacing: 2) {
                Text(weekdayLetter(bucket.date))
                    .appFont(.meta)
                    .fontWeight(.heavy)
                    .foregroundStyle(isToday ? Color.brand : Color.textMeta)
                Text(dayNumber(bucket.date))
                    .appFont(.meta)
                    .foregroundStyle(Color.textMeta)
                    .opacity(0.8)
                if bucket.hasLogs {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 4, height: 4)
                } else {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(isToday ? Color.brand.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: bucket))
    }

    // MARK: - Formatting helpers

    private func weekRangeLabel(interval: DateInterval) -> String {
        let endInclusive = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let monthFmt = DateFormatter()
        monthFmt.locale = .current
        monthFmt.dateFormat = "MMM"
        let dayFmt = DateFormatter()
        dayFmt.locale = .current
        dayFmt.dateFormat = "d"

        let startMonth = monthFmt.string(from: interval.start)
        let endMonth   = monthFmt.string(from: endInclusive)
        let startDay   = dayFmt.string(from: interval.start)
        let endDay     = dayFmt.string(from: endInclusive)

        if startMonth == endMonth {
            return "\(startMonth) \(startDay)–\(endDay)"
        } else {
            return "\(startMonth) \(startDay) – \(endMonth) \(endDay)"
        }
    }

    private func weekdayLetter(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEEE" // narrow: S M T W T F S
        return f.string(from: date)
    }

    private func dayNumber(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private func accessibilityLabel(for bucket: DailyBucket) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .full
        let dateStr = f.string(from: bucket.date)
        if bucket.hasLogs {
            return "\(dateStr), \(format(bucket.totals.totalCalories)) calories"
        } else {
            return "\(dateStr), no meals logged"
        }
    }

    private func format(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}
