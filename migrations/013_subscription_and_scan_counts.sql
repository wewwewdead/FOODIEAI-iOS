-- Phase 22 — Pro/Free tiers + server-enforced daily scan limits.
--
-- Two changes:
--
-- 1) Three columns on `profiles` to carry the entitlement.
--      tier              'free' | 'pro' (default 'free')
--      pro_expires_at    when the active App Store subscription ends.
--                        Treat NULL or a past timestamp as "not pro".
--      signup_date       date the user first signed up. Drives the
--                        first-7-days bonus (4 scans/day vs 2). Backfilled
--                        from auth.users.created_at on the existing rows
--                        so the limit math is correct on day one.
--
-- 2) `daily_scan_counts` — one row per (user, user-local date) tallying
--    successful /analyze calls. The server increments on success only
--    (no row is created for over-limit, decode-failed, or 5xx requests).
--    `scan_date` is the user's LOCAL date — the client passes its
--    YYYY-MM-DD on each /analyze, so the bucket boundary is the user's
--    midnight, not UTC's. East-of-UTC users (e.g. KST/JST) get the
--    correct reset window.
--
-- RLS: the table is touched only by the service-role client on the
-- server. We enable RLS with no policies so an accidental anon-key
-- read returns zero rows rather than leaking another user's scan
-- history.

alter table public.profiles
    add column if not exists tier text not null default 'free'
        check (tier in ('free', 'pro')),
    add column if not exists pro_expires_at timestamptz,
    add column if not exists signup_date date;

-- Backfill signup_date for existing rows from auth.users.created_at.
-- After this point, new rows are seeded by the trigger below.
update public.profiles p
    set signup_date = (u.created_at at time zone 'UTC')::date
    from auth.users u
    where p.signup_date is null
      and p.id = u.id;

alter table public.profiles
    alter column signup_date set default (now() at time zone 'UTC')::date;

-- Extend the new-user trigger to stamp signup_date. The original
-- handle_new_user trigger lives in foodie_schema.sql and inserts only
-- (id, display_name); recreating it here is additive — existing trigger
-- behavior is preserved and signup_date is now seeded server-side so the
-- client never has to send it.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name, signup_date)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data->>'display_name',
            split_part(new.email, '@', 1)
        ),
        (new.created_at at time zone 'UTC')::date
    );
    return new;
end;
$$;

-- Scan-count ledger. Composite PK = (user_id, scan_date) — both
-- supports the upsert pattern and gives us a fast point lookup per
-- request without a separate index.
create table if not exists public.daily_scan_counts (
    user_id     uuid        not null references auth.users(id) on delete cascade,
    scan_date   date        not null,
    count       integer     not null default 0 check (count >= 0),
    updated_at  timestamptz not null default now(),
    primary key (user_id, scan_date)
);

alter table public.daily_scan_counts enable row level security;
-- No policies: only the service-role server reads/writes this table.

create trigger daily_scan_counts_set_updated_at
    before update on public.daily_scan_counts
    for each row execute function public.set_updated_at();
