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
    //
    // Granny Smith treatment, mirroring WeekView: single-hue vertical
    // brandBright→brand wash, deep-green ink on chartreuse, ivory chevron
    // pills for month nav, and the shared MacroGlassChip strip at the
    // foot. Month-specific bits: the nav row carries the chevrons and a
    // days-logged pill; the headline is "Month YYYY".

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

        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.brandBright, Color.brand],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .strokeBorder(Color.brandDeep.opacity(0.12), lineWidth: 1.5)
                .frame(width: 360, height: 360)
                .offset(x: 200, y: -150)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                // 1. Nav row — [<] [days-pill] [>]
                HStack(spacing: 10) {
                    chevronButton(systemName: "chevron.left",
                                  action: { Task { await viewModel.goToPreviousMonth() } },
                                  enabled: true,
                                  label: "Previous month")

                    Spacer()

                    Text("\(loggedDays) of \(totalDays) logged")
                        .font(.custom(AppFont.PS.nunitoExtraBold, size: 11))
                        .tracking(0.4)
                        .foregroundStyle(Color.greenCalorie)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.brandIvory))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.brandDeep.opacity(0.12),
                                              lineWidth: 0.75)
                        )

                    Spacer()

                    chevronButton(systemName: "chevron.right",
                                  action: { Task { await viewModel.goToNextMonth() } },
                                  enabled: !viewModel.isCurrentMonth,
                                  label: "Next month")
                }

                Spacer().frame(height: 16)

                // 2. Month + year — anchor headline.
                Text(monthYearLabel(interval: interval))
                    .font(.custom(AppFont.PS.mplusExtraBold, size: 36))
                    .kerning(-0.5)
                    .foregroundStyle(Color.brandDeep)

                Spacer().frame(height: 18)

                // 3. Hero kcal number.
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    AnimatedNumber(
                        value: totals.totalCalories,
                        formatter: AnimatedNumber.integerFormatter
                    )
                    .font(.custom(AppFont.PS.mplusBlack, size: 68))
                    .kerning(-2.5)
                    .foregroundStyle(Color.greenCalorie)

                    Text("kcal")
                        .font(.custom(AppFont.PS.nunitoExtraBold, size: 16))
                        .foregroundStyle(Color.brandDeep.opacity(0.70))
                        .padding(.bottom, 10)
                }

                Spacer().frame(height: 6)

                // 4. Subtitle — avg / day.
                HStack(spacing: 7) {
                    Text("avg")
                        .foregroundStyle(Color.brandDeep.opacity(0.65))
                    AnimatedNumber(value: avg,
                                   formatter: AnimatedNumber.integerFormatter)
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.greenCalorie)
                    Text("kcal / day")
                        .foregroundStyle(Color.brandDeep.opacity(0.65))
                }
                .font(.custom(AppFont.PS.nunitoSemiBold, size: 13))

                Spacer().frame(height: 22)

                // 5. Macro chip strip — shared with WeekView.
                HStack(spacing: 6) {
                    MacroGlassChip(label: "CARBS",   value: totals.totalCarbs)
                    MacroGlassChip(label: "SUGAR",   value: totals.totalSugar)
                    MacroGlassChip(label: "PROTEIN", value: totals.totalProtein)
                    MacroGlassChip(label: "FAT",     value: totals.totalFat)
                    MacroGlassChip(label: "FIBER",   value: totals.totalFiber)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.brandDeep.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.brand.opacity(0.28), radius: 16, x: 0, y: 10)
    }

    /// Circular ivory chevron button used by the month nav. Disabled
    /// state fades both the glyph and the fill so the next-month button
    /// reads as inert on the current month without disappearing.
    private func chevronButton(systemName: String,
                               action: @escaping () -> Void,
                               enabled: Bool,
                               label: String) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.brandDeep.opacity(enabled ? 1.0 : 0.35))
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(Color.brandIvory.opacity(enabled ? 1.0 : 0.6))
                )
                .overlay(
                    Circle().strokeBorder(Color.brandDeep.opacity(0.12),
                                          lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Calendar grid

    private func calendarCard(buckets: [DailyBucket], interval: DateInterval) -> some View {
        let cells = monthGridCells(buckets: buckets, interval: interval)
        let columns = Array(repeating: GridItem(.flexible(), spacing: AppSpacing.xs), count: 7)

        return VStack(spacing: AppSpacing.sm) {
            // Weekday header row, rotated by Calendar.firstWeekday.
            HStack(spacing: AppSpacing.xs) {
                ForEach(Array(orderedWeekdaySymbols().enumerated()), id: \.offset) { _, sym in
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
