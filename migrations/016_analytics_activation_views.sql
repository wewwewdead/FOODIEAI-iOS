-- 016_analytics_activation_views.sql
--
-- Activation + retention views over analytics_events. For an AI app these
-- matter as much as the purchase funnel: AI apps monetize well but churn
-- faster, so "do onboarders actually use it, and do they come back?" is where
-- you protect MRR.
--
-- Run in the Supabase SQL Editor (service role — bypasses per-user RLS).
-- Underlying events (all confirmed firing in the app):
--   app_opened (launch), meal_analyzed (scan/aha), meal_saved (core action).
-- Service-role only, same as 015 — never granted to app clients.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Activation — of users who COMPLETED onboarding in the last 30 days, how
--    many went on to scan a meal (the "aha") and save one (the core action),
--    at any point on/after they onboarded.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.analytics_activation_30d as
with onboarders as (
  select user_id, min(occurred_at) as onboarded_at
  from public.analytics_events
  where name = 'onboarding_completed'
    and occurred_at > now() - interval '30 days'
  group by user_id
),
per_user as (
  select
    o.user_id,
    bool_or(e.name = 'meal_analyzed' and e.occurred_at >= o.onboarded_at) as analyzed,
    bool_or(e.name = 'meal_saved'    and e.occurred_at >= o.onboarded_at) as saved
  from onboarders o
  left join public.analytics_events e on e.user_id = o.user_id
  group by o.user_id
)
select
  count(*)                                                             as onboarders,
  count(*) filter (where analyzed)                                     as scanned_a_meal,
  count(*) filter (where saved)                                        as saved_a_meal,
  round(100.0 * count(*) filter (where analyzed) / nullif(count(*), 0), 1) as pct_scanned,
  round(100.0 * count(*) filter (where saved)    / nullif(count(*), 0), 1) as pct_saved
from per_user;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Retention — by the day a user was first seen (first app_opened), what
--    share came back the next day (D1) and a week later (D7). Last 90 days.
--    D1/D7 rows near "today" will look low simply because that day hasn't
--    happened yet — read cohorts old enough to have matured.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.analytics_retention as
with first_seen as (
  select user_id, min(occurred_at::date) as cohort_day
  from public.analytics_events
  where name = 'app_opened'
  group by user_id
),
opens as (
  select distinct user_id, occurred_at::date as open_day
  from public.analytics_events
  where name = 'app_opened'
)
select
  fs.cohort_day,
  count(distinct fs.user_id)                                                   as new_users,
  count(distinct d1.user_id)                                                   as returned_d1,
  count(distinct d7.user_id)                                                   as returned_d7,
  round(100.0 * count(distinct d1.user_id) / nullif(count(distinct fs.user_id), 0), 1) as pct_d1,
  round(100.0 * count(distinct d7.user_id) / nullif(count(distinct fs.user_id), 0), 1) as pct_d7
from first_seen fs
left join opens d1 on d1.user_id = fs.user_id and d1.open_day = fs.cohort_day + 1
left join opens d7 on d7.user_id = fs.user_id and d7.open_day = fs.cohort_day + 7
where fs.cohort_day > now()::date - 90
group by fs.cohort_day
order by fs.cohort_day desc;

-- ─────────────────────────────────────────────────────────────────────────
-- Access control: service role only, never the client.
-- ─────────────────────────────────────────────────────────────────────────
revoke all on public.analytics_activation_30d from anon, authenticated;
revoke all on public.analytics_retention      from anon, authenticated;
grant select on public.analytics_activation_30d to service_role;
grant select on public.analytics_retention      to service_role;
