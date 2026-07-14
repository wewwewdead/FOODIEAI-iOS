-- 017_analytics_revenue_accuracy.sql
--
-- Corrects the funnel so "paid" means REAL revenue, not free-trial starts.
--
-- The client used to fire `pro_purchased` the instant a purchase succeeded —
-- but a free-trial start "succeeds" immediately, so trials were being counted
-- as revenue. Fixed event model:
--   trial_started        (client) a FREE trial began — NOT revenue
--   pro_purchased        (client) a DIRECT paid purchase (no trial) — revenue
--   subscription_renewed (server, DID_RENEW) a paid renewal, INCLUDING the
--                        first one after a trial → this is the true trial→paid
--                        conversion (the client can't see the app-closed event)
--   subscription_expired (server, EXPIRED)
--
-- Run in the Supabase SQL Editor. We DROP + CREATE (not create-or-replace)
-- because the column set changes (paid→paying, +trial_converted, etc.), and
-- Postgres won't let create-or-replace drop/rename/reorder view columns.
-- Supersedes the funnel views from 015; onboarding_quality from 015 is unchanged.

-- Overall funnel, last 30 days — now with honest revenue semantics.
drop view if exists public.analytics_funnel_30d;
create view public.analytics_funnel_30d as
with base as (
  select * from public.analytics_events
  where occurred_at > now() - interval '30 days'
),
per_user as (
  select
    user_id,
    bool_or(name = 'onboarding_signed_in')  as signed_in,
    bool_or(name = 'onboarding_completed')   as completed,
    bool_or(name = 'paywall_viewed')         as saw_paywall,
    bool_or(name = 'trial_started')          as started_trial,
    bool_or(name = 'subscription_renewed')   as renewed,
    bool_or(name = 'pro_purchased')          as direct_purchase
  from base
  group by user_id
)
select
  count(*) filter (where signed_in)                     as signed_in,
  count(*) filter (where completed)                     as completed,
  count(*) filter (where saw_paywall)                   as saw_paywall,
  count(*) filter (where started_trial)                 as started_trial,
  -- true trial→paid: started a trial AND later had a paid renewal
  count(*) filter (where started_trial and renewed)     as trial_converted,
  count(*) filter (where direct_purchase)               as direct_purchases,
  -- real paying customers: a direct buy OR any paid renewal
  count(*) filter (where direct_purchase or renewed)    as paying,
  round(100.0 * count(*) filter (where started_trial and renewed)
        / nullif(count(*) filter (where started_trial), 0), 1) as pct_trial_to_paid
from per_user;

-- Daily trend — `paying` now counts real revenue events (direct buys +
-- renewals/conversions), so a trial START day doesn't look like revenue; the
-- CONVERSION day (DID_RENEW) does. (drop+create: `paid` column renamed to `paying`.)
drop view if exists public.analytics_onboarding_daily;
create view public.analytics_onboarding_daily as
select
  date_trunc('day', occurred_at)::date                                 as day,
  count(distinct user_id) filter (where name = 'onboarding_signed_in') as signed_in,
  count(distinct user_id) filter (where name = 'onboarding_completed')  as completed,
  count(distinct user_id) filter (where name = 'paywall_viewed')        as saw_paywall,
  count(distinct user_id) filter (where name = 'trial_started')         as started_trial,
  count(distinct user_id) filter (where name in ('pro_purchased', 'subscription_renewed'))
                                                                        as paying
from public.analytics_events
where occurred_at > now() - interval '90 days'
group by 1
order by 1 desc;

-- Access control (create-or-replace keeps grants, but re-assert to be safe).
revoke all on public.analytics_funnel_30d       from anon, authenticated;
revoke all on public.analytics_onboarding_daily from anon, authenticated;
grant select on public.analytics_funnel_30d       to service_role;
grant select on public.analytics_onboarding_daily to service_role;
