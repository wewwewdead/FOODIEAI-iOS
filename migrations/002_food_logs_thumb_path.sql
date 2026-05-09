-- Phase 12: per-meal thumbnail object stored alongside the main image.
--
-- The iOS client uploads two JPEGs per save: a 1024px-long-edge "main"
-- (~80–150 KB) and a 256px-long-edge "thumb" (~10–25 KB). The thumb path
-- is what list/grid views load; the main path is reserved for a future
-- tap-to-zoom feature.
--
-- Pre-Phase-12 rows have NULL here. The MealRow component falls back to
-- image_path for those rows so legacy meals continue to render — slightly
-- wasteful (loads the larger object) but harmless and tapers off as
-- users save new meals.
--
-- No backfill: the original captured image isn't kept anywhere
-- retrievable, so we can't regenerate thumbnails for old rows without
-- re-running through the picker.
alter table public.food_logs
    add column if not exists image_thumb_path text;
