import Foundation

/// Phase 21 — drives the ManualLogSheet's three-step flow:
///
///   .search → user picks a CommonFood (or Quick Add) → .quantity
///   .quantity → user confirms multiplier → .confirm
///   .confirm → Save → returns the inserted FoodLog
///
/// The .custom step is a parallel branch from .search for "I'm typing
/// a food that isn't in the database." Save from .custom skips
/// .quantity entirely.
///
/// Streak + quest side-effects fire from the host view after a
/// successful save, not here — this view model stays focused on the
/// input mechanics and the DB insert.
@MainActor
final class ManualLogViewModel: ObservableObject {
    enum Step: Equatable {
        case search
        case quantity
        case confirm
        case custom
    }

    @Published var step: Step = .search
    @Published var query: String = ""
    @Published var pickedFood: CommonFood? = nil
    @Published var quantityMultiplier: Double = 1.0
    @Published var quickAddSuggestions: [FoodLog] = []
    @Published var isSaving: Bool = false
    @Published var lastError: String? = nil

    // Custom-food inputs. Kept as strings so the numeric fields can
    // accept partial input ("0", "12.") without re-formatting on every
    // keystroke; parsed to Double at save time.
    @Published var customName: String = ""
    @Published var customCalories: String = ""
    @Published var customCarbs: String = ""
    @Published var customProtein: String = ""
    @Published var customFat: String = ""
    @Published var customFiber: String = ""
    @Published var customSugar: String = ""

    private let foodLogService: FoodLogService
    private let mealHistory: MealHistoryService

    init(foodLogService: FoodLogService = FoodLogService(),
         mealHistory: MealHistoryService = MealHistoryService()) {
        self.foodLogService = foodLogService
        self.mealHistory    = mealHistory
    }

    var searchResults: [CommonFood] {
        CommonFoodsRepository.shared.search(query)
    }

    func loadQuickAddSuggestions() async {
        do {
            let recents = try await mealHistory.recentUniqueMeals(limit: 6)
            // Don't show relogged duplicates — they reference the same
            // food name as their source, which would surface twice.
            // `recentUniqueMeals` already dedupes by name; we just
            // exclude relogged-origin rows in case a re-log is the
            // newest instance and its source has aged out.
            quickAddSuggestions = recents.filter { $0.origin != .relogged }
        } catch {
            #if DEBUG
            NSLog("[ManualLog] quick-add load FAILED: %@", "\(error)")
            #endif
            quickAddSuggestions = []
        }
    }

    func selectCommonFood(_ food: CommonFood) {
        pickedFood = food
        quantityMultiplier = 1.0
        step = .quantity
    }

    func selectQuickAdd(_ log: FoodLog) {
        // Project the prior log into a synthetic CommonFood at its
        // original serving so the quantity step works against the same
        // shape as a database pick. The serving description is taken
        // from the original log's nutrients[0] (where manual logs
        // stashed it) if available, otherwise a generic label.
        let serving: String
        if log.origin == .manual, let first = log.nutrients.first, !first.isEmpty {
            serving = first
        } else {
            serving = "Previously logged"
        }
        pickedFood = CommonFood(
            name: log.foodName,
            servingDesc: serving,
            calories: log.calories,
            carbsG: log.carbsG,
            proteinG: log.proteinG,
            fatG: log.fatG,
            fiberG: log.fiberG,
            sugarG: log.sugarG
        )
        quantityMultiplier = 1.0
        step = .quantity
    }

    func goBackToSearch() {
        pickedFood = nil
        step = .search
    }

    func proceedToConfirm() {
        step = .confirm
    }

    func openCustom() {
        step = .custom
    }

    var computedTotals: (calories: Double, carbs: Double, protein: Double?, fat: Double?, fiber: Double?, sugar: Double?) {
        guard let food = pickedFood else { return (0, 0, nil, nil, nil, nil) }
        let m = quantityMultiplier
        return (
            food.calories * m,
            food.carbsG * m,
            food.proteinG.map { $0 * m },
            food.fatG.map     { $0 * m },
            food.fiberG.map   { $0 * m },
            food.sugarG.map   { $0 * m }
        )
    }

    /// Save the picked CommonFood at the chosen multiplier. Throws on
    /// DB error; the caller is expected to set `isSaving` and present
    /// `lastError` from the catch site.
    func saveCommonFoodEntry() async throws -> FoodLog {
        guard let food = pickedFood else { throw ManualLogError.noFoodSelected }
        let totals = computedTotals

        let multiplierDesc: String
        if abs(quantityMultiplier - 1.0) < 0.001 {
            multiplierDesc = food.servingDesc
        } else {
            multiplierDesc = "\(Self.formatMultiplier(quantityMultiplier))× \(food.servingDesc)"
        }

        return try await foodLogService.insertManual(
            foodName:    food.name,
            servingDesc: multiplierDesc,
            calories:    totals.calories,
            carbsG:      totals.carbs,
            proteinG:    totals.protein,
            fatG:        totals.fat,
            fiberG:      totals.fiber,
            sugarG:      totals.sugar
        )
    }

    func saveCustomEntry() async throws -> FoodLog {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManualLogError.missingName }
        guard let cals = Double(customCalories.replacingOccurrences(of: ",", with: ".")),
              cals > 0 else {
            throw ManualLogError.missingCalories
        }

        return try await foodLogService.insertManual(
            foodName:    trimmed,
            servingDesc: "Custom entry",
            calories:    cals,
            carbsG:      Self.parseOptional(customCarbs) ?? 0,
            proteinG:    Self.parseOptional(customProtein),
            fatG:        Self.parseOptional(customFat),
            fiberG:      Self.parseOptional(customFiber),
            sugarG:      Self.parseOptional(customSugar)
        )
    }

    /// "0.5" / "1.5" / "2" — drop trailing zeros so the serving
    /// description reads naturally.
    private static func formatMultiplier(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%g", value)
    }

    private static func parseOptional(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

enum ManualLogError: LocalizedError {
    case noFoodSelected
    case missingName
    case missingCalories

    var errorDescription: String? {
        switch self {
        case .noFoodSelected:   return "Pick a food first."
        case .missingName:      return "Add a name for your custom food."
        case .missingCalories:  return "Calories are required."
        }
    }
}
