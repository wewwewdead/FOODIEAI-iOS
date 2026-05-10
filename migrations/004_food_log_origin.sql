-- Phase 15: distinguish original analyses from quick re-logs.
--
-- `origin = 'analyzed'`  → user took a photo and ran /analyze. Default.
--                           Existing pre-Phase-15 rows pick this up via
--                           the column default during ALTER.
-- `origin = 'relogged'`  → row was created by Quick Re-log. `source_log_id`
--                           points at the row whose data was copied. The
--                           image_path / image_thumb_path are reused (we
--                           don't re-upload), so two rows can reference
--                           the same Storage object.
--
-- The new index supports name-based repeat detection
-- (`MealHistoryService.priorOccurrences(of:)`). Postgres won't use it
-- for fuzzy / case-insensitive matches but exact-match heuristic v1
-- is sufficient.
--
-- ON DELETE SET NULL on source_log_id: if a user deletes the original
-- meal that a re-log points at, the re-log row stays — it represents
-- a real meal the user ate, with its own calorie/macro data already
-- frozen in place at insert time.

alter table public.food_logs
    add column if not exists origin text not null default 'analyzed'
        check (origin in ('analyzed', 'relogged'));

alter table public.food_logs
    add column if not exists source_log_id uuid
        references public.food_logs(id) on delete set null;

create index if not exists food_logs_user_food_name_idx
    on public.food_logs (user_id, food_name);
