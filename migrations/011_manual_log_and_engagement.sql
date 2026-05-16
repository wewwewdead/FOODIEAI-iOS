-- Phase 21 — Manual meal logs + daily-engagement state.
--
-- Two concerns combined into a single migration because they ship as
-- one product surface and the engagement state (streaks, quests) only
-- makes sense once manual logging exists as an input path.
--
-- 1. `origin = 'manual'` joins the existing analyzed/relogged values.
--    A manual log carries the same row shape as an analyzed one minus
--    image_path / image_thumb_path / coach_* (all already nullable).
--
-- 2. Seven additive columns on `profiles` track streak + quest state.
--    All have safe defaults so existing users decode cleanly without
--    a backfill: streak counters start at 0, grace at 1, quest fields
--    NULL until the user opens Today.
--
-- The streak math lives on the client (`StreakService`) — these
-- columns are storage only, no triggers, no computed views.
-- `grace_days_remaining` is capped at 2 by check constraint so a bug
-- in the refill logic can't grant infinite saves.

-- Drop and recreate the origin check so the new value is accepted.
alter table public.food_logs
    drop constraint if exists food_logs_origin_check;

alter table public.food_logs
    add constraint food_logs_origin_check
        check (origin in ('analyzed', 'relogged', 'manual'));

alter table public.profiles
    add column if not exists current_streak_days integer not null default 0,
    add column if not exists longest_streak_days integer not null default 0,
    add column if not exists last_logged_local_date date,
    add column if not exists grace_days_remaining integer not null default 1
        check (grace_days_remaining >= 0 and grace_days_remaining <= 2),
    add column if not exists last_quest_date date,
    add column if not exists last_quest_kind text,
    add column if not exists last_quest_completed boolean not null default false;
