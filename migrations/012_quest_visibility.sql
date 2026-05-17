-- Phase 21.12 — Quest visibility toggle.
--
-- Single additive column on `profiles` to gate the daily "Healthy
-- Choice" card on Home. Default true so existing users keep seeing
-- quests after the migration; the toggle lives in Profile → Preferences
-- for users who prefer a quieter Home.
--
-- No data migration is needed: the Phase 21.12 reframing also drops
-- five non-health quest kinds (`tryNewFood`, `logNewCuisine`,
-- `logThreeMeals`, `logBeforeTime`, `logDinnerEarly`) from the client
-- enum. Rows where `last_quest_kind` references one of those values
-- will fail to decode on the client; `DailyQuestService.todaysQuest`
-- already treats an unknown kind as "no stored quest for today" and
-- picks a fresh one, so the stale value is self-healing.

alter table public.profiles
    add column if not exists healthy_choices_enabled boolean not null default true;
