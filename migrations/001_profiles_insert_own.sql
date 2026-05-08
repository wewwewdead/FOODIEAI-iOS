-- 001_profiles_insert_own.sql
-- Belt-and-suspenders: allow a signed-in user to INSERT their own profile row
-- if the handle_new_user trigger didn't fire (e.g., schema-deployed-after-signup,
-- as encountered during Phase 7 verification with d73869bb-…).
-- The trigger remains the primary path; this is a safety net the iOS client
-- uses on first read when the row is missing.
--
-- RLS pattern matches food_logs_insert_own / profiles_update_own:
--   auth.uid() = id
--
-- Run in Supabase SQL Editor. Confirm appears in
--   Authentication → Policies → public.profiles
-- alongside profiles_select_own and profiles_update_own.

create policy "profiles_insert_own"
    on public.profiles for insert
    with check (auth.uid() = id);
