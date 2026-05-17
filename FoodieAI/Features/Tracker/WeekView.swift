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
            chartCard(buckets: buckets, interval: interval)
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
    //
    // "Granny Smith" treatment: single-hue vertical wash from brandBright
    // into brand, with deep-green ink for headline + hero number. Dark
    // type on chartreuse delivers the contrast that white-on-green was
    // missing, while staying entirely within the existing brand palette.
    // One soft ring outline bleeds off the upper-right for depth without
    // creating a competing hotspot.

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

        return ZStack(alignment: .topLeading) {
            // Single-hue vertical wash — top brandBright fades into brand
            // at the foot. Same family, no color clash, no hotspot.
            LinearGradient(
                colors: [Color.brandBright, Color.brand],
                startPoint: .top,
                endPoint: .bottom
            )

            // One thin ring outline bleeding off the top-right. Drawn in
            // brandDeep at low opacity so it reads as a tonal texture
            // against the chartreuse, not a competing visual.
            Circle()
                .strokeBorder(Color.brandDeep.opacity(0.12), lineWidth: 1.5)
                .frame(width: 360, height: 360)
                .offset(x: 200, y: -150)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                // 1. Eyebrow row + days-logged pill
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.brandDeep)
                            .frame(width: 6, height: 6)
                        Text("THIS WEEK")
                            .font(.custom(AppFont.PS.nunitoExtraBold, size: 11))
                            .tracking(2.5)
                            .foregroundStyle(Color.brandDeep.opacity(0.78))
                    }
                    Spacer()
                    Text("\(loggedDays) of 7 logged")
                        .font(.custom(AppFont.PS.nunitoExtraBold, size: 11))
                        .tracking(0.4)
                        .foregroundStyle(Color.greenCalorie)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.brandIvory)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.brandDeep.opacity(0.12),
                                              lineWidth: 0.75)
                        )
                }

                Spacer().frame(height: 16)

                // 2. Date range — the section's anchor headline.
                Text(weekRangeLabel(interval: interval))
                    .font(.custom(AppFont.PS.mplusExtraBold, size: 36))
                    .kerning(-0.5)
                    .foregroundStyle(Color.brandDeep)

                Spacer().frame(height: 18)

                // 3. Hero kcal number — one statistic, dominant scale,
                //    rendered in the deepest brand green for max read.
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

                // 4. Avg / day · days-logged subtitle.
                HStack(spacing: 7) {
                    Text("avg")
                        .foregroundStyle(Color.brandDeep.opacity(0.65))
                    AnimatedNumber(value: avg,
                                   formatter: AnimatedNumber.integerFormatter)
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.greenCalorie)
                    Text("kcal / day")
                        .foregroundStyle(Color.brandDeep.opacity(0.65))
                    Circle()
                        .fill(Color.brandDeep.opacity(0.35))
                        .frame(width: 3, height: 3)
                    Text("\(loggedDays) day\(loggedDays == 1 ? "" : "s") logged")
                        .foregroundStyle(Color.brandDeep.opacity(0.80))
                }
                .font(.custom(AppFont.PS.nunitoSemiBold, size: 13))

                Spacer().frame(height: 22)

                // 5. Macro chip strip — 5 across, ivory cards, equal flex.
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

    // MARK: - Chart card

    private func chartCard(buckets: [DailyBucket], interval: DateInterval) -> some View {
        // Pin the X domain to the full week so bars align with the 7-cell
        // day-label row below — otherwise Charts auto-fits the domain to the
        // observed data range, and a partial week (e.g. Sun–Wed) spreads its
        // bars across the entire plot width.
        let xDomain = interval.start ... interval.end

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
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
            .chartXScale(domain: xDomain)
            .chartXAxis {
                // Day-of-week labels rendered natively by Charts so they're
                // automatically aligned to each bar — avoids measuring the
                // plot area via @State (which triggers per-frame update
                // warnings inside chartOverlay's layout pass).
                AxisMarks(values: buckets.map(\.date)) { value in
                    AxisValueLabel(centered: true) {
                        if let d = value.as(Date.self),
                           let bucket = buckets.first(where: { calendar.isDate($0.date, inSameDayAs: d) }) {
                            dayLabel(for: bucket)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.textMeta.opacity(0.2))
                    AxisValueLabel()
                        .font(AppFont.font(.meta))
                        .foregroundStyle(Color.textMeta)
                }
            }
            .frame(height: 220)
            .chartOverlay { proxy in
                // Tap regions aligned to the plot area inside the same
                // GeometryReader evaluation — no @State, no preferences,
                // so nothing is written back into layout per frame.
                GeometryReader { geo in
                    let frame = geo[proxy.plotAreaFrame]
                    HStack(spacing: 0) {
                        ForEach(buckets) { bucket in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { selectedBucket = bucket }
                                .accessibilityLabel(accessibilityLabel(for: bucket))
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
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

    private func dayLabel(for bucket: DailyBucket) -> some View {
        let isToday = calendar.isDateInToday(bucket.date)
        return VStack(spacing: 2) {
            Text(weekdayLetter(bucket.date))
                .appFont(.meta)
                .fontWeight(.heavy)
                .foregroundStyle(isToday ? Color.brand : Color.textMeta)
            Text(dayNumber(bucket.date))
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
                .opacity(0.8)
            Circle()
                .fill(bucket.hasLogs ? Color.brand : Color.clear)
                .frame(width: 4, height: 4)
        }
        .padding(.vertical, 2)
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

// MARK: - MacroGlassChip
//
// Ivory pill that sits on the brand-chartreuse hero card. Eyebrow label
// at the top in muted brandDeep, value below in greenCalorie. The chip
// has a fixed minHeight so 1-digit and 3-digit values share the same
// row height; numeric Text uses lineLimit + minimumScaleFactor so
// 3-digit values like "191g" stay on one line even at narrow widths.
//
// Shared with MonthView — both hero cards render the same 5-macro strip.
struct MacroGlassChip: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom(AppFont.PS.nunitoExtraBold, size: 9))
                .tracking(1.4)
                .foregroundStyle(Color.brandDeep.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.80)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                AnimatedNumber(value: value,
                               formatter: AnimatedNumber.integerFormatter)
                    .font(.custom(AppFont.PS.nunitoExtraBold, size: 17))
                    .foregroundStyle(Color.greenCalorie)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("g")
                    .font(.custom(AppFont.PS.nunitoBold, size: 10))
                    .foregroundStyle(Color.brandDeep.opacity(0.55))
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.brandIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.brandDeep.opacity(0.10), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(value.rounded())) grams")
    }
}

