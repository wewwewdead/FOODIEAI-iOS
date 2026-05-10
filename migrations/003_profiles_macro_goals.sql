-- Phase 14+: per-user goals for protein, fat, and fiber.
--
-- The base schema (foodie_schema.sql) only persisted three daily goals
-- (calories / carbs / sugar). Tracker's TodayView already renders bars
-- for protein, fat, and fiber, but their denominators were hard-coded to
-- design-reference constants (90 g / 70 g / 28 g) because there was no
-- column to drive them per-user. This migration adds the missing
-- columns so the Profile editor can expose them as steppers and the
-- shared `ProfileStore` can read them like the other three.
--
-- Defaults match the design-reference constants the client used before
-- this migration, so existing rows are visually unchanged after
-- backfill — the user only notices a difference once they edit one of
-- the new steppers.
--
-- Bounds via CHECK constraints mirror the steppers' iOS-side ranges:
--   protein: 0 – 1000 g
--   fat:     0 – 1000 g
--   fiber:   0 – 500 g
-- These keep DB bytes sane against malformed payloads even though the
-- client also clamps via `Stepper(in:)`.
alter table public.profiles
    add column if not exists daily_protein_goal_g int not null default 90,
    add column if not exists daily_fat_goal_g     int not null default 70,
    add column if not exists daily_fiber_goal_g   int not null default 28;

alter table public.profiles
    drop constraint if exists profiles_daily_protein_goal_g_check,
    drop constraint if exists profiles_daily_fat_goal_g_check,
    drop constraint if exists profiles_daily_fiber_goal_g_check;

alter table public.profiles
    add constraint profiles_daily_protein_goal_g_check
        check (daily_protein_goal_g between 0 and 1000),
    add constraint profiles_daily_fat_goal_g_check
        check (daily_fat_goal_g     between 0 and 1000),
    add constraint profiles_daily_fiber_goal_g_check
        check (daily_fiber_goal_g   between 0 and 500);

-- No RLS changes: the existing `profiles_select_own` / `profiles_update_own`
-- policies already gate access by `auth.uid() = id`, and the new columns
-- inherit that protection automatically. The client-side ProfileUpdate
-- patch (added in the matching iOS change) won't include these fields
-- when null, so partial updates remain safe.
