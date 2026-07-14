-- 020_subscription_environment.sql
--
-- Records the App Store BILLING ENVIRONMENT (Sandbox vs Production) on each
-- Pro entitlement, so TestFlight / sandbox test purchases stop inflating the
-- real paying-customer count.
--
-- Why this exists:
--   The server writes pro_expires_at verbatim from Apple's signed transaction
--   (server/routes/subscription.js). In StoreKit's SANDBOX, subscription
--   durations are compressed (1 year -> 1 hour, 1 month -> 5 min), and
--   TestFlight ALWAYS bills against sandbox. So every time you or a tester
--   exercises the paywall, a "pro" row lands in profiles that looks identical
--   to a real customer. Without the environment tag they can't be told apart
--   (this is exactly why the 1-hour and 1-day "pro" rows appeared).
--
-- After this migration the server stamps subscription_env on /validate and on
-- the renewal webhook. Rows written BEFORE this migration keep it NULL
-- (unknown); the audit view below infers those from entitlement length as a
-- stopgap until each such user next re-validates.
--
-- DEPLOY ORDER (important): run THIS migration in the Supabase SQL Editor
-- FIRST, then redeploy the Railway server. If the server ships first it will
-- try to write a column that does not exist yet and every purchase validation
-- will 500 (real buyers blocked). Migration first, deploy second.

alter table public.profiles
    add column if not exists subscription_env text;

comment on column public.profiles.subscription_env is
    'App Store billing environment of the current Pro entitlement: '
    '"Production", "Sandbox", or "Xcode". Written by the server from the '
    'Apple-signed transaction. NULL = recorded before migration 020 (unknown).';

-- Audit view: every Pro row with an environment verdict. Uses the real tag
-- when known; for legacy NULL rows it FALLS BACK to a duration heuristic. No
-- real product is shorter than the 3-day trial, and every sandbox duration is
-- <= 1 hour (a sandbox yearly), so anything under ~2 days of entitlement is a
-- test purchase.
-- email lives in auth.users (profiles only holds the app fields), so join it
-- in the same way the ad-hoc pro-users query does. The view runs with its
-- owner's privileges, so the service_role reader still sees auth.users.email.
drop view if exists public.pro_customers_audit;
create view public.pro_customers_audit as
select
    p.id,
    u.email,
    p.display_name,
    p.tier,
    p.created_at,
    p.pro_expires_at,
    (p.pro_expires_at - p.created_at)          as entitlement_length,
    p.subscription_env,
    (p.pro_expires_at > now())                 as active_now,
    case
        when p.subscription_env in ('Sandbox', 'Xcode') then 'sandbox'
        when p.subscription_env = 'Production'           then 'production'
        -- legacy rows (env not recorded yet): infer from entitlement length.
        when (p.pro_expires_at - p.created_at) < interval '2 days'
                                                         then 'likely_sandbox'
        else 'likely_production'
    end                                        as environment_flag
from public.profiles p
left join auth.users u on u.id = p.id
where p.tier = 'pro'
  and p.pro_expires_at is not null;

-- The honest number to track: real, currently-active, production payers.
-- (Still includes the owner's own comp account if any — add
--  `and email <> 'you@example.com'` when you query it if you want it out.)
drop view if exists public.real_paying_customers;
create view public.real_paying_customers as
select *
from public.pro_customers_audit
where active_now
  and environment_flag in ('production', 'likely_production');

-- Service-role only, matching the other analytics views (015/017).
revoke all on public.pro_customers_audit     from anon, authenticated;
revoke all on public.real_paying_customers   from anon, authenticated;
grant select on public.pro_customers_audit   to service_role;
grant select on public.real_paying_customers to service_role;
