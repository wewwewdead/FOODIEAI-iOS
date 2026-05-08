import SwiftUI

/// Daily Tracker tab. Layout per DESIGN_SYSTEM.md §DailyTracker, mobile
/// stacked: a brand→brandBright gradient header card with today's date and
/// summed totals, an overlaid "resets at 12:00 am" reminder badge in the
/// bottom-leading corner, and a list of today's saved meals below.
///
/// Data is fetched on appear and on pull-to-refresh; the v1 sync model is
/// "switching to the tab refreshes" — accepting a brief flicker on tab
/// switch in exchange for not plumbing a shared event publisher.
struct TrackerView: View {
    @StateObject private var viewModel = TrackerViewModel()

    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    headerCard
                    body(for: viewModel.state)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xl3)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
        .task {
            await viewModel.refresh()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Today, \(formattedDate())")
                .appFont(.displayMD)
                .fontWeight(.heavy)
                .foregroundStyle(.white)

            totalsBlock

            // Web layout absolute-positions this in the bottom-left corner;
            // on mobile the totals + badge stack vertically inside the card
            // to avoid overlap with the macros lines.
            BouncingBadge(
                text: "Daily tracker resets every 12:00 am",
                style: .reminder
            )
            .padding(.top, AppSpacing.xs)
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
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var totalsBlock: some View {
        switch viewModel.state {
        case .loading:
            // Placeholder dashes while loading; keeps the header height stable.
            totals(calories: nil, sugar: nil, carbs: nil)
        case .empty:
            totals(calories: 0, sugar: 0, carbs: 0)
        case .loaded(_, let totals):
            self.totals(calories: totals.totalCalories,
                        sugar: totals.totalSugar,
                        carbs: totals.totalCarbs)
        case .failed:
            totals(calories: nil, sugar: nil, carbs: nil)
        }
    }

    private func totals(calories: Double?, sugar: Double?, carbs: Double?) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Text(format(calories))
                    .appFont(.kcal)
                    .fontWeight(.black)
                    .foregroundStyle(.white)
                Text("total calories")
                    .appFont(.body)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text("Total sugar: \(format(sugar))g")
                .appFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Total carbs: \(format(carbs))g")
                .appFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Body switch

    @ViewBuilder
    private func body(for state: TrackerViewModel.State) -> some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(Color.brand)
                .padding(.top, AppSpacing.xl3)
        case .empty:
            VStack(spacing: AppSpacing.sm) {
                Text("No data yet!")
                    .appFont(.body)
                    .foregroundStyle(Color.textMeta)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, AppSpacing.xl3)
        case .loaded(let logs, _):
            VStack(spacing: AppSpacing.lg) {
                ForEach(Array(logs.enumerated()), id: \.element.id) { idx, log in
                    EntryCard(log: log)
                        .transition(.opacity)
                        .animation(
                            .easeInOut(duration: 0.5).delay(Double(idx) * 0.2),
                            value: logs.count
                        )
                }
            }
        case .failed(let error):
            VStack(spacing: AppSpacing.md) {
                Text("Couldn't load today's meals")
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

    // MARK: - Formatting helpers

    private func formattedDate(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM d"
        return f.string(from: date)
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

/// Single saved-meal card. brandIvory background, lg radius, md padding.
/// Renders timestamp (h:mm a), food name as a subhead, and the three macros.
private struct EntryCard: View {
    let log: FoodLog

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(timestamp(log.eatenAt))
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)

            Text(log.foodName)
                .appFont(.bodyLG)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Calories: \(format(log.calories))")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
                Text("Sugar: \(format(log.sugarG))g")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
                Text("Carbs: \(format(log.carbsG))g")
                    .appFont(.body)
                    .foregroundStyle(Color.textBody)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.brandIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 2)
        )
    }

    private func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func format(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}

#if DEBUG
#Preview("TrackerView — loading") {
    TrackerView()
}
#endif
