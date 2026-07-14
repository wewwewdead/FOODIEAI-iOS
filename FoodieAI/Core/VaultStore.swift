import Foundation
import Combine

/// One entry in the Vault's lightweight name manifest: just the id and the
/// food name. This is what the client fetches for the WHOLE vault up front
/// (`VaultService.nameManifest`) — the heavy analysis payload (benefits,
/// drawbacks, nutrients, coach note, macros) is fetched lazily, one page at
/// a time, only for the cards actually on screen.
///
/// The array order returned by the manifest query IS recency (created_at
/// desc), so no timestamp is needed here — dropping it keeps the manifest as
/// small as possible (the low-egress rule): two short strings per food.
struct VaultNameEntry: Decodable, Identifiable, Hashable {
    let id: UUID
    let foodName: String

    enum CodingKeys: String, CodingKey {
        case id
        case foodName = "food_name"
    }
}

/// A client-side inverted index over the vault's food names, so search is
/// instant and costs zero egress no matter how large the vault grows. Built
/// once from the name manifest; kept in lockstep with add/remove.
///
/// Structure:
///   - `postings`: token → set of item ids whose name contains that token.
///   - `sortedTokens`: the distinct tokens, sorted, so a prefix query
///     ("chick") resolves to a contiguous range ("chicken", "chickpea", …)
///     via binary search instead of scanning every token.
///
/// Query semantics: the query is tokenized the same way as the names; every
/// query term must match (AND), and each term is prefix-matched, so
/// "grill chick" finds "Grilled Chicken". `search` returns the matching id
/// set, or `nil` for an empty query (caller reads `nil` as "no filter").
struct VaultSearchIndex {
    private var postings: [String: Set<UUID>] = [:]
    private var sortedTokens: [String] = []

    init() {}

    init(_ entries: [(id: UUID, name: String)]) {
        for entry in entries {
            addTokens(of: entry.name, to: entry.id)
        }
        rebuildSortedTokens()
    }

    // MARK: Mutation

    mutating func insert(id: UUID, name: String) {
        addTokens(of: name, to: id)
        rebuildSortedTokens()
    }

    mutating func remove(id: UUID, name: String) {
        for token in Self.tokenize(name) {
            postings[token]?.remove(id)
            if postings[token]?.isEmpty == true { postings[token] = nil }
        }
        rebuildSortedTokens()
    }

    private mutating func addTokens(of name: String, to id: UUID) {
        for token in Self.tokenize(name) {
            postings[token, default: []].insert(id)
        }
    }

    private mutating func rebuildSortedTokens() {
        sortedTokens = postings.keys.sorted()
    }

    // MARK: Query

    /// Matching ids for `query`, or `nil` when the query has no terms (the
    /// caller treats `nil` as "show everything, unfiltered"). An empty set
    /// means "searched, matched nothing".
    func search(_ query: String) -> Set<UUID>? {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return nil }

        var result: Set<UUID>?
        for term in terms {
            let matches = ids(withPrefix: term)
            if matches.isEmpty { return [] }        // a term hits nothing → no results
            if result == nil {
                result = matches
            } else {
                result!.formIntersection(matches)   // AND across terms
                if result!.isEmpty { return [] }
            }
        }
        return result ?? []
    }

    /// Union of the postings for every token that starts with `prefix`,
    /// located by binary-searching the sorted token list for the range start.
    private func ids(withPrefix prefix: String) -> Set<UUID> {
        guard !prefix.isEmpty else { return [] }
        var out = Set<UUID>()
        var i = Self.lowerBound(sortedTokens, prefix)
        while i < sortedTokens.count, sortedTokens[i].hasPrefix(prefix) {
            if let ids = postings[sortedTokens[i]] { out.formUnion(ids) }
            i += 1
        }
        return out
    }

    /// First index `i` where `arr[i] >= key`.
    private static func lowerBound(_ arr: [String], _ key: String) -> Int {
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Split a name/query into lowercased alphanumeric tokens.
    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    #if DEBUG
    /// Test-only: number of distinct tokens indexed.
    var tokenCount: Int { sortedTokens.count }
    #endif
}

/// Phase 23 — the Vault. App-wide, server-backed store of the user's
/// saved foods (`public.vault_items`). This is the durable counterpart to
/// the on-device, name-only `FavoritesStore`: it keeps the full analysis
/// + photo so a saved food can be re-logged forever, not just while it's
/// still inside the recent-meals window.
///
/// Heart (FavoritesStore) and Vault are deliberately separate features.
///
/// ## Scaling: manifest + paged cards + local index (low egress)
///
/// A naive "fetch the whole vault" grows unbounded — the analysis payload
/// per food is large. Instead this store loads a tiny **name manifest**
/// (id + name for every food) once, then fetches the heavy card rows
/// **one page at a time** as the gallery scrolls (`loadNextPage`). Search
/// runs entirely against an in-memory **inverted index** built from the
/// manifest, so filtering costs zero egress; only the cards that actually
/// display are ever fetched in full.
///
/// This store owns:
///   - `manifest` + `index` + `names`: the full, lightweight view of the
///     vault (for count, search, and `isInVault`),
///   - `cache` of already-fetched card rows + `visible` (the current page
///     window) for the gallery,
///   - keyset-style pagination over `orderedIDs` (the manifest order for
///     browse, the index-matched order for search),
///   - optimistic add/remove with rollback on failure.
///
/// Fail-open: if `vault_items` doesn't exist yet (migration 022 not run)
/// or a load fails, the store surfaces the error in `loadState` and keeps
/// an empty cache, but never crashes the flows that call into it.
@MainActor
final class VaultStore: ObservableObject {
    static let shared = VaultStore()

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// `.failed(message, tableMissing)` — `tableMissing` is true when
        /// the error looks like "migration 022 hasn't been run," so the
        /// UI can show setup-specific copy instead of a generic error.
        case failed(String, tableMissing: Bool)
    }

    /// Outcome of an add, so callers can toast precisely.
    enum AddOutcome: Equatable { case saved, alreadySaved, failed }

    /// The heavy card rows currently loaded for display (the paged window,
    /// in `orderedIDs` order). The gallery renders exactly this.
    @Published private(set) var visible: [SavedFood] = []
    @Published private(set) var loadState: LoadState = .idle
    /// True while a page fetch is in flight (drives the scroll-footer spinner).
    @Published private(set) var isLoadingPage = false
    /// Total foods in the vault (manifest count) — for the pill badge and
    /// header, independent of how many cards are currently paged in.
    @Published private(set) var totalCount = 0
    /// How many foods match the active search (`orderedIDs.count`). With no
    /// query this equals `totalCount`; when a search matches nothing it's 0.
    @Published private(set) var matchedCount = 0
    /// The trimmed query currently in effect (so the UI can distinguish
    /// "still loading the first page" from "searched, matched nothing").
    @Published private(set) var activeQuery = ""

    /// Lightweight full view of the vault: id + name for every food,
    /// newest first. Powers count, search, and membership without paying
    /// for the heavy payload.
    private var manifest: [VaultNameEntry] = []
    /// Inverted index over `manifest`, rebuilt on load and kept in lockstep.
    private var index = VaultSearchIndex()
    /// Normalized food names in the vault. Kept in lockstep with `manifest`
    /// so `isInVault` is O(1) and never touches the network.
    private var names: Set<String> = []
    /// Already-fetched card rows, by id. Survives re-sorts and re-searches
    /// so a food's heavy payload is fetched at most once per session.
    private var cache: [UUID: SavedFood] = [:]
    /// Ids in current display order: the manifest order for browse, the
    /// index-matched order for search (optionally A–Z).
    private var orderedIDs: [UUID] = []
    /// How many of `orderedIDs` have been paged into `visible`.
    private var loadedCount = 0
    /// Current display state.
    private var query = ""
    private var sortByName = false

    private let pageSize = 24
    private let service: VaultService
    private let imageService: FoodImageService
    private var hasLoaded = false

    init(service: VaultService = VaultService(),
         imageService: FoodImageService = FoodImageService()) {
        self.service = service
        self.imageService = imageService
    }

    // MARK: - Membership / derived (instant, local)

    /// True if a food with this (normalized) name is already in the vault.
    /// Uses the same normalization rule as the heart / repeat-detection so
    /// "Margherita Pizza" and "margherita pizza" are one food.
    func isInVault(foodName: String) -> Bool {
        names.contains(FavoritesStore.normalize(foodName))
    }

    var isEmpty: Bool { totalCount == 0 }

    /// True when more pages remain to load for the current display order.
    var canLoadMore: Bool { loadedCount < orderedIDs.count }

    /// True only when we *know* the backing table is missing (migration
    /// 022 hasn't been run). Used to hide the save-to-vault affordances so
    /// a tap can't fail with nothing but an error haptic. Distinct from a
    /// transient load error, where the vault stays available and retries.
    var isUnavailable: Bool {
        if case .failed(_, tableMissing: true) = loadState { return true }
        return false
    }

    // MARK: - Load

    /// Load the vault once per session. Idempotent — repeated calls no-op
    /// after the first success. Call after sign-in and when a vault
    /// surface appears.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// Force a fresh fetch (retry, pull-to-refresh, cross-surface sync).
    /// Rebuilds the manifest + index + names, then pages in the first
    /// screen of cards.
    func reload() async {
        loadState = .loading
        do {
            let fetched = try await service.nameManifest()
            manifest = fetched
            rebuildIndexAndNames()
            totalCount = manifest.count
            hasLoaded = true
            // Rebuild the display against the fresh manifest, preserving any
            // search/sort the user set while the load was in flight, then
            // page in the first screen of cards.
            activeQuery = query
            rebuildOrderedIDs()
            loadedCount = 0
            visible = []
            await loadNextPage()
            loadState = .loaded
        } catch {
            #if DEBUG
            NSLog("[Vault] load FAILED: %@", "\(error)")
            #endif
            let missing = Self.isTableMissing(error)
            loadState = .failed(Self.friendlyMessage(for: error, tableMissing: missing),
                                tableMissing: missing)
        }
    }

    private func rebuildIndexAndNames() {
        index = VaultSearchIndex(manifest.map { (id: $0.id, name: $0.foodName) })
        names = Set(manifest.map { FavoritesStore.normalize($0.foodName) })
    }

    // MARK: - Display (search + sort, local)

    /// Set the current search + sort. Filtering runs against the in-memory
    /// index (zero egress); pagination resets and the first page of the new
    /// order is fetched. No-ops if nothing changed.
    func setDisplay(query rawQuery: String, sortByName newSort: Bool) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query || newSort != sortByName else { return }
        query = trimmed
        sortByName = newSort
        activeQuery = trimmed
        rebuildOrderedIDs()
        loadedCount = 0
        visible = []
        Task { await loadNextPage() }
    }

    /// Recompute `orderedIDs` from the manifest for the current query + sort.
    /// Browse (no query) keeps manifest order (recency); search intersects
    /// with the index matches; A–Z sorts by name across the whole result.
    private func rebuildOrderedIDs() {
        let entries: [VaultNameEntry]
        if let matched = index.search(query) {
            entries = manifest.filter { matched.contains($0.id) }
        } else {
            entries = manifest
        }
        if sortByName {
            orderedIDs = entries
                .sorted { $0.foodName.localizedCaseInsensitiveCompare($1.foodName) == .orderedAscending }
                .map(\.id)
        } else {
            orderedIDs = entries.map(\.id)
        }
        matchedCount = orderedIDs.count
    }

    /// Fetch the next page of heavy card rows for the current order, pulling
    /// only the ids not already cached. Extends `visible`. Safe to call
    /// repeatedly (from an on-appear near the end of the grid).
    func loadNextPage() async {
        guard hasLoaded, !isLoadingPage, loadedCount < orderedIDs.count else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let start = loadedCount
        let end = min(start + pageSize, orderedIDs.count)
        let pageIDs = Array(orderedIDs[start..<end])
        let missing = pageIDs.filter { cache[$0] == nil }

        if !missing.isEmpty {
            do {
                let rows = try await service.cards(ids: missing)
                for row in rows { cache[row.id] = row }
            } catch {
                #if DEBUG
                NSLog("[Vault] page load FAILED: %@", "\(error)")
                #endif
                return   // leave loadedCount as-is; a later on-appear retries
            }
        }
        loadedCount = end
        recomputeVisible()
    }

    private func recomputeVisible() {
        visible = orderedIDs.prefix(loadedCount).compactMap { cache[$0] }
    }

    // MARK: - Mutations (optimistic)

    /// Save a food to the vault. Returns the outcome so the caller can
    /// toast. Guards against duplicates via the in-memory name set (the
    /// DB unique index is the backstop). Optimistic: reserves membership
    /// immediately so a double-tap can't double-insert, and rolls back on
    /// a genuine failure.
    @discardableResult
    func add(_ draft: NewVaultItem) async -> AddOutcome {
        let key = FavoritesStore.normalize(draft.foodName)
        guard !key.isEmpty else { return .failed }
        if names.contains(key) { return .alreadySaved }

        names.insert(key)   // optimistic reservation
        do {
            let inserted = try await service.insert(draft)
            insertLocally(inserted)
            return .saved
        } catch {
            #if DEBUG
            NSLog("[Vault] add FAILED for %@: %@", draft.foodName, "\(error)")
            #endif
            if Self.isUniqueViolation(error) {
                // Row already exists server-side (e.g. saved on another
                // device). Keep the reservation and refresh so the manifest
                // catches up; report as already-saved, not a failure.
                Task { await reload() }
                return .alreadySaved
            }
            names.remove(key)   // rollback
            return .failed
        }
    }

    /// Snapshot a logged meal (a `food_logs` row) into the vault.
    @discardableResult
    func add(from log: FoodLog) async -> AddOutcome {
        await add(NewVaultItem(from: log))
    }

    /// Insert a freshly-saved card into the manifest, index, name set, and
    /// card cache, and reflect it in the current display (prepended, since
    /// it's the newest).
    private func insertLocally(_ item: SavedFood) {
        manifest.insert(VaultNameEntry(id: item.id, foodName: item.foodName), at: 0)
        index.insert(id: item.id, name: item.foodName)
        names.insert(FavoritesStore.normalize(item.foodName))
        cache[item.id] = item
        totalCount = manifest.count
        rebuildOrderedIDs()
        // The window grew by one (the new item sits at/near the front in
        // browse; a search may filter it out, in which case the clamp drops
        // it back). Keep the already-loaded tail visible.
        if loadedCount > 0 { loadedCount = min(loadedCount + 1, orderedIDs.count) }
        recomputeVisible()
    }

    /// Remove a vault item by id. Optimistic: drops it locally first, rolls
    /// back if the delete fails so it doesn't silently vanish while still on
    /// the server.
    ///
    /// After the row is gone, best-effort clean up its stored photo — but
    /// only if no `food_logs` (or other `vault_items`) row still points at
    /// it. This is why deleting a food from the Vault never removes the
    /// photo from a meal still logged in the Tracker: `deleteUnreferenced`
    /// sees the log's reference and keeps the object. The card row (with its
    /// image paths) is taken from the cache, or fetched once if this item was
    /// never paged in.
    func remove(_ id: UUID) async {
        guard let manifestIdx = manifest.firstIndex(where: { $0.id == id }) else { return }
        let entry = manifest[manifestIdx]
        // Card row (for image cleanup) from the cache, or fetched once if
        // this item was never paged in. `await` can't live inside `??`'s
        // autoclosure, so resolve it explicitly.
        let card: SavedFood?
        if let cached = cache[id] {
            card = cached
        } else {
            card = (try? await service.cards(ids: [id]))?.first
        }

        removeLocally(id, name: entry.foodName)

        do {
            try await service.delete(id)
        } catch {
            #if DEBUG
            NSLog("[Vault] remove FAILED for %@: %@", id.uuidString, "\(error)")
            #endif
            reinsertLocally(entry, card: card, at: manifestIdx)
            return
        }

        if let card {
            let paths = [card.imagePath, card.imageThumbPath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !paths.isEmpty {
                try? await imageService.deleteUnreferenced(paths: paths)
            }
        }
    }

    private func removeLocally(_ id: UUID, name: String) {
        manifest.removeAll { $0.id == id }
        index.remove(id: id, name: name)
        // Only drop the name from the membership set if no other saved food
        // still normalizes to it (defensive — the unique index makes dups
        // impossible, but manifest is the source of truth here).
        let key = FavoritesStore.normalize(name)
        if !manifest.contains(where: { FavoritesStore.normalize($0.foodName) == key }) {
            names.remove(key)
        }
        cache[id] = nil
        totalCount = manifest.count
        let wasLoaded = orderedIDs.prefix(loadedCount).contains(id)
        rebuildOrderedIDs()
        if wasLoaded, loadedCount > 0 { loadedCount -= 1 }
        loadedCount = min(loadedCount, orderedIDs.count)
        recomputeVisible()
    }

    /// Restore a locally-removed item after a failed server delete. Position
    /// is best-effort (the item returns near its old manifest slot).
    private func reinsertLocally(_ entry: VaultNameEntry, card: SavedFood?, at manifestIdx: Int) {
        manifest.insert(entry, at: min(manifestIdx, manifest.count))
        index.insert(id: entry.id, name: entry.foodName)
        names.insert(FavoritesStore.normalize(entry.foodName))
        if let card { cache[entry.id] = card }
        totalCount = manifest.count
        rebuildOrderedIDs()
        loadedCount = min(loadedCount + 1, orderedIDs.count)
        recomputeVisible()
    }

    /// Remove whichever vault item matches this (normalized) food name.
    /// Convenience for the meal-card toggle, which knows the name but not
    /// the vault id.
    func remove(byFoodName name: String) async {
        let key = FavoritesStore.normalize(name)
        guard let entry = manifest.first(where: {
            FavoritesStore.normalize($0.foodName) == key
        }) else { return }
        await remove(entry.id)
    }

    /// Clear on sign-out so the next account starts clean.
    func clear() {
        manifest = []
        index = VaultSearchIndex()
        names = []
        cache = [:]
        orderedIDs = []
        loadedCount = 0
        query = ""
        sortByName = false
        activeQuery = ""
        visible = []
        totalCount = 0
        matchedCount = 0
        isLoadingPage = false
        hasLoaded = false
        loadState = .idle
    }

    // MARK: - Error helpers

    private static func isUniqueViolation(_ error: Error) -> Bool {
        let text = "\(error)".lowercased()
        return text.contains("23505") || text.contains("duplicate key")
    }

    /// Table-missing = migration 022 hasn't been run yet. PostgREST/Postgres
    /// surface this as `42P01 undefined_table` and/or a message naming the
    /// relation.
    static func isTableMissing(_ error: Error) -> Bool {
        let text = "\(error)".lowercased()
        if text.contains("42p01") { return true }
        return text.contains("vault_items")
            && (text.contains("does not exist")
                || text.contains("not found")
                || text.contains("could not find the table"))
    }

    static func friendlyMessage(for error: Error, tableMissing: Bool) -> String {
        tableMissing
            ? "Your vault isn't set up yet."
            : "Couldn't load your vault."
    }
}
