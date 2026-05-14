import Foundation
import Combine

/// Week 3 — local-only "favorite meals" store.
///
/// Keyed by normalized food name (lowercased, whitespace-collapsed) so
/// "Margherita Pizza" and "margherita pizza" share a heart. Persists to
/// UserDefaults as a `Set<String>`; no schema change, no network call.
/// A future phase can promote this to a server-backed surface; the
/// public API is intentionally narrow (`isFavorite`, `toggle`) so the
/// call sites won't need to change.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: Set<String> = []

    private let defaults: UserDefaults
    private let storageKey = "foodie.favorites.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.array(forKey: storageKey) as? [String] {
            self.favorites = Set(saved)
        }
    }

    func isFavorite(foodName: String) -> Bool {
        favorites.contains(Self.normalize(foodName))
    }

    /// Returns the new favorite state after toggling.
    @discardableResult
    func toggle(foodName: String) -> Bool {
        let key = Self.normalize(foodName)
        guard !key.isEmpty else { return false }
        if favorites.contains(key) {
            favorites.remove(key)
            persist()
            return false
        } else {
            favorites.insert(key)
            persist()
            return true
        }
    }

    private func persist() {
        defaults.set(Array(favorites), forKey: storageKey)
    }

    /// Lowercased, whitespace-trimmed, internal whitespace collapsed.
    /// Matches `MealHistoryService`'s case-insensitive identity rule so
    /// the heart and the repeat chip agree on what counts as the
    /// "same" food.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}
