import Foundation

/// Phase 21 — a single row of the bundled `CommonFoods.json` database.
/// Macro values are sourced from USDA FoodData Central plus published
/// values for Korean dishes. Optional fields stay nil when the source
/// didn't supply a value rather than getting silently zeroed.
struct CommonFood: Codable, Hashable, Identifiable {
    let name: String
    let servingDesc: String
    let calories: Double
    let carbsG: Double
    let proteinG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?

    var id: String { name }
}

/// Phase 21 — in-memory cache of the bundled common-foods database.
///
/// The JSON file is ~30 KB, decoded once on init, kept resident for the
/// life of the process. Search is a linear scan against the lowercased
/// query — at ~200 entries this is well under a microsecond and avoids
/// any index-warmup latency on first open.
@MainActor
final class CommonFoodsRepository: ObservableObject {
    static let shared = CommonFoodsRepository()
    private(set) var all: [CommonFood] = []

    init() {
        load()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "CommonFoods", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            #if DEBUG
            NSLog("[CommonFoods] bundle resource missing")
            #endif
            return
        }
        do {
            self.all = try JSONDecoder().decode([CommonFood].self, from: data)
        } catch {
            #if DEBUG
            NSLog("[CommonFoods] decode FAILED: %@", "\(error)")
            #endif
            self.all = []
        }
    }

    /// Case-insensitive prefix/substring search. Prefix matches rank
    /// above substring matches so "ban" surfaces "Banana" before
    /// anything that merely contains "ban" elsewhere in the name.
    func search(_ query: String, limit: Int = 12) -> [CommonFood] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(all.prefix(limit)) }

        var prefixHits: [CommonFood] = []
        var substringHits: [CommonFood] = []
        for food in all {
            let lower = food.name.lowercased()
            if lower.hasPrefix(q) {
                prefixHits.append(food)
            } else if lower.contains(q) {
                substringHits.append(food)
            }
        }
        return Array((prefixHits + substringHits).prefix(limit))
    }
}
