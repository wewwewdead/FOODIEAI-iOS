import Foundation

// NOVEL_DIRECTIONS Idea 4 — "Visual Food Memory".
//
// The app analyzes a meal photo once, then throws it away and leans on the
// (unreliable) text name — which is exactly why a `NameConfirmSheet` fires on
// EVERY scan. This subsystem gives the app a memory of the user's meals keyed
// on the PHOTO instead: each saved meal contributes a compact feature-print
// (from `VisionMealEmbedder`, on-device Vision), stored locally with zero
// egress. From it we can answer "have they eaten this exact dish before?" and,
// later, pre-fill the name from the nearest visual match.
//
// Split by testability: the matching logic here is PURE (operates on `[Float]`
// descriptors + Euclidean distance) so it's unit-tested without Vision; the
// side-effectful embedding lives at the boundary in `VisionMealEmbedder`.

/// A compact visual fingerprint of a meal photo (a Vision feature-print vector).
/// Persisted as raw little-endian `Float` bytes (base64 in JSON) rather than an
/// array of JSON numbers — ~2k dims per print, so the compact form matters.
struct VisualDescriptor: Codable, Equatable {
    let vector: [Float]

    init(vector: [Float]) { self.vector = vector }

    /// True when every element is finite. A print with a NaN/Inf element (a
    /// corrupt embedding) must never be stored or matched — it would poison
    /// distance comparisons.
    var isValid: Bool { !vector.isEmpty && vector.allSatisfy { $0.isFinite } }

    /// Squared Euclidean distance — no `sqrt`, monotonic, so it's fine for
    /// nearest-neighbour ranking and threshold tests. Vision feature-prints use
    /// an L2 metric, so this matches `VNFeaturePrintObservation.computeDistance`
    /// on the extracted vector. Mismatched dimensions, empty, or any non-finite
    /// result ⇒ "infinitely far" (never a false match). Accumulates in `Double`
    /// for numerical stability across ~2k dimensions.
    func squaredDistance(to other: VisualDescriptor) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else {
            return .greatestFiniteMagnitude
        }
        var sum: Double = 0
        for i in vector.indices {
            let d = Double(vector[i]) - Double(other.vector[i])
            sum += d * d
        }
        guard sum.isFinite else { return .greatestFiniteMagnitude }
        return Float(min(sum, Double(Float.greatestFiniteMagnitude)))
    }

    /// Euclidean distance. Thresholds in this file are expressed in this space.
    func distance(to other: VisualDescriptor) -> Float {
        let sq = squaredDistance(to: other)
        return sq == .greatestFiniteMagnitude ? sq : sq.squareRoot()
    }

    // Compact Codable: store the raw float bytes as `Data` (base64 in JSON).
    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let data = try c.decode(Data.self, forKey: .data)
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        self.vector = floats
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try c.encode(data, forKey: .data)
    }
}

/// One remembered meal: its name at save time, its visual fingerprint, and when.
struct VisualMemoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let foodName: String
    let descriptor: VisualDescriptor
    let loggedAt: Date

    init(id: UUID = UUID(), foodName: String, descriptor: VisualDescriptor, loggedAt: Date) {
        self.id = id
        self.foodName = foodName
        self.descriptor = descriptor
        self.loggedAt = loggedAt
    }
}

struct VisualMatch: Equatable {
    let entry: VisualMemoryEntry
    /// Euclidean distance from the query descriptor (smaller = more similar).
    let distance: Float
}

/// Pure nearest-neighbour + clustering logic over remembered meals. No I/O, no
/// Vision — every function is a pure function of its inputs, so the recognition
/// behaviour is fully unit-testable with synthetic descriptors.
enum VisualFoodMatcher {

    /// The single closest remembered meal to `query`, or nil when there's
    /// nothing to compare against. Deterministic tie-break: on equal distance
    /// the earlier-logged entry wins, then the lower UUID, so results are stable.
    static func nearest(to query: VisualDescriptor,
                        in entries: [VisualMemoryEntry]) -> VisualMatch? {
        var best: VisualMatch?
        for entry in entries {
            let d = entry.descriptor.distance(to: query)
            guard d < .greatestFiniteMagnitude else { continue }
            if let current = best {
                if d < current.distance
                    || (d == current.distance && entry.loggedAt < current.entry.loggedAt)
                    || (d == current.distance && entry.loggedAt == current.entry.loggedAt
                        && entry.id.uuidString < current.entry.id.uuidString) {
                    best = VisualMatch(entry: entry, distance: d)
                }
            } else {
                best = VisualMatch(entry: entry, distance: d)
            }
        }
        return best
    }

    /// Every remembered meal within `maxDistance` of `query` — the "you've
    /// eaten this before" cluster — sorted nearest-first.
    static func occurrences(of query: VisualDescriptor,
                            in entries: [VisualMemoryEntry],
                            within maxDistance: Float) -> [VisualMatch] {
        entries
            .map { VisualMatch(entry: $0, distance: $0.descriptor.distance(to: query)) }
            .filter { $0.distance <= maxDistance }
            .sorted { $0.distance < $1.distance }
    }

    /// How many past meals look like `query` (the cluster size). This is the
    /// "you've had this 6 times" signal.
    static func timesSeen(_ query: VisualDescriptor,
                          in entries: [VisualMemoryEntry],
                          within maxDistance: Float) -> Int {
        occurrences(of: query, in: entries, within: maxDistance).count
    }

    /// Name to suggest for a new photo: the nearest remembered meal's name, but
    /// only when it's close enough to trust (≤ `maxDistance`). Returns nil when
    /// there's no confident match — the caller then falls back to the model's
    /// name. This is what lets the name-confirm step be skipped for a dish the
    /// user has logged before.
    static func suggestedName(for query: VisualDescriptor,
                              in entries: [VisualMemoryEntry],
                              maxDistance: Float) -> String? {
        guard let match = nearest(to: query, in: entries),
              match.distance <= maxDistance else { return nil }
        return match.entry.foodName
    }

    /// Learn a "same dish" distance threshold from the user's OWN labeled
    /// history, so recognition needs no hand-tuned magic number. Same-name
    /// entries give the distances between repeats of a dish; different-name
    /// entries give the gap to other dishes. The threshold sits high enough to
    /// catch real repeats (85th percentile of same-dish distances) yet never
    /// bleeds into clearly-different dishes (capped by the closest different-dish
    /// pairs). Returns nil until there's enough evidence (>= `minSamePairs`
    /// same-dish pairs), so recognition stays silent rather than guessing.
    static func calibratedThreshold(from entries: [VisualMemoryEntry],
                                    minSamePairs: Int = 4) -> Float? {
        guard entries.count >= 3 else { return nil }
        var same: [Float] = []
        var diff: [Float] = []
        for i in 0..<entries.count {
            let nameA = entries[i].foodName.lowercased()
            for j in (i + 1)..<entries.count {
                let d = entries[i].descriptor.distance(to: entries[j].descriptor)
                guard d < .greatestFiniteMagnitude else { continue }
                if nameA == entries[j].foodName.lowercased() { same.append(d) }
                else { diff.append(d) }
            }
        }
        guard same.count >= minSamePairs else { return nil }
        same.sort()
        let sameP85 = percentile(same, 0.85)
        guard !diff.isEmpty else { return sameP85 }
        diff.sort()
        let diffP05 = percentile(diff, 0.05)   // the closest different-dish pairs
        // Clean separation: sit at the same-dish 85th percentile. Overlap: split
        // the difference so most repeats match without calling two different
        // dishes the same.
        return sameP85 <= diffP05 ? sameP85 : (sameP85 + diffP05) / 2
    }

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * min(max(p, 0), 1)).rounded())
        return sorted[idx]
    }
}

/// On-device store of remembered meals. Actor-isolated so the save path can
/// write to it from a detached task without data races. File-persisted JSON in
/// Application Support (never leaves the device). Newest-first, capped.
actor VisualFoodMemory {
    static let shared = VisualFoodMemory()

    /// Keep the store bounded — visual recognition only needs recent history,
    /// and each print is ~8 KB. 300 ≈ a few months of meals.
    static let maxEntries = 300

    private var entries: [VisualMemoryEntry]
    /// The "same dish" threshold learned from the user's OWN repeat history (see
    /// `VisualFoodMatcher.calibratedThreshold`). nil until there's enough
    /// evidence, in which case recognition stays silent rather than guessing.
    /// Recomputed on every write; cached so reads are cheap.
    private var cachedThreshold: Float?
    private let storeURL: URL?

    init(storeURL: URL? = VisualFoodMemory.defaultStoreURL()) {
        self.storeURL = storeURL
        self.entries = VisualFoodMemory.load(from: storeURL)
        self.cachedThreshold = VisualFoodMatcher.calibratedThreshold(from: entries)
    }

    /// Test seam: build a store with in-memory entries and no persistence.
    init(entries: [VisualMemoryEntry]) {
        self.storeURL = nil
        self.entries = entries
        self.cachedThreshold = VisualFoodMatcher.calibratedThreshold(from: entries)
    }

    // MARK: Write

    func record(foodName: String, descriptor: VisualDescriptor, at date: Date) {
        let name = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, descriptor.isValid else { return }
        entries.insert(
            VisualMemoryEntry(foodName: name, descriptor: descriptor, loggedAt: date),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        cachedThreshold = VisualFoodMatcher.calibratedThreshold(from: entries)
        persist()
    }

    // MARK: Read (delegates to the pure matcher, gated by the learned threshold)

    /// The learned "same dish" threshold, or nil until there's enough repeat
    /// history to trust one. Recognition stays silent while nil.
    var learnedThreshold: Float? { cachedThreshold }

    func nearestMatch(to descriptor: VisualDescriptor) -> VisualMatch? {
        VisualFoodMatcher.nearest(to: descriptor, in: entries)
    }

    /// Number of past meals recognized as this dish, or 0 until calibrated.
    func timesSeen(_ descriptor: VisualDescriptor) -> Int {
        guard let threshold = cachedThreshold else { return 0 }
        return VisualFoodMatcher.timesSeen(descriptor, in: entries, within: threshold)
    }

    /// Name recognized from a confident past match, or nil until calibrated /
    /// when nothing is close enough. Self-gating: silent until the user has
    /// enough repeat history to learn their own threshold.
    func suggestedName(for descriptor: VisualDescriptor) -> String? {
        guard let threshold = cachedThreshold else { return nil }
        return VisualFoodMatcher.suggestedName(for: descriptor, in: entries, maxDistance: threshold)
    }

    var count: Int { entries.count }

    // MARK: Persistence

    private func persist() {
        guard let storeURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func defaultStoreURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("visual_food_memory.v1.json")
    }

    private static func load(from url: URL?) -> [VisualMemoryEntry] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([VisualMemoryEntry].self, from: data)
        else { return [] }
        return decoded
    }
}
