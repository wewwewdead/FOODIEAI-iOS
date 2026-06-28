-- 014_analytics_events.sql
-- First-party, privacy-respecting product analytics. No third-party SDK
-- (CLAUDE.md forbids third-party networking libraries) — events land in our
-- own Supabase table and are analyzed from the SQL editor / a service-role
-- job. The client only ever INSERTs its own rows.
--
-- Run this top-to-bottom in the Supabase SQL editor, like the rest of the
-- schema. Safe to re-run (idempotent guards throughout).

create table if not exists public.analytics_events (
    id          uuid        primary key default gen_random_uuid(),
    -- Defaulted from the JWT and pinned by RLS — never sent by the client.
    user_id     uuid        not null default auth.uid()
                            references auth.users (id) on delete cascade,
    -- Event name, e.g. 'meal_analyzed', 'app_opened'. See AnalyticsService.Event.
    name        text        not null,
    -- Free-form string-valued context (jsonb). Numbers are stored as strings
    -- in v1; query with `props->>'key'`.
    props       jsonb       not null default '{}'::jsonb,
    -- One id per app launch → lets queries derive sessions / DAU / retention.
    session_id  text,
    occurred_at timestamptz not null default now()
);

-- Query helpers: by user over time (retention cohorts) and by event name.
create index if not exists analytics_events_user_time_idx
    on public.analytics_events (user_id, occurred_at desc);
create index if not exists analytics_events_name_time_idx
    on public.analytics_events (name, occurred_at desc);

-- RLS: a signed-in user may only insert (and read) their own events. Cross-user
-- aggregate analysis is done with the service role / SQL editor, which bypasses
-- RLS — so no broad read policy is exposed to clients.
alter table public.analytics_events enable row level security;

drop policy if exists "analytics_insert_own" on public.analytics_events;
create policy "analytics_insert_own"
    on public.analytics_events
    for insert
    with check (auth.uid() = user_id);

drop policy if exists "analytics_select_own" on public.analytics_events;
create policy "analytics_select_own"
    on public.analytics_events
    for select
    using (auth.uid() = user_id);
