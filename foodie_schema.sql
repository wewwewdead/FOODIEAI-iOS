-- ============================================================================
-- FoodieAI iOS — Supabase Schema
-- Run this top-to-bottom in the Supabase SQL Editor on a fresh project.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. PROFILES — extends auth.users with app-specific data + daily goals
-- ----------------------------------------------------------------------------
create table public.profiles (
    id                    uuid primary key references auth.users(id) on delete cascade,
    display_name          text,
    avatar_url            text,
    daily_calorie_goal    int  not null default 2000,
    daily_carb_goal_g     int  not null default 250,
    daily_sugar_goal_g    int  not null default 50,
    created_at            timestamptz not null default now(),
    updated_at            timestamptz not null default now()
);

-- Auto-create a profile row whenever a new auth user signs up
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data->>'display_name',
            split_part(new.email, '@', 1)
        )
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- Generic updated_at trigger function (reused below)
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger profiles_set_updated_at
    before update on public.profiles
    for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. FOOD_LOGS — every analyzed meal
-- ----------------------------------------------------------------------------
create table public.food_logs (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null default auth.uid()
                        references auth.users(id) on delete cascade,

    food_name       text not null,
    image_path      text,                          -- key in the food-images bucket

    -- Macros (the 3 you had + 3 useful additions)
    calories        numeric(7,2) not null,
    carbs_g         numeric(7,2) not null,
    sugar_g         numeric(7,2) not null,
    protein_g       numeric(7,2),
    fat_g           numeric(7,2),
    fiber_g         numeric(7,2),

    -- Full Gemini analysis (previously discarded)
    benefits        text[] not null default '{}',
    drawbacks       text[] not null default '{}',
    nutrients       text[] not null default '{}',
    coach_name      text,
    coach_advice    text,

    -- eaten_at lets users back-date a meal; created_at is the audit timestamp
    eaten_at        timestamptz not null default now(),
    created_at      timestamptz not null default now()
);

-- Fast lookup of "this user's logs in this date range"
create index food_logs_user_eaten_idx
    on public.food_logs (user_id, eaten_at desc);

-- ----------------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY — enforce per-user isolation at the DB layer
-- ----------------------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.food_logs   enable row level security;

-- profiles: each user can read/update only their own profile
create policy "profiles_select_own"
    on public.profiles for select
    using (auth.uid() = id);

create policy "profiles_update_own"
    on public.profiles for update
    using (auth.uid() = id)
    with check (auth.uid() = id);

-- food_logs: full CRUD on own rows only
create policy "food_logs_select_own"
    on public.food_logs for select
    using (auth.uid() = user_id);

create policy "food_logs_insert_own"
    on public.food_logs for insert
    with check (auth.uid() = user_id);

create policy "food_logs_update_own"
    on public.food_logs for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "food_logs_delete_own"
    on public.food_logs for delete
    using (auth.uid() = user_id);

-- ----------------------------------------------------------------------------
-- 4. DAILY TOTALS VIEW — pre-aggregated daily macros
-- ----------------------------------------------------------------------------
create or replace view public.daily_food_totals
with (security_invoker = on) as
select
    user_id,
    (eaten_at at time zone 'UTC')::date  as day,
    count(*)                              as entries,
    coalesce(sum(calories),  0)::numeric(10,2) as total_calories,
    coalesce(sum(carbs_g),   0)::numeric(10,2) as total_carbs,
    coalesce(sum(sugar_g),   0)::numeric(10,2) as total_sugar,
    coalesce(sum(protein_g), 0)::numeric(10,2) as total_protein,
    coalesce(sum(fat_g),     0)::numeric(10,2) as total_fat,
    coalesce(sum(fiber_g),   0)::numeric(10,2) as total_fiber
from public.food_logs
group by user_id, (eaten_at at time zone 'UTC')::date;

-- security_invoker = on means the view runs under the calling user,
-- so the underlying food_logs RLS policies still apply.

-- ----------------------------------------------------------------------------
-- 5. STORAGE BUCKET — for food photos (private, per-user folders)
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('food-images', 'food-images', false)
on conflict (id) do nothing;

-- Convention: object name MUST start with "{user_id}/..." e.g. "abc-123/meal.jpg"
-- The policies below enforce that pattern.

create policy "food_images_select_own"
    on storage.objects for select
    using (
        bucket_id = 'food-images'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "food_images_insert_own"
    on storage.objects for insert
    with check (
        bucket_id = 'food-images'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "food_images_update_own"
    on storage.objects for update
    using (
        bucket_id = 'food-images'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "food_images_delete_own"
    on storage.objects for delete
    using (
        bucket_id = 'food-images'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- ============================================================================
-- Done. Verify with:
--   select * from public.profiles;
--   select * from public.food_logs;
--   select * from public.daily_food_totals;
-- ============================================================================
