-- 015_analytics_funnel_views.sql
--
-- Saved aggregate views over analytics_events so "using the analytics" is a
-- one-line query instead of hand-writing funnel SQL each time.
--
-- WHERE TO RUN THEM: the Supabase SQL Editor (or any service-role connection).
-- The service role bypasses the per-user RLS on analytics_events, so these
-- return cross-user aggregates. They are deliberately NOT granted to the app's
-- anon/authenticated roles — a view over an RLS table would otherwise expose
-- everyone's data to any signed-in client. (Matches 014's "service role /
-- SQL editor" note.)
--
-- Run this whole file once in the SQL Editor to install the views.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Overall conversion funnel, last 30 days (distinct users per stage +
--    the stage-to-stage conversion rates that tell you WHERE to focus).
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.analytics_funnel_30d as
with base as (
  select * from public.analytics_events
  where occurred_at > now() - interval '30 days'
)
select
  count(distinct user_id) filter (where name = 'onboarding_signed_in') as signed_in,
  count(distinct user_id) filter (where name = 'onboarding_completed')  as completed,
  count(distinct user_id) filter (where name = 'paywall_viewed')        as saw_paywall,
  count(distinct user_id) filter (where name = 'trial_started')         as started_trial,
  count(distinct user_id) filter (where name = 'pro_purchased')         as paid,
  round(100.0 * count(distinct user_id) filter (where name = 'onboarding_completed')
        / nullif(count(distinct user_id) filter (where name = 'onboarding_signed_in'), 0), 1)
        as pct_signin_to_complete,
  round(100.0 * count(distinct user_id) filter (where name = 'paywall_viewed')
        / nullif(count(distinct user_id) filter (where name = 'onboarding_completed'), 0), 1)
        as pct_complete_to_paywall,
  round(100.0 * count(distinct user_id) filter (where name = 'trial_started')
        / nullif(count(distinct user_id) filter (where name = 'paywall_viewed'), 0), 1)
        as pct_paywall_to_trial,
  round(100.0 * count(distinct user_id) filter (where name = 'pro_purchased')
        / nullif(count(distinct user_id) filter (where name = 'trial_started'), 0), 1)
        as pct_trial_to_paid
from base;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Daily onboarding funnel (last 90 days) — trend + before/after view for
--    checking whether a change you shipped actually moved conversion.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.analytics_onboarding_daily as
select
  date_trunc('day', occurred_at)::date                                 as day,
  count(distinct user_id) filter (where name = 'onboarding_signed_in') as signed_in,
  count(distinct user_id) filter (where name = 'onboarding_completed')  as completed,
  count(distinct user_id) filter (where name = 'paywall_viewed')        as saw_paywall,
  count(distinct user_id) filter (where name = 'trial_started')         as started_trial,
  count(distinct user_id) filter (where name = 'pro_purchased')         as paid
from public.analytics_events
where occurred_at > now() - interval '90 days'
group by 1
order by 1 desc;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Onboarding quality (last 30 days) — how many reached the "aha" plan
--    reveal and personalized, read from onboarding_signed_in's props.
-- ─────────────────────────────────────────────────────────────────────────
create or replace view public.analytics_onboarding_quality as
select
  count(*)                                                     as signins,
  count(*) filter (where props->>'plan_revealed' = 'true')    as saw_plan_reveal,
  count(*) filter (where props->>'personalized'  = 'true')    as personalized,
  round(100.0 * count(*) filter (where props->>'plan_revealed' = 'true')
        / nullif(count(*), 0), 1)                             as pct_saw_plan_reveal
from public.analytics_events
where name = 'onboarding_signed_in'
  and occurred_at > now() - interval '30 days';

-- ─────────────────────────────────────────────────────────────────────────
-- Access control: service role only (SQL editor / server), never the client.
-- ─────────────────────────────────────────────────────────────────────────
revoke all on public.analytics_funnel_30d          from anon, authenticated;
revoke all on public.analytics_onboarding_daily    from anon, authenticated;
revoke all on public.analytics_onboarding_quality  from anon, authenticated;
grant select on public.analytics_funnel_30d         to service_role;
grant select on public.analytics_onboarding_daily   to service_role;
grant select on public.analytics_onboarding_quality to service_role;
