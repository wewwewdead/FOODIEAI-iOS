import Foundation
import Supabase

/// Phase 23 — the Vault. Thin persistence boundary over
/// `public.vault_items`. RLS scopes every query to the signed-in user
/// (`auth.uid()`), so no query here filters on `user_id` and inserts
/// never send it.
///
/// Mirrors `FoodLogService`'s shape (an `actor` wrapping the shared
/// client). Caching + optimistic UI live one layer up in `VaultStore`.
actor VaultService {
    private let client: SupabaseClient

    init(client: SupabaseClient = FoodieClient.shared) {
        self.client = client
    }

    /// The lightweight name manifest for the WHOLE vault, newest first:
    /// just `id` + `food_name` per row. This is the only unbounded fetch,
    /// and it's deliberately tiny (two short strings per food) so it scales
    /// to a large vault without hurting egress. `VaultStore` builds its
    /// search index off this and pages in the heavy card rows separately.
    func nameManifest() async throws -> [VaultNameEntry] {
        try await client
            .from("vault_items")
            .select("id,food_name")
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Fetch the full card rows for a batch of ids (one page of the gallery).
    /// The heavy analysis payload is only ever fetched for foods actually on
    /// screen. Order isn't guaranteed here — `VaultStore` re-orders by its
    /// manifest/display order.
    func cards(ids: [UUID]) async throws -> [SavedFood] {
        guard !ids.isEmpty else { return [] }
        return try await client
            .from("vault_items")
            .select()
            .in("id", values: ids.map { $0.uuidString })
            .execute()
            .value
    }

    /// Insert a vault item. Returns the persisted row. `NewVaultItem`
    /// omits `user_id`; the DB default fills it from `auth.uid()`.
    ///
    /// A unique `(user_id, lower(btrim(food_name)))` index backstops
    /// duplicates. Callers guard with `VaultStore`'s in-memory name set
    /// first so a dup never reaches the network on the happy path; a
    /// `23505` conflict here is interpreted by `VaultStore` as "already
    /// saved" rather than a hard failure.
    @discardableResult
    func insert(_ draft: NewVaultItem) async throws -> SavedFood {
        try await client
            .from("vault_items")
            .insert(draft, returning: .representation)
            .single()
            .execute()
            .value
    }

    func delete(_ id: UUID) async throws {
        try await client
            .from("vault_items")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}
