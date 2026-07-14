-- 019_analytics_paywall_context.sql
--
-- Splits `paywall_viewed` by surface so the onboarding funnel stays honest.
--
-- Phase 24 made the onboarding offer step BE the real paywall (PaywallView is
-- now rendered inline, no more "Try Pro" tap to open it). Two consequences for
-- analytics:
--   1. `paywall_viewed` now fires for ~100% of onboarding completers instead of
--      the ~29% who used to tap through. The RAW count spikes BY DESIGN.
--   2. Every `paywall_viewed` now carries a `context` prop: 'onboarding' from
--      the onboarding step, 'in_app' from the post-onboarding upsells
--      (CaptureView / ProfileView / ScanLimitSheet / SubscriptionInfoView).
--
-- The funnel views from 015/017 counted `name = 'paywall_viewed'` with no
-- context filter, so they would now conflate onboarding exposure with in-app
-- upsells. This migration rescopes `saw_paywall` to the onboarding surface and
-- exposes the in-app count separately.
--
-- FORWARD-LOOKING: events fired BEFORE this deploy have no `context` prop
-- (props->>'context' IS NULL), so they fall out of the onboarding count and into
-- `saw_paywall_inapp` via the coalesce default. That's fine — pre-Phase-24
-- onboarding paywall views were a different (two-tap) event anyway, and test
-- rows get cleared before launch. Read the trend from the deploy date forward.
--
-- Run this whole file once in the Supabase SQL Editor (service role). DROP +
-- CREATE because the column set changes (Postgres won't add columns via
-- create-or-replace). Supersedes the paywall counts in 015 and 017;
-- onboarding_quality from 015 is unchanged.

-- ─────────────────────────────────────────────────────────────────────────
-- Overall conversion funnel, last 30 days — saw_paywall is now onboarding-only.
-- ─────────────────────────────────────────────────────────────────────────
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
    -- onboarding offer exposure: the paywall shown as the onboarding step
    bool_or(name = 'paywall_viewed'
            and props->>'context' = 'onboarding')          as saw_paywall,
    -- post-onboarding upsell exposure (NULL context defaults here for
    -- pre-Phase-24 rows; see the forward-looking note above)
    bool_or(name = 'paywall_viewed'
            and coalesce(props->>'context', 'in_app') = 'in_app') as saw_paywall_inapp,
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
  count(*) filter (where saw_paywall_inapp)             as saw_paywall_inapp,
  count(*) filter (where started_trial)                 as started_trial,
  -- true trial→paid: started a trial AND later had a paid renewal
  count(*) filter (where started_trial and renewed)     as trial_converted,
  count(*) filter (where direct_purchase)               as direct_purchases,
  -- real paying customers: a direct buy OR any paid renewal
  count(*) filter (where direct_purchase or renewed)    as paying,
  -- with the one-tap paywall this should sit near 100%; a dip means completers
  -- aren't reaching the offer step (investigate the flow, not the offer)
  round(100.0 * count(*) filter (where saw_paywall)
        / nullif(count(*) filter (where completed), 0), 1) as pct_complete_to_paywall,
  round(100.0 * count(*) filter (where started_trial)
        / nullif(count(*) filter (where saw_paywall), 0), 1) as pct_paywall_to_trial,
  round(100.0 * count(*) filter (where started_trial and renewed)
        / nullif(count(*) filter (where started_trial), 0), 1) as pct_trial_to_paid
from per_user;

-- ─────────────────────────────────────────────────────────────────────────
-- Daily onboarding funnel, last 90 days — saw_paywall onboarding-scoped, with
-- the in-app upsell count broken out alongside it.
-- ─────────────────────────────────────────────────────────────────────────
drop view if exists public.analytics_onboarding_daily;
create view public.analytics_onboarding_daily as
select
  date_trunc('day', occurred_at)::date                                 as day,
  count(distinct user_id) filter (where name = 'onboarding_signed_in') as signed_in,
  count(distinct user_id) filter (where name = 'onboarding_completed')  as completed,
  count(distinct user_id) filter (
    where name = 'paywall_viewed'
      and props->>'context' = 'onboarding')                            as saw_paywall,
  count(distinct user_id) filter (
    where name = 'paywall_viewed'
      and coalesce(props->>'context', 'in_app') = 'in_app')            as saw_paywall_inapp,
  count(distinct user_id) filter (where name = 'trial_started')         as started_trial,
  count(distinct user_id) filter (where name in ('pro_purchased', 'subscription_renewed'))
                                                                        as paying
from public.analytics_events
where occurred_at > now() - interval '90 days'
group by 1
order by 1 desc;

-- ─────────────────────────────────────────────────────────────────────────
-- Access control: service role only (SQL editor / server), never the client.
-- ─────────────────────────────────────────────────────────────────────────
revoke all on public.analytics_funnel_30d       from anon, authenticated;
revoke all on public.analytics_onboarding_daily from anon, authenticated;
grant select on public.analytics_funnel_30d       to service_role;
grant select on public.analytics_onboarding_daily to service_role;
