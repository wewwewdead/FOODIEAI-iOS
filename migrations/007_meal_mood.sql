-- Phase 18: post-save mood pulse stored on each meal.
--
-- Three values, nullable. Existing rows pre-Phase-18 stay NULL (additive
-- migration); the post-save pulse can also be dismissed without an answer
-- so a fresh row is born NULL too. The partial index supports the future
-- mood-cluster pattern query without bloating the index for the common
-- "no mood recorded" case.
--
-- The three values are deliberately small. Five options would be more
-- granular but would dilute signal — three forces a real choice. The
-- naming avoids clinical language: loved / fine / tough rather than
-- positive / neutral / negative.
--
-- RLS: mood lives on `food_logs`, so the existing per-user policies
-- (food_logs_select_own, food_logs_update_own, food_logs_insert_own,
-- food_logs_delete_own) protect it for free.

alter table public.food_logs
    add column if not exists mood text
        check (mood is null or mood in ('loved', 'fine', 'tough'));

create index if not exists food_logs_user_mood_idx
    on public.food_logs (user_id, mood)
    where mood is not null;

-- Weekly recap mood summary --------------------------------------
-- Phase 18 also surfaces the week's emotional shape on the recap.
-- Optional column; the server returns NULL when fewer than 3 meals
-- in the week have mood labels (not enough signal to summarize).
alter table public.weekly_recaps
    add column if not exists mood_summary text;
