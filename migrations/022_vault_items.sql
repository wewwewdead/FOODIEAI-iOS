-- Phase 23: the Vault — a durable, user-curated library of saved foods.
--
-- Why a new table (and not the existing "favorites"):
--   * food_logs records what was eaten *when*. A log row is transient —
--     users delete old days, so it's not a lasting home for "foods I eat
--     often."
--   * FavoritesStore (on-device, name-only) surfaces a hearted meal only
--     while it's still inside the 30-day recent-meals window. Heart
--     something and skip it for a month and the favorite goes "dead."
--
-- vault_items is the lasting home. Each row is a frozen snapshot of a
-- food's analysis (name + 6 macros + benefits/drawbacks/nutrients + coach
-- copy) plus the Storage paths of its photo. Re-logging from the Vault
-- copies this snapshot into a fresh food_logs row (origin='relogged'),
-- reusing the same Storage objects — no re-upload, no re-analyze, no scan
-- credit. The columns mirror food_logs' analysis payload 1:1 so the app
-- can build a NewFoodLog from a vault item with a direct field copy.
--
-- source_log_id points back at the food_logs row the item was saved from,
-- when there was one. Nullable because "Save to Vault" from the result
-- screen happens before a log row necessarily exists, and ON DELETE SET
-- NULL keeps the vault item alive when that origin log is later deleted —
-- the whole point of the Vault outliving the daily log.

create table if not exists public.vault_items (
    id               uuid primary key default gen_random_uuid(),
    user_id          uuid not null default auth.uid()
                         references auth.users(id) on delete cascade,

    food_name        text not null,
    image_path       text,                         -- key in the food-images bucket
    image_thumb_path text,

    calories         numeric(7,2) not null,
    carbs_g          numeric(7,2) not null,
    sugar_g          numeric(7,2) not null,
    protein_g        numeric(7,2),
    fat_g            numeric(7,2),
    fiber_g          numeric(7,2),

    benefits         text[] not null default '{}',
    drawbacks        text[] not null default '{}',
    nutrients        text[] not null default '{}',
    coach_name       text,
    coach_advice     text,

    -- ON DELETE SET NULL: deleting the origin meal must not evict the
    -- vault item — it represents a food the user chose to keep.
    source_log_id    uuid references public.food_logs(id) on delete set null,
    created_at       timestamptz not null default now()
);

-- The user's vault, newest first (list query).
create index if not exists vault_items_user_created_idx
    on public.vault_items (user_id, created_at desc);

-- One vault entry per food name per user (case-insensitive). Makes
-- "Save to Vault" idempotent and enforces "don't store the same food
-- twice" at the DB layer. The client also guards with an in-memory
-- normalized-name set, so a duplicate never reaches the network on the
-- happy path; this index is the backstop against races / double-taps.
create unique index if not exists vault_items_user_name_uidx
    on public.vault_items (user_id, lower(btrim(food_name)));

-- ----------------------------------------------------------------------------
-- Row Level Security — full CRUD on own rows only. Same pattern as food_logs.
-- ----------------------------------------------------------------------------
alter table public.vault_items enable row level security;

create policy "vault_items_select_own"
    on public.vault_items for select
    using (auth.uid() = user_id);

create policy "vault_items_insert_own"
    on public.vault_items for insert
    with check (auth.uid() = user_id);

create policy "vault_items_update_own"
    on public.vault_items for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "vault_items_delete_own"
    on public.vault_items for delete
    using (auth.uid() = user_id);
