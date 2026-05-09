import SwiftUI

/// Today segment of the Tracker tab — Phase 6 behavior, unchanged.
/// Layout per DESIGN_SYSTEM.md §DailyTracker: brand→brandBright gradient
/// header card with today's date and summed totals, an overlaid
/// "resets at 12:00 am" reminder badge in the bottom-leading corner, and a
/// list of today's saved meals below.
struct TodayView: View {
    @ObservedObject var viewModel: TrackerViewModel

    var body: some View {
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
            totals(calories: nil, sugar: nil, carbs: nil,
                   protein: nil, fat: nil, fiber: nil)
        case .empty:
            totals(calories: 0, sugar: 0, carbs: 0,
                   protein: 0, fat: 0, fiber: 0)
        case .loaded(_, let totals):
            self.totals(calories: totals.totalCalories,
                        sugar:    totals.totalSugar,
                        carbs:    totals.totalCarbs,
                        protein:  totals.totalProtein,
                        fat:      totals.totalFat,
                        fiber:    totals.totalFiber)
        case .failed:
            totals(calories: nil, sugar: nil, carbs: nil,
                   protein: nil, fat: nil, fiber: nil)
        }
    }

    private func totals(calories: Double?, sugar: Double?, carbs: Double?,
                        protein: Double?, fat: Double?, fiber: Double?) -> some View {
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
            Text("Total protein: \(format(protein))g")
                .appFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Total fat: \(format(fat))g")
                .appFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Total fiber: \(format(fiber))g")
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
                    MealRow(log: log)
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

