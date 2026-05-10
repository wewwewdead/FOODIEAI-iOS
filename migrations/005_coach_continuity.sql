-- Phase 16 — Coach Continuity.
--
-- Adds per-user coach preferences and a `coach_observations` table for
-- the editorial card the coach posts on Today between meals.
--
-- Why a separate table for observations (instead of e.g. a column on
-- food_logs): an observation is decoupled from any single meal — it's
-- generated from a *pattern* (Phase 15's MealHistoryService.Pattern),
-- and lives across days. Phase 17's weekly recap reads from this table
-- to summarize the coach's voice over time.
--
-- RLS mirrors food_logs / profiles: the four-policy pattern (select /
-- insert / update / delete) all gated on `auth.uid() = user_id`. We
-- enable update because dismissals set `dismissed_at` in place rather
-- than deleting the row (we want the dismissal history for dedup and
-- recap, even if the card itself is hidden from Today).

-- 1. Coach preferences on profiles ---------------------------------
--
-- text[] of coach names in user-preference order. First element = most
-- preferred. Empty array = no preference, server picks any. Existing
-- rows pick this up via the column default during ALTER.
alter table public.profiles
    add column if not exists preferred_coaches text[] not null default '{}';

-- 2. coach_observations -------------------------------------------
create table if not exists public.coach_observations (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null default auth.uid()
                        references auth.users(id) on delete cascade,
    coach_name      text not null,
    body            text not null,
    -- Mirrors the raw values of the Swift `Pattern.Kind` enum
    -- ("frequent", "firstThisWeek", "streak"). Nullable because future
    -- observations may not be derived from a single Pattern (e.g.,
    -- weekly recap rollups).
    pattern_kind    text,
    -- The food name (or nutrient label) the observation centers on.
    -- Used by the dedup-by-subject guardrail in
    -- CoachObservationService.generateIfNeeded — we won't re-generate
    -- the same (kind, subject) within a 7-day window.
    pattern_subject text,
    -- Set when the user dismisses the card. NULL = active.
    dismissed_at    timestamptz,
    created_at      timestamptz not null default now()
);

create index if not exists coach_observations_user_created_idx
    on public.coach_observations (user_id, created_at desc);

-- Optional supporting index for the dedup-by-subject query (filters by
-- user_id + pattern_kind + pattern_subject within a 7-day window).
-- Cheap; the table is per-user low-volume.
create index if not exists coach_observations_user_subject_idx
    on public.coach_observations (user_id, pattern_kind, pattern_subject);

alter table public.coach_observations enable row level security;

-- Re-runnable: drop existing policies of the same name first so applying
-- this migration twice doesn't error on duplicate-policy.
drop policy if exists coach_observations_select_own on public.coach_observations;
drop policy if exists coach_observations_insert_own on public.coach_observations;
drop policy if exists coach_observations_update_own on public.coach_observations;
drop policy if exists coach_observations_delete_own on public.coach_observations;

create policy coach_observations_select_own
    on public.coach_observations for select
    using (auth.uid() = user_id);

create policy coach_observations_insert_own
    on public.coach_observations for insert
    with check (auth.uid() = user_id);

create policy coach_observations_update_own
    on public.coach_observations for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy coach_observations_delete_own
    on public.coach_observations for delete
    using (auth.uid() = user_id);
