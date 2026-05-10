import SwiftUI

/// Month segment of the Tracker tab. Brand-gradient header card with month
/// name + prev/next nav, monthly totals, then a 7-column calendar grid where
/// logged days are tinted brand and today's cell is outlined.
struct MonthView: View {
    @ObservedObject var viewModel: MonthViewModel
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
            // Phase 13: skeleton header + 7×5 calendar grid.
            VStack(spacing: AppSpacing.lg) {
                SkeletonShape(cornerRadius: AppRadius.lg)
                    .frame(height: 220)
                MonthGridSkeleton()
                    .padding(AppSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(Color.bgSurface)
                    )
            }
        case .loaded(let buckets, let interval):
            headerCard(buckets: buckets, interval: interval)
            calendarCard(buckets: buckets, interval: interval)
        case .failed(let error):
            VStack(spacing: AppSpacing.md) {
                Text("Couldn't load this month")
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

    // MARK: - Header

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
        let totalDays = buckets.count
        let avg: Double = loggedDays > 0
            ? (totals.totalCalories / Double(loggedDays)).rounded()
            : 0

        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Button {
                    Haptics.tap()
                    Task { await viewModel.goToPreviousMonth() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(AppSpacing.sm)
                        .background(Circle().fill(.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous month")

                Spacer(minLength: 0)

                Text(monthYearLabel(interval: interval))
                    .appFont(.displayMD)
                    .fontWeight(.heavy)
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                Button {
                    Haptics.tap()
                    Task { await viewModel.goToNextMonth() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white.opacity(viewModel.isCurrentMonth ? 0.35 : 1.0))
                        .padding(AppSpacing.sm)
                        .background(Circle().fill(.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCurrentMonth)
                .accessibilityLabel("Next month")
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    AnimatedNumber(value: totals.totalCalories,
                                   formatter: AnimatedNumber.integerFormatter)
                        .font(AppFont.font(.kcal))
                        .fontWeight(.black)
                        .foregroundStyle(.white)
                    Text("calories this month")
                        .appFont(.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("Average: \(format(avg)) cal/day")
                    .appFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("Logged \(loggedDays)/\(totalDays) days")
                    .appFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Group {
                    TotalLine(label: "Total carbs",   value: totals.totalCarbs)
                    TotalLine(label: "Total sugar",   value: totals.totalSugar)
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

    // MARK: - Calendar grid

    private func calendarCard(buckets: [DailyBucket], interval: DateInterval) -> some View {
        let cells = monthGridCells(buckets: buckets, interval: interval)
        let columns = Array(repeating: GridItem(.flexible(), spacing: AppSpacing.xs), count: 7)

        return VStack(spacing: AppSpacing.sm) {
            // Weekday header row, rotated by Calendar.firstWeekday.
            HStack(spacing: AppSpacing.xs) {
                ForEach(orderedWeekdaySymbols(), id: \.self) { sym in
                    Text(sym)
                        .appFont(.meta)
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.textMeta)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: AppSpacing.xs) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    cellView(cell)
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

    @ViewBuilder
    private func cellView(_ cell: MonthGridCell) -> some View {
        switch cell {
        case .padding:
            Color.clear
                .frame(height: 48)
        case .day(let bucket, let isToday, let isFuture):
            Button {
                guard !isFuture else { return }
                Haptics.selection()
                selectedBucket = bucket
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(cellFill(bucket: bucket, isFuture: isFuture))
                    if isToday {
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .strokeBorder(Color.brand, lineWidth: 2)
                    }
                    Text(dayNumber(bucket.date))
                        .appFont(.body)
                        .fontWeight(.heavy)
                        .foregroundStyle(isFuture ? Color.textMeta.opacity(0.5) : Color.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if bucket.hasLogs {
                        Text("\(bucket.logs.count)")
                            .appFont(.meta)
                            .foregroundStyle(Color.greenAnalysis)
                            .opacity(0.6)
                            .padding(4)
                    }
                }
                .frame(height: 48)
            }
            .buttonStyle(CalendarCellButtonStyle())
            .disabled(isFuture)
            .accessibilityLabel(accessibilityLabel(for: bucket, isFuture: isFuture))
        }
    }

    private func cellFill(bucket: DailyBucket, isFuture: Bool) -> Color {
        if isFuture { return Color.bgSurface.opacity(0.5) }
        return bucket.hasLogs ? Color.brand.opacity(0.4) : Color.bgSurface
    }

    // MARK: - Grid math

    private enum MonthGridCell {
        case padding
        case day(bucket: DailyBucket, isToday: Bool, isFuture: Bool)
    }

    private func monthGridCells(buckets: [DailyBucket], interval: DateInterval) -> [MonthGridCell] {
        guard let firstDay = buckets.first?.date else { return [] }
        // Leading padding: number of empty slots before day 1 of the month,
        // determined by how far the month's first day is from firstWeekday.
        let weekday = calendar.component(.weekday, from: firstDay)
        let firstWeekday = calendar.firstWeekday
        let leading = (weekday - firstWeekday + 7) % 7

        let now = Date()
        let today = calendar.startOfDay(for: now)

        var cells: [MonthGridCell] = Array(repeating: .padding, count: leading)
        for bucket in buckets {
            let isToday = calendar.isDate(bucket.date, inSameDayAs: today)
            let isFuture = bucket.date > today
            cells.append(.day(bucket: bucket, isToday: isToday, isFuture: isFuture))
        }
        // Trailing padding to fill the final row to a multiple of 7.
        let remainder = cells.count % 7
        if remainder != 0 {
            cells.append(contentsOf: Array(repeating: .padding, count: 7 - remainder))
        }
        return cells
    }

    private func orderedWeekdaySymbols() -> [String] {
        // Calendar.shortWeekdaySymbols is Sunday-first; rotate by firstWeekday.
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        guard first >= 0, first < symbols.count else { return symbols }
        return Array(symbols[first...] + symbols[..<first])
    }

    // MARK: - Formatting helpers

    private func monthYearLabel(interval: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM yyyy"
        return f.string(from: interval.start)
    }

    private func dayNumber(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private func accessibilityLabel(for bucket: DailyBucket, isFuture: Bool) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .full
        let dateStr = f.string(from: bucket.date)
        if isFuture { return dateStr }
        if bucket.hasLogs {
            return "\(dateStr), \(bucket.logs.count) meal\(bucket.logs.count == 1 ? "" : "s") logged"
        }
        return "\(dateStr), no meals"
    }

    private func format(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

/// Phase 13: subtle press feedback for calendar cells. The default
/// `.buttonStyle(.plain)` on a tappable rounded rect gives no visual cue
/// that the tap registered; this scales the cell down to 0.92 on press.
struct CalendarCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}
