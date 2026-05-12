-- Phase 20 — User physiology.
--
-- Six additive, nullable columns on `profiles` that hold the inputs
-- required to compute a personalized calorie + macro target via the
-- Mifflin-St Jeor BMR equation, standard activity multipliers, and
-- the USDA Dietary Guidelines macro split.
--
-- NULL == "not collected yet"; users who skip the physiology step keep
-- the archetype-based defaults from Phase 19. The compute step happens
-- entirely on the client (Core/CalorieGoalCalculator.swift) and writes
-- back into the existing daily_*_goal_* columns, so no view changes.
--
-- Check constraints reject only physically nonsensical values (under-13
-- age, sub-30 kg weight, etc.) while leaving room for the full population
-- of legitimate adult users.

alter table public.profiles
    add column if not exists biological_sex text
        check (biological_sex is null
               or biological_sex in ('male', 'female', 'unspecified')),
    add column if not exists age_years integer
        check (age_years is null or (age_years >= 13 and age_years <= 120)),
    add column if not exists height_cm numeric(5,1)
        check (height_cm is null or (height_cm >= 100 and height_cm <= 250)),
    add column if not exists weight_kg numeric(5,1)
        check (weight_kg is null or (weight_kg >= 30 and weight_kg <= 300)),
    add column if not exists activity_level text
        check (activity_level is null
               or activity_level in ('sedentary', 'light', 'moderate', 'very', 'extra')),
    add column if not exists weight_goal_direction text
        check (weight_goal_direction is null
               or weight_goal_direction in ('lose', 'maintain', 'gain'));
