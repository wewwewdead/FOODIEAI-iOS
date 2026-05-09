import SwiftUI

/// Sheet shown when a Week bar or a Month calendar cell is tapped. Displays
/// totals for the day plus a chronological list of meals with thumbnails.
/// Empty days show a static "No meals logged this day" state — they're still
/// tappable so users get an explicit confirmation rather than a no-op tap.
///
/// Phase 10: meal rows are now expandable inline via the shared `MealRow`
/// component. Tapping a row reveals the saved coach advice and analysis
/// panels (nutrients/benefits/drawbacks) without leaving the sheet.
struct DayDetailSheet: View {
    let bucket: DailyBucket

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                if bucket.hasLogs {
                    totalsBlock
                    mealsList
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.brandCream.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(formattedDate)
                .appFont(.displayMD)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)
            Text(subhead)
                .appFont(.body)
                .foregroundStyle(Color.textMeta)
        }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: bucket.date)
    }

    private var subhead: String {
        bucket.hasLogs
            ? "\(bucket.logs.count) meal\(bucket.logs.count == 1 ? "" : "s") logged"
            : "No meals logged this day"
    }

    // MARK: - Totals

    private var totalsBlock: some View {
        let totals = bucket.totals
        return VStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.lg) {
                totalPill(label: "Calories", value: format(totals.totalCalories), unit: nil)
                Divider().frame(height: 28).foregroundStyle(Color.textMeta.opacity(0.3))
                totalPill(label: "Sugar", value: format(totals.totalSugar), unit: "g")
                Divider().frame(height: 28).foregroundStyle(Color.textMeta.opacity(0.3))
                totalPill(label: "Carbs", value: format(totals.totalCarbs), unit: "g")
            }
            HStack(spacing: AppSpacing.lg) {
                totalPill(label: "Protein", value: format(totals.totalProtein), unit: "g")
                Divider().frame(height: 28).foregroundStyle(Color.textMeta.opacity(0.3))
                totalPill(label: "Fat",     value: format(totals.totalFat),     unit: "g")
                Divider().frame(height: 28).foregroundStyle(Color.textMeta.opacity(0.3))
                totalPill(label: "Fiber",   value: format(totals.totalFiber),   unit: "g")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.brandIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 2)
        )
    }

    private func totalPill(label: String, value: String, unit: String?) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .appFont(.bodyLG)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.brand)
                if let unit {
                    Text(unit)
                        .appFont(.meta)
                        .foregroundStyle(Color.brand)
                }
            }
            Text(label)
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Meals list

    private var mealsList: some View {
        LazyVStack(spacing: AppSpacing.md) {
            ForEach(bucket.logs) { log in
                MealRow(log: log)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.brand.opacity(0.3))
            Text("No meals logged this day")
                .appFont(.body)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textMeta)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.xl3)
    }

    private func format(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

