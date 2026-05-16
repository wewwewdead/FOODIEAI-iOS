import SwiftUI

/// Phase 14: a `MealCard` that owns its own inline expansion.
///
/// Tapping the card reveals the saved analysis below in the redesign's
/// visual language: `EditorialQuote` for the coach advice, then one
/// `CategoryAccordion` per non-empty category (Nutrients / Benefits /
/// Drawbacks). Cards with no expandable content swallow the tap (no
/// haptic, no state change) — matching the v1 `MealRow` "hide chevron
/// when there's nothing to show" rule, even though `MealCard`'s chevron
/// remains visually constant.
///
/// Used by:
///   - `TodayView` (Today tab list)
///   - `DayDetailSheet` (Week and Month day-detail sheet list)
///
/// All three surfaces now share one expansion design, which was the goal
/// of the post-redesign cleanup.
struct ExpandableMealCard: View {
    let log: FoodLog
    /// When non-nil, a long-press on the card surfaces a destructive
    /// "Delete log" context-menu item that opens a confirmation dialog
    /// before invoking this closure. Parents own the actual deletion
    /// (so they can refresh their own state afterwards).
    var onDelete: (() -> Void)? = nil

    @State private var isExpanded: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var deletePhase: DeletePhase = .idle

    /// Three-beat delete choreography, Duolingo-style:
    ///   .idle    → resting state
    ///   .windup  → squash + lift (≈140ms): the card "gathers itself"
    ///   .vanish  → shrink toward center with a small CCW tilt + fade
    ///              (≈340ms bouncy spring): springy disappear that has a
    ///              tiny overshoot before zero so the eye reads it as
    ///              alive, not as a hard cut.
    /// The parent's `onDelete` is invoked only once `.vanish` settles, so
    /// the network call and list-shift happen with the card already
    /// invisible — no awkward double-disappear.
    private enum DeletePhase { case idle, windup, vanish }

    var body: some View {
        // Phase 21.9 — one unified card chrome wraps both the row and
        // the expansion content. Previously `MealCard` carried its own
        // chrome and the expansion sat as an unstyled sibling below it,
        // which read as "floating outside the card." `hideChrome: true`
        // suppresses MealCard's own surface; this VStack supplies it.
        VStack(alignment: .leading, spacing: 0) {
            MealCard(
                log: log,
                onTap: {
                    guard hasExpandableContent else { return }
                    Haptics.soft()
                    // Phase 14 delight: bouncy expansion — overshoots before
                    // settling so the reveal feels alive.
                    withAnimation(.appBouncy) {
                        isExpanded.toggle()
                    }
                },
                expandsName: isExpanded,
                hideChrome: true
            )
            .contextMenu {
                if onDelete != nil {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete log", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog(
                "Delete this meal log?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    runDeleteAnimation()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the entry and its photo. This can't be undone.")
            }

            if isExpanded, hasExpandableContent, deletePhase == .idle {
                expansion
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.md)
                    .padding(.horizontal, AppSpacing.sm + 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .scaleEffect(deleteScaleX, anchor: .center)
        .scaleEffect(x: 1, y: deleteScaleY, anchor: .center)
        .rotationEffect(deleteRotation, anchor: .center)
        .opacity(deleteOpacity)
        .allowsHitTesting(deletePhase == .idle)
    }

    // MARK: - Delete choreography

    private var deleteScaleX: CGFloat {
        switch deletePhase {
        case .idle:    return 1
        case .windup:  return 1.04   // squash wider…
        case .vanish:  return 0.2
        }
    }

    private var deleteScaleY: CGFloat {
        switch deletePhase {
        case .idle:    return 1
        case .windup:  return 0.94   // …and shorter — gathering energy
        case .vanish:  return 0.2
        }
    }

    private var deleteRotation: Angle {
        switch deletePhase {
        case .idle, .windup: return .zero
        case .vanish:        return .degrees(-7)
        }
    }

    private var deleteOpacity: Double {
        switch deletePhase {
        case .idle, .windup: return 1
        case .vanish:        return 0
        }
    }

    private func runDeleteAnimation() {
        // Beat 1 — soft tap as the user commits, paired with the windup
        // squash. Soft (not heavy) because the heavier moment is the
        // vanish itself.
        Haptics.soft()
        withAnimation(.appStamp) {
            deletePhase = .windup
        }
        Task {
            try? await Task.sleep(nanoseconds: 140_000_000) // 0.14s
            // Beat 2 — vanish. Bouncy spring so the shrink feels
            // alive (slight overshoot before zero) instead of a flat
            // ease-out fade.
            await MainActor.run {
                Haptics.tap()
                withAnimation(.appBouncy) {
                    deletePhase = .vanish
                }
            }
            try? await Task.sleep(nanoseconds: 340_000_000) // 0.34s
            // Beat 3 — hand off. Card is already invisible, so the
            // list-row removal under us is unseen and the neighbors
            // spring into the empty slot smoothly.
            await MainActor.run {
                onDelete?()
            }
        }
    }

    /// The card is always expandable now (Phase 21.9): even a manual log
    /// with no analysis content has six macros worth showing in the
    /// macros grid. Tapping a card never feels inert.
    private var hasExpandableContent: Bool { true }

    @ViewBuilder
    private var expansion: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // Phase 21.9 — full 6-macro breakdown at the top of every
            // expansion. The inline row only shows carbs/sugar/protein;
            // fat and fiber were previously invisible per meal.
            MealMacroGrid(log: log)

            if let advice = log.coachAdvice, !advice.isEmpty {
                EditorialQuote(text: advice, attribution: log.coachName)
            }
            if !log.nutrients.isEmpty {
                CategoryAccordion(
                    kind: .nutrients,
                    title: "Nutrients",
                    items: log.nutrients
                )
            }
            if !log.benefits.isEmpty {
                CategoryAccordion(
                    kind: .benefits,
                    title: "Benefits",
                    items: log.benefits
                )
            }
            if !log.drawbacks.isEmpty {
                CategoryAccordion(
                    kind: .drawbacks,
                    title: "Drawbacks",
                    items: log.drawbacks
                )
            }
        }
        // Horizontal padding moved to the call site so the expansion
        // can align with the row inside the unified card chrome.
    }
}

// MARK: - Phase 21.9 — per-meal macros grid

/// Six-macro breakdown for one meal. Used inside `ExpandableMealCard`'s
/// expanded content. Reuses `MacroChip` so the visual treatment matches
/// the day-level chip row in `DayDetailSheet`.
///
/// Nil-valued macros (pre-Phase-11 analyzed rows, or manual logs where
/// the user left protein/fat/fiber blank) render as "—" rather than "0g"
/// — "0g" would be a false claim about the food's composition.
private struct MealMacroGrid: View {
    let log: FoodLog

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Macros").eyebrow()
                .foregroundStyle(Color.inkLight)

            // Two rows of three chips. Top: Calories / Carbs / Sugar
            // (always present in the schema). Bottom: Protein / Fat /
            // Fiber (optional — fall back to "—" placeholder).
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.sm) {
                    MacroChip(label: "Calories", value: log.calories, unit: "")
                    MacroChip(label: "Carbs",    value: log.carbsG,   unit: "g")
                    MacroChip(label: "Sugar",    value: log.sugarG,   unit: "g")
                }
                HStack(spacing: AppSpacing.sm) {
                    OptionalMacroChip(label: "Protein", value: log.proteinG, unit: "g")
                    OptionalMacroChip(label: "Fat",     value: log.fatG,     unit: "g")
                    OptionalMacroChip(label: "Fiber",   value: log.fiberG,   unit: "g")
                }
            }
        }
    }
}

/// Renders a `MacroChip` for a non-nil value, or a same-geometry "—"
/// placeholder when nil. Same fixed 78×64 footprint so a missing value
/// doesn't reflow the grid.
private struct OptionalMacroChip: View {
    let label: String
    let value: Double?
    let unit: String

    var body: some View {
        if let v = value {
            MacroChip(label: label, value: v, unit: unit)
        } else {
            MacroChipPlaceholder(label: label)
        }
    }
}

private struct MacroChipPlaceholder: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).eyebrow()
                .foregroundStyle(Color.inkLight)
            // "—" replaces both the number and the unit — communicating
            // "no data" rather than "we measured this and it was zero."
            Text("—")
                .appFont(.chipNumber)
                .foregroundStyle(Color.inkLight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 78, height: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) not recorded")
    }
}

#if DEBUG
#Preview("ExpandableMealCard — collapsed + expanded") {
    ScrollView {
        VStack(spacing: AppSpacing.md) {
            ExpandableMealCard(log: .preview(
                name: "Margherita Pizza",
                advice: "Pair with a side salad to balance carbs and fiber.",
                coach: "Albert Einstein",
                nutrients: ["Calcium 200mg", "Protein 12g", "Sodium 700mg"],
                benefits: ["Calcium for bone health", "Lycopene from tomato"],
                drawbacks: ["High in refined carbs", "Sodium can be elevated"]
            ))
            ExpandableMealCard(log: .preview(
                name: "Mystery snack (no content)",
                advice: nil,
                coach: nil,
                nutrients: [],
                benefits: [],
                drawbacks: []
            ))
        }
        .padding(AppSpacing.lg)
    }
    .background(Color.bgCanvas)
    .environmentObject(FavoritesStore.shared)
}

private extension FoodLog {
    static func preview(name: String,
                        advice: String?,
                        coach: String?,
                        nutrients: [String],
                        benefits: [String],
                        drawbacks: [String]) -> FoodLog {
        FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: 285,
            carbsG: 35,
            sugarG: 4,
            proteinG: 12,
            fatG: 9,
            fiberG: 2,
            benefits: benefits,
            drawbacks: drawbacks,
            nutrients: nutrients,
            coachName: coach,
            coachAdvice: advice,
            eatenAt: Date(),
            createdAt: Date(),
            origin: .analyzed,
            sourceLogId: nil,
            mood: nil
        )
    }
}
#endif
