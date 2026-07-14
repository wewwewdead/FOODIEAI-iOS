-- 021_analytics_checkout_funnel.sql
--
-- Surfaces the MIDDLE of the paywall funnel that the daily onboarding view
-- (019) hides.
--
-- The problem: `analytics_onboarding_daily` jumps straight from `saw_paywall`
-- (paywall_viewed, onboarding) to `started_trial` (trial_started) to `paying`.
-- When saw_paywall is ~everyone and started_trial is ~0, that view can't say
-- WHERE the drop is: did they never tap the buy CTA (paywall problem), or tap
-- it and bail at Apple's sheet (price shock / Ask-to-Buy), or hit a technical
-- failure (StoreKit error / server receipt rejection)?
--
-- The events already exist — the client fires `checkout_started` the instant
-- the CTA is tapped (before StoreKit opens), then one of checkout_abandoned /
-- checkout_pending / checkout_failed / trial_validation_failed / trial_started /
-- pro_purchased. This view just splits the funnel by those events so the drop
-- is attributable.
--
-- NOTE ON CONTEXT: paywall_viewed / checkout_started / checkout_* all carry a
-- `context` prop ('onboarding' vs 'in_app'). The revenue events trial_started /
-- pro_purchased currently DO NOT (fired inside SubscriptionManager.purchase,
-- which doesn't know the surface), so those two columns are global, not
-- onboarding-scoped. During onboarding-heavy days that's close enough; the
-- follow-up is to thread `context` into the revenue events too.
--
-- CAVEAT: checkout_started shipped in the funnel-instrumentation build (early
-- Jul 2026). Days before users adopted that build show tapped_buy = 0 even when
-- purchases happened — read tapped_buy only from the adoption date forward.
--
-- Run this whole file once in the Supabase SQL Editor (service role).

drop view if exists public.analytics_checkout_funnel_daily;
create view public.analytics_checkout_funnel_daily as
select
  date_trunc('day', occurred_at)::date                                   as day,
  -- exposure: reached the onboarding paywall
  count(distinct user_id) filter (
    where name = 'paywall_viewed' and props->>'context' = 'onboarding')   as saw_paywall,
  -- intent: tapped Subscribe / Start-trial (fires BEFORE StoreKit opens)
  count(distinct user_id) filter (
    where name = 'checkout_started' and props->>'context' = 'onboarding')  as tapped_buy,
  count(distinct user_id) filter (
    where name = 'checkout_started' and props->>'context' = 'onboarding'
      and props->>'product' like '%yearly%')                             as tapped_yearly,
  count(distinct user_id) filter (
    where name = 'checkout_started' and props->>'context' = 'onboarding'
      and props->>'product' like '%monthly%')                            as tapped_monthly,
  -- outcomes (trial_started / pro_purchased are global; see NOTE above)
  count(distinct user_id) filter (where name = 'trial_started')          as started_trial,
  count(distinct user_id) filter (where name = 'pro_purchased')          as direct_purchase,
  -- leaks after the tap
  count(distinct user_id) filter (
    where name = 'checkout_abandoned' and props->>'context' = 'onboarding') as cancelled_sheet,
  count(distinct user_id) filter (
    where name = 'checkout_pending' and props->>'context' = 'onboarding')   as pending_asktobuy,
  count(distinct user_id) filter (
    where name = 'checkout_failed' and props->>'context' = 'onboarding')    as checkout_failed,
  count(distinct user_id) filter (
    where name = 'trial_validation_failed' and props->>'context' = 'onboarding') as validation_failed,
  -- the two rates that localize the drop
  round(100.0 * count(distinct user_id) filter (
          where name = 'checkout_started' and props->>'context' = 'onboarding')
        / nullif(count(distinct user_id) filter (
          where name = 'paywall_viewed' and props->>'context' = 'onboarding'), 0), 1)
        as pct_paywall_to_tap,
  round(100.0 * count(distinct user_id) filter (
          where name in ('trial_started', 'pro_purchased'))
        / nullif(count(distinct user_id) filter (
          where name = 'checkout_started' and props->>'context' = 'onboarding'), 0), 1)
        as pct_tap_to_buy
from public.analytics_events
where occurred_at > now() - interval '90 days'
group by 1
order by 1 desc;

-- Access control: service role only (SQL editor / server), never the client.
revoke all on public.analytics_checkout_funnel_daily from anon, authenticated;
grant select on public.analytics_checkout_funnel_daily to service_role;
