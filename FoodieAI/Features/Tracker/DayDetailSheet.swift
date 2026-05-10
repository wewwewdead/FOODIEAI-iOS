import SwiftUI

/// Sheet shown when a Week bar or a Month calendar cell is tapped.
///
/// Phase 14 redesign: header and totals lifted to the v2 visual language —
/// eyebrow weekday + display2 date, hero calories number, MacroChip row
/// with "+more" expansion. The meal list uses `ExpandableMealCard` so
/// Week- and Month-day expansions match the Today list visually
/// (`EditorialQuote` + `CategoryAccordion`s) — one expansion design across
/// all three surfaces.
struct DayDetailSheet: View {
    let bucket: DailyBucket
    /// Optional callback invoked after a successful delete. Parent
    /// presenters (Week / Month) pass a refresh hook so the chart and
    /// calendar bars settle to the new totals. When nil, the sheet
    /// hides the delete affordance entirely (e.g., previews).
    var onDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showAllMacros: Bool = false
    private let logService = FoodLogService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                header
                if bucket.hasLogs {
                    caloriesBlock
                    macroChipRow
                    mealsSection
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.bgCanvas.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(weekdayLabel).eyebrow()
                .foregroundStyle(Color.inkLight)
            Text(monthDayLabel)
                .appFont(.display2)
                .foregroundStyle(Color.ink)
            Text(subhead)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
    }

    private var weekdayLabel: String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE"
        return f.string(from: bucket.date)
    }

    private var monthDayLabel: String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d"
        return f.string(from: bucket.date)
    }

    private var subhead: String {
        bucket.hasLogs
            ? "\(bucket.logs.count) meal\(bucket.logs.count == 1 ? "" : "s") logged"
            : "No meals logged this day"
    }

    // MARK: - Calories block

    private var caloriesBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Calories").eyebrow()
                .foregroundStyle(Color.inkLight)
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Text.number(bucket.totals.totalCalories)
                    .appFont(.heroNumber)
                    .foregroundStyle(Color.ink)
                Text("cal")
                    .appFont(.title2)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Macro chips

    /// Three primary chips visible by default. "+more" expands to reveal
    /// fat and fiber inline (sugar always shown — it's the brand's core
    /// metric). Tap on any chip in the expanded row collapses back.
    private var macroChipRow: some View {
        let totals = bucket.totals
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                MacroChip(label: "Carbs",   value: totals.totalCarbs,   unit: "g")
                MacroChip(label: "Sugar",   value: totals.totalSugar,   unit: "g")
                MacroChip(label: "Protein", value: totals.totalProtein, unit: "g")
                if showAllMacros {
                    MacroChip(label: "Fat",   value: totals.totalFat,   unit: "g")
                    MacroChip(label: "Fiber", value: totals.totalFiber, unit: "g")
                } else {
                    Button {
                        Haptics.tap()
                        withAnimation(.motionReveal) { showAllMacros = true }
                    } label: {
                        MacroChip.more(count: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show fat and fiber")
                }
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: - Meals section

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Meals").eyebrow()
                    .foregroundStyle(Color.inkLight)
                Spacer()
                Text("\(bucket.logs.count)")
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.brand)
            }

            // Phase 13: 0.08s stagger between meal rows on entrance — tighter
            // than the Today list's 0.2s because the sheet is a smaller
            // surface and a longer cascade would feel sluggish.
            LazyVStack(spacing: AppSpacing.md) {
                ForEach(Array(bucket.logs.enumerated()), id: \.element.id) { idx, log in
                    ExpandableMealCard(
                        log: log,
                        onDelete: onDeleted == nil ? nil : {
                            handleDelete(log)
                        }
                    )
                    // Asymmetric: keep the staggered top-slide on insert
                    // but use a simple opacity exit on removal — the
                    // card's own squash-and-vanish has already played
                    // by the time SwiftUI sees the row leave.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                    .animation(
                        .appBouncy.delay(Double(idx) * 0.04),
                        value: bucket.logs.count
                    )
                }
            }
        }
    }

    // MARK: - Delete

    /// Fires the actual deletion in the background, then notifies the
    /// parent so it can refresh. The card has already played its own
    /// squash-and-vanish before this is called, so visual feedback for
    /// the tap is fully owned by the card itself.
    private func handleDelete(_ log: FoodLog) {
        Task {
            do {
                try await logService.delete(log)
            } catch {
                #if DEBUG
                NSLog("[DayDetail] delete FAILED for %@: %@",
                      log.id.uuidString, "\(error)")
                #endif
            }
            await MainActor.run {
                onDeleted?()
                // If the bucket had a single log, the parent's refresh
                // will repopulate to an empty bucket; close the sheet
                // to avoid showing the now-stale "1 meal logged" header.
                if bucket.logs.count <= 1 {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        AmbientEmptyState(
            iconSystemName: "fork.knife.circle",
            message: "No meals logged this day"
        )
        .padding(.top, AppSpacing.xl3)
    }
}

#if DEBUG
#Preview("DayDetailSheet — populated") {
    Color.bgCanvas.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            DayDetailSheet(bucket: .preview(meals: 3))
                .presentationDetents([.medium, .large])
        }
}

#Preview("DayDetailSheet — empty") {
    Color.bgCanvas.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            DayDetailSheet(bucket: .preview(meals: 0))
                .presentationDetents([.medium, .large])
        }
}

private extension DailyBucket {
    static func preview(meals: Int) -> DailyBucket {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let names = ["Margherita pizza", "Greek salad", "Protein shake"]
        let logs: [FoodLog] = (0..<meals).map { i in
            FoodLog(
                id: UUID(),
                userId: UUID(),
                foodName: names[i % names.count],
                imagePath: nil,
                imageThumbPath: nil,
                calories: Double(420 - i * 80),
                carbsG: Double(48 - i * 6),
                sugarG: Double(6 + i),
                proteinG: Double(18 + i * 4),
                fatG: Double(12),
                fiberG: Double(3),
                benefits: ["Calcium", "Lycopene"],
                drawbacks: ["Refined carbs"],
                nutrients: ["Calcium 200mg", "Iron 2mg"],
                coachName: "Albert Einstein",
                coachAdvice: "Pair with a side salad to balance.",
                eatenAt: cal.date(byAdding: .hour, value: 8 + i * 4, to: day) ?? day,
                createdAt: Date(),
                origin: .analyzed,
                sourceLogId: nil,
                mood: nil
            )
        }
        return DailyBucket(date: day, logs: logs)
    }
}
#endif
