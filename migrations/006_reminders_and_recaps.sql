-- Phase 17 — Smart Reminders & Weekly Recap.
--
-- Two concerns in one migration:
--   1. Notification preferences on profiles. `notifications_enabled` is
--      the master gate; the three meal flags + recap flag are
--      independently togglable. Default `notifications_enabled = false`
--      so existing accounts don't get surprise nudges after the
--      migration runs — the user has to opt in via the permission flow.
--   2. `weekly_recaps` table — generated Sunday-evening summaries of
--      the prior week. Read-mostly: written once per (user, week_start)
--      via the unique constraint, surfaced via RecapView.
--
-- `time_zone` stores an IANA identifier ("Asia/Seoul"), NOT a UTC
-- offset (which would lose DST/timezone-policy changes). Captured by
-- the iOS client on auth bootstrap; re-synced when it changes.

-- 1. Notification prefs on profiles -------------------------------
alter table public.profiles
    add column if not exists notifications_enabled boolean not null default false,
    add column if not exists reminder_breakfast    boolean not null default true,
    add column if not exists reminder_lunch        boolean not null default true,
    add column if not exists reminder_dinner       boolean not null default true,
    add column if not exists weekly_recap_enabled  boolean not null default true,
    add column if not exists time_zone             text;

-- 2. weekly_recaps -----------------------------------------------
create table if not exists public.weekly_recaps (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null default auth.uid()
                        references auth.users(id) on delete cascade,
    -- Both bounds expressed as DATE in the user's local timezone (no
    -- ambiguity when the recap covers a week that crosses a DST
    -- transition).
    week_start      date not null,
    week_end        date not null,
    coach_name      text not null,
    body            text not null,
    headline_stat   text,
    top_pattern     text,
    created_at      timestamptz not null default now(),
    -- The unique constraint is the safety net for double-generation:
    -- the iOS orchestration also calls `latest()` first, but a race
    -- between two devices opened on Sunday evening could otherwise
    -- produce two recaps for the same week.
    unique (user_id, week_start)
);

create index if not exists weekly_recaps_user_week_idx
    on public.weekly_recaps (user_id, week_start desc);

alter table public.weekly_recaps enable row level security;

-- v1 ships without UPDATE / DELETE policies. Recaps are write-once.
-- If a recap regenerates incorrectly, the practical recovery is a
-- separate admin migration; we don't expose mutation through the
-- client API.

drop policy if exists weekly_recaps_select_own on public.weekly_recaps;
drop policy if exists weekly_recaps_insert_own on public.weekly_recaps;

create policy weekly_recaps_select_own
    on public.weekly_recaps for select
    using (auth.uid() = user_id);

create policy weekly_recaps_insert_own
    on public.weekly_recaps for insert
    with check (auth.uid() = user_id);
