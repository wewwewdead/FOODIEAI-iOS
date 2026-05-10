import SwiftUI

/// Phase 15 — Quick Re-log picker.
///
/// Presented from CaptureView's "pick from recent meals" affordance.
/// Lists the user's recent unique meals (deduplicated by food name,
/// newest instance per name) so re-logging the morning oatmeal or the
/// daily lunch is a single tap with no photo round-trip.
///
/// Empty state: "No saved meals yet" with a quiet illustration. New
/// users will hit this until they've completed at least one analyze
/// → save flow.
///
/// Tap-to-pick semantics: the sheet calls `onPicked(log)` and dismisses
/// itself synchronously. The actual `food_logs` insert is the parent's
/// responsibility (`CaptureViewModel.relog(_:)`) so the parent owns the
/// success/failure toast.
struct RecentMealsSheet: View {
    /// Caller-provided handler. The sheet dismisses itself via the
    /// environment's `dismiss` immediately after invoking this; the
    /// network insert happens after dismissal.
    let onPicked: (FoodLog) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = RecentMealsViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Re-log a meal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .background(Color.bgCanvas)
                .task { await vm.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            VStack(spacing: AppSpacing.md) {
                ProgressView().tint(Color.brand)
                Text("Loading your meals…")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            emptyState

        case .loaded(let meals):
            list(meals)

        case .failed(let error):
            failedState(error)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.inkLight)
            Text("No saved meals yet")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            Text("Save a meal first — it'll show up here for one-tap re-logging.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ error: Error) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.error.opacity(0.85))
            Text("Couldn't load your meals")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            Text(error.localizedDescription)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
            PrimaryButton(title: "Try again",
                          leadingSystemImage: "arrow.clockwise") {
                Task { await vm.load() }
            }
            .padding(.top, AppSpacing.sm)
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ meals: [FoodLog]) -> some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                ForEach(meals) { log in
                    MealCard(log: log) {
                        Haptics.tap()
                        onPicked(log)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl2)
        }
    }
}

/// View model for the picker. Owned by the sheet only — torn down on
/// dismiss, since the data is small and refreshing on each open is
/// cheap and avoids stale "recent" lists after multiple saves.
@MainActor
final class RecentMealsViewModel: ObservableObject {
    enum State {
        case loading
        case empty
        case loaded([FoodLog])
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    private let history: MealHistoryService

    init(history: MealHistoryService = MealHistoryService()) {
        self.history = history
    }

    func load() async {
        state = .loading
        do {
            let meals = try await history.recentUniqueMeals(limit: 12)
            state = meals.isEmpty ? .empty : .loaded(meals)
        } catch {
            state = .failed(error)
        }
    }
}
