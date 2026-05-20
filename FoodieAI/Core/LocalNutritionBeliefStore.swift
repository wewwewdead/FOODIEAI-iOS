import Foundation
import Combine

/// Local-only Bayesian-style belief store. Tracks the user's per-food
/// mean macros and observation counts so the result UI can annotate
/// Gemini's estimate with a personalized confidence + insight without a
/// backend round-trip.
///
/// Storage shape: a single JSON blob (`Set` → dictionary keyed by
/// normalized food name) in `UserDefaults`. Updates run incrementally
/// using Welford's recurrence:
///
///   newMean = oldMean + (observedValue - oldMean) / newCount
///
/// Macros are tracked independently because Gemini's structured output
/// can return any subset (e.g., older meals saved without protein /
/// fiber). A nil observed value just means "don't move that macro's
/// belief this time."
///
/// Confidence buckets are intentionally coarse so the UI can describe
/// them in plain language:
///   - 0...1 observations  → .low
///   - 2...4 observations  → .medium
///   - 5+    observations  → .high
///
/// Privacy: beliefs never leave the device. No PII beyond the food
/// names the user has already chosen to log; on reinstall the store
/// resets to empty.
@MainActor
final class LocalNutritionBeliefStore: ObservableObject {
    static let shared = LocalNutritionBeliefStore()

    @Published private(set) var beliefs: [String: FoodBelief] = [:]

    private let defaults: UserDefaults
    /// Bumped to v2 when mood counts and per-meal calorie samples
    /// were added to `FoodBelief`. v1 blobs are simply ignored on
    /// upgrade (local-only enrichment, no migration value).
    private let storageKey = "foodie.nutritionBeliefs.v2"

    /// Soft cap so the JSON blob can't grow unbounded over time. When
    /// hit, we drop the least-recently-updated entries first. ~1KB per
    /// belief × 500 entries ≈ 500KB, comfortably below the
    /// UserDefaults sweet spot.
    private let retentionCap = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.beliefs = Self.load(from: defaults, key: storageKey)
    }

    // MARK: - Reads

    /// Look up the belief for a food name (case- and whitespace-
    /// insensitive). Returns nil for unknown foods so callers can
    /// short-circuit to a neutral presentation.
    func belief(for foodName: String) -> FoodBelief? {
        let key = Self.normalize(foodName)
        guard !key.isEmpty else { return nil }
        return beliefs[key]
    }

    // MARK: - Writes

    /// Update beliefs from a freshly inserted log. Each macro updates
    /// only if the observed value is present and finite; missing
    /// macros leave the prior mean untouched but still bump the
    /// overall observation counter so confidence reflects "how many
    /// times have I seen this food at all."
    ///
    /// Silent on failure paths (e.g., empty food name) — beliefs are
    /// enrichment and must never block save.
    func update(from log: FoodLog) {
        update(
            foodName: log.foodName,
            calories: log.calories,
            carbs:    log.carbsG,
            protein:  log.proteinG,
            fat:      log.fatG,
            sugar:    log.sugarG,
            fiber:    log.fiberG,
            mood:     log.mood,
            now:      Date()
        )
    }

    /// Granular form used by tests so we don't have to construct a
    /// full FoodLog with a UUID/userId just to feed the store. `mood`
    /// is optional because most saves happen before the mood pulse
    /// fires — see `recordMoodIfKnown(...)` for the post-pulse path.
    func update(foodName: String,
                calories: Double?,
                carbs: Double?,
                protein: Double?,
                fat: Double?,
                sugar: Double?,
                fiber: Double?,
                mood: FoodLog.Mood? = nil,
                now: Date = Date()) {
        let key = Self.normalize(foodName)
        guard !key.isEmpty else { return }

        var belief = beliefs[key] ?? FoodBelief(
            foodKey:     key,
            displayName: foodName,
            calories:    MacroBelief(),
            carbs:       MacroBelief(),
            protein:     MacroBelief(),
            fat:         MacroBelief(),
            sugar:       MacroBelief(),
            fiber:       MacroBelief(),
            moodCounts:  MoodCounts(),
            observations: 0,
            lastUpdated:  now
        )

        belief.displayName = foodName
        belief.observations += 1
        belief.lastUpdated  = now
        belief.calories.update(with: calories)
        belief.carbs.update(with: carbs)
        belief.protein.update(with: protein)
        belief.fat.update(with: fat)
        belief.sugar.update(with: sugar)
        belief.fiber.update(with: fiber)
        belief.moodCounts.record(mood)

        beliefs[key] = belief
        prune()
        persist()

        #if DEBUG
        NSLog("[Belief] update key=%@ obs=%d cal_mean=%.0f (n=%d)",
              key, belief.observations,
              belief.calories.mean, belief.calories.count)
        #endif
    }

    /// Late-binding mood update — used after the mood pulse resolves
    /// for a meal that was already inserted (and already counted as an
    /// observation by `update(from:)`). Increments the mood histogram
    /// only; does NOT bump `observations` again, otherwise the same
    /// meal would inflate confidence twice.
    func recordMoodIfKnown(_ mood: FoodLog.Mood?,
                           for foodName: String,
                           now: Date = Date()) {
        guard let mood else { return }
        let key = Self.normalize(foodName)
        guard !key.isEmpty, var belief = beliefs[key] else { return }
        belief.moodCounts.record(mood)
        belief.lastUpdated = now
        beliefs[key] = belief
        persist()
    }

    // MARK: - Global stats

    /// Mean calories across every observation of every food the user
    /// has saved at least once. Used by the pattern insight service
    /// to compare a single meal against the user's typical meal —
    /// nil when we don't yet have enough data to make the comparison
    /// honest (< 3 distinct foods with calorie observations).
    func typicalMealCalories(minimumFoods: Int = 3) -> Double? {
        let withCalories = beliefs.values.filter { $0.calories.count > 0 }
        guard withCalories.count >= minimumFoods else { return nil }
        let total = withCalories.reduce(0.0) { $0 + $1.calories.mean }
        return total / Double(withCalories.count)
    }

    /// Test/debug surface. Production paths never need this.
    func reset() {
        beliefs = [:]
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(beliefs)
            defaults.set(data, forKey: storageKey)
        } catch {
            #if DEBUG
            NSLog("[Belief] persist FAILED: %@", "\(error)")
            #endif
        }
    }

    private static func load(from defaults: UserDefaults,
                             key: String) -> [String: FoodBelief] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: FoodBelief].self, from: data)
        } catch {
            #if DEBUG
            NSLog("[Belief] decode FAILED: %@", "\(error)")
            #endif
            return [:]
        }
    }

    /// Drops the least-recently-updated entries once the dictionary
    /// exceeds `retentionCap`. Cheap O(n log n) sort; runs after every
    /// update — n is bounded.
    private func prune() {
        guard beliefs.count > retentionCap else { return }
        let sorted = beliefs.sorted { $0.value.lastUpdated > $1.value.lastUpdated }
        beliefs = Dictionary(uniqueKeysWithValues: sorted.prefix(retentionCap)
            .map { ($0.key, $0.value) })
    }

    // MARK: - Normalization

    /// Case-folded, whitespace-collapsed key so "Chicken Rice" and
    /// "chicken  rice" map to the same belief. We intentionally do not
    /// lemmatize / strip qualifiers — "chicken rice bowl" and
    /// "chicken rice" are different enough nutritionally that
    /// conflating them would muddy the signal.
    nonisolated static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        let folded = lowered.folding(options: .diacriticInsensitive,
                                     locale: .current)
        let collapsed = folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

/// Per-macro belief: incremental mean + observation count. Confidence
/// derives from `count` so callers can describe certainty per macro
/// when (e.g.) calories are well-known but fiber isn't.
struct MacroBelief: Codable, Equatable {
    var mean: Double = 0
    var count: Int   = 0

    /// Welford-style incremental mean. Skips nil / non-finite values
    /// so a missing macro doesn't drag the running mean toward zero.
    mutating func update(with observed: Double?) {
        guard let v = observed, v.isFinite else { return }
        count += 1
        mean += (v - mean) / Double(count)
    }

    var confidence: BeliefConfidence {
        BeliefConfidence.bucket(for: count)
    }
}

/// Aggregate belief for a single normalized food name.
struct FoodBelief: Codable, Equatable {
    let foodKey: String
    var displayName: String
    var calories: MacroBelief
    var carbs: MacroBelief
    var protein: MacroBelief
    var fat: MacroBelief
    var sugar: MacroBelief
    var fiber: MacroBelief
    /// Running histogram of post-meal moods reported for this food.
    /// Populated lazily — most observations land before the user
    /// answers the mood pulse, so `moodCounts.total` is typically
    /// lower than `observations`. The insight surface gates on
    /// `moodCounts.total >= 2` to avoid speaking from a single
    /// data point.
    var moodCounts: MoodCounts
    /// How many times this food was saved overall. Used by the UI
    /// confidence label; per-macro counts can be lower than this
    /// when the source analysis was missing fields.
    var observations: Int
    var lastUpdated: Date

    var confidence: BeliefConfidence {
        BeliefConfidence.bucket(for: observations)
    }
}

/// Per-food histogram of the three FoodLog moods.
struct MoodCounts: Codable, Equatable {
    var loved: Int = 0
    var fine: Int = 0
    var tough: Int = 0

    var total: Int { loved + fine + tough }

    mutating func record(_ mood: FoodLog.Mood?) {
        guard let mood else { return }
        switch mood {
        case .loved: loved += 1
        case .fine:  fine  += 1
        case .tough: tough += 1
        }
    }

    /// Returns the mood that holds the plurality of reports, but only
    /// when it actually dominates (≥ 60% of the sample) — keeps the
    /// "you usually feel X after this" copy honest. Nil when the
    /// sample is too small or evenly split.
    func dominant(minimumSample: Int = 2,
                  dominanceRatio: Double = 0.6) -> FoodLog.Mood? {
        guard total >= minimumSample else { return nil }
        let pairs: [(FoodLog.Mood, Int)] = [
            (.loved, loved), (.fine, fine), (.tough, tough)
        ]
        guard let top = pairs.max(by: { $0.1 < $1.1 }) else { return nil }
        let share = Double(top.1) / Double(total)
        return share >= dominanceRatio ? top.0 : nil
    }
}

/// Three-tier confidence label. Coarse on purpose: the UI copy reads
/// better when it can say "still learning" / "getting a feel" /
/// "confident" instead of a numeric count.
enum BeliefConfidence: String, Codable, Equatable, CaseIterable {
    case low
    case medium
    case high

    static func bucket(for count: Int) -> BeliefConfidence {
        switch count {
        case ..<2:  return .low
        case 2...4: return .medium
        default:    return .high
        }
    }

    var label: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}
