-- Phase 19 — Onboarding state.
--
-- Track onboarding completion server-side so the v2 flow doesn't
-- re-appear on a different device after the user finishes it once.
-- `onboarding_completed_at` is the gate; existing accounts have NULL
-- and so will see v2 onboarding once (they can skip every screen).
--
-- `onboarding_archetype` records the answer to the goal-framing
-- question. Persisted because future phases may bias defaults
-- (different empty states for "lose weight" vs "build muscle"
-- users, different coach voice biasing, etc.). Constrained to the
-- four canonical values; non-clinical framings on purpose.
--
-- Both columns are nullable / additive; the migration is safe to run
-- against an existing project that already has Phase 17 reminders.

alter table public.profiles
    add column if not exists onboarding_completed_at timestamptz,
    add column if not exists onboarding_archetype text
        check (onboarding_archetype is null
               or onboarding_archetype in ('aware', 'lose_weight', 'build_muscle', 'curious'));
