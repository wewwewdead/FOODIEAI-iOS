-- asa_cost_per_payer.sql
-- Weekly Apple Search Ads optimization: rank keywords by the users they turn
-- into PAYING subscribers, not just installs.
--
-- How the data gets here: once a build with `SearchAdsAttribution` is live
-- (>= 1.0.4 build 10), the app resolves which ASA keyword drove each install
-- via Apple's first-party AdServices API and stamps `asa_*` keys onto every
-- analytics event's `props` (jsonb). So `trial_started` / `pro_purchased`
-- events carry the keyword that produced them.
--
-- Run these in the Supabase SQL editor (service role / editor bypasses RLS, so
-- you see all users' events, not just your own). Nothing here writes data.
--
-- Table shape (see migrations/014_analytics_events.sql):
--   analytics_events(id, user_id, name, props jsonb, session_id, occurred_at)
--   props values are strings, e.g. props->>'asa_keyword_id'.


-- =====================================================================
-- 1. SANITY CHECK — is attribution actually landing?
-- Run this first after the attribution build goes live. Expect a mix of
-- 'true' (ad installs), 'false' (organic), and null (pre-resolve / old builds).
-- =====================================================================
select
    props ->> 'asa_attributed' as attributed,
    count(*)                    as events,
    count(distinct user_id)     as users
from analytics_events
where occurred_at >= now() - interval '7 days'
group by 1
order by users desc;


-- =====================================================================
-- 2. PAYERS + TRIALS PER KEYWORD — the weekly cost-per-payer input.
-- Cross-reference each keyword_id's `payers` with that keyword's spend from
-- the Search Ads dashboard:  cost per payer = ASA spend / payers.
-- Set the interval to match the spend window you're comparing against.
-- =====================================================================
with attributed as (
    select
        user_id,
        name,
        props ->> 'asa_campaign_id' as campaign_id,
        props ->> 'asa_keyword_id'  as keyword_id,
        occurred_at
    from analytics_events
    where occurred_at >= now() - interval '30 days'    -- match your ASA spend window
      and props ->> 'asa_keyword_id' is not null       -- ad-driven events only
)
select
    campaign_id,
    keyword_id,
    count(distinct user_id) filter (where name = 'trial_started') as trials,
    count(distinct user_id) filter (where name = 'pro_purchased') as payers,
    round(
        count(distinct user_id) filter (where name = 'pro_purchased')::numeric
        / nullif(count(distinct user_id) filter (where name = 'trial_started'), 0),
        2
    ) as trial_to_paid
from attributed
group by campaign_id, keyword_id
order by payers desc nulls last, trials desc;


-- =====================================================================
-- 2b. PAYERS PER KEYWORD — trial-aware (USE THIS, not #2, for the trial funnel).
--
-- Why #2 undercounts: it counts payers as `pro_purchased`, which only fires for
-- DIRECT (no-trial) buys. The paywall leads with the yearly FREE TRIAL, so the
-- real trial→paid conversion arrives days later as the SERVER-side
-- `subscription_renewed` event (app closed) — which carries NO asa_* props
-- (super-props are client-only). So #2 filters those out and shows
-- "trials, zero payers" for ad traffic even after money lands.
--
-- Fix: don't require the PAYMENT event to be attributed. Attribute each paying
-- user to the keyword from their OWN earliest asa-stamped event (trial_started /
-- attribution_resolved / any asa event), then group. A renewal is credited to
-- the keyword that drove that user's install.
-- =====================================================================
with user_keyword as (
    -- One keyword/campaign per user, from their earliest attributed event.
    -- NOT time-bounded: attribution is stamped once near install and is
    -- permanent for that user, even if the paying window is later.
    select distinct on (user_id)
        user_id,
        props ->> 'asa_campaign_id' as campaign_id,
        props ->> 'asa_keyword_id'  as keyword_id
    from analytics_events
    where props ->> 'asa_keyword_id' is not null
    order by user_id, occurred_at asc
),
user_status as (
    select
        user_id,
        bool_or(name = 'trial_started')                            as started_trial,
        -- real revenue: a direct buy OR any paid renewal (incl. trial→paid)
        bool_or(name in ('pro_purchased', 'subscription_renewed')) as paying
    from analytics_events
    where occurred_at >= now() - interval '30 days'    -- match your ASA spend window
    group by user_id
)
select
    k.campaign_id,
    k.keyword_id,
    count(*) filter (where s.started_trial) as trials,
    count(*) filter (where s.paying)        as payers,
    round(
        count(*) filter (where s.paying)::numeric
        / nullif(count(*) filter (where s.started_trial), 0),
        2
    ) as trial_to_paid
from user_keyword k
join user_status s using (user_id)
group by k.campaign_id, k.keyword_id
order by payers desc nulls last, trials desc;


-- =====================================================================
-- 2c. FULL FUNNEL PER KEYWORD — install → onboarding paywall → trial → pay.
--
-- Phase 24 made the onboarding offer step BE the real paywall, and every
-- `paywall_viewed` now carries props->>'context' ('onboarding' vs 'in_app').
-- This inserts the offer-exposure stage between install and trial so you can
-- tell WHICH failure a weak keyword has, instead of only seeing "few payers":
--   * high users, low saw_offer  -> that traffic bounces before finishing
--     onboarding (relevance/quality problem for the keyword, or a flow bug)
--   * high saw_offer, low trials -> they reach the offer but don't want it
--     (intent mismatch, e.g. a "free calorie counter" searcher)
--   * high trials, low payers    -> a trial->paid problem (price/product), not ads
--
-- Same attribution rule as #2b: credit each user to the keyword from their
-- EARLIEST asa-stamped event; payment/renewal events need not be attributed.
-- NOTE: saw_offer only fills in for installs on the Phase 24+ (context-tagged)
-- build. Earlier installs have untagged paywall_viewed and read 0 here, so read
-- this per-keyword funnel from the new build's ship date forward.
-- =====================================================================
with user_keyword as (
    select distinct on (user_id)
        user_id,
        props ->> 'asa_campaign_id' as campaign_id,
        props ->> 'asa_keyword_id'  as keyword_id
    from analytics_events
    where props ->> 'asa_keyword_id' is not null
    order by user_id, occurred_at asc
),
user_status as (
    select
        user_id,
        bool_or(name = 'onboarding_completed')                     as completed,
        bool_or(name = 'paywall_viewed'
                and props ->> 'context' = 'onboarding')            as saw_offer,
        bool_or(name = 'trial_started')                            as started_trial,
        -- real revenue: a direct buy OR any paid renewal (incl. trial->paid)
        bool_or(name in ('pro_purchased', 'subscription_renewed')) as paying
    from analytics_events
    where occurred_at >= now() - interval '30 days'    -- match your ASA spend window
    group by user_id
)
select
    k.campaign_id,
    k.keyword_id,
    count(*)                                  as users,
    count(*) filter (where s.completed)       as completed,
    count(*) filter (where s.saw_offer)       as saw_offer,
    count(*) filter (where s.started_trial)   as trials,
    count(*) filter (where s.paying)          as payers,
    -- with the one-tap paywall this should sit near 100%; a low value means that
    -- keyword's users aren't reaching the offer (quality/flow), not that it's weak
    round(100.0 * count(*) filter (where s.saw_offer)
          / nullif(count(*) filter (where s.completed), 0), 1)     as pct_completed_saw_offer,
    round(100.0 * count(*) filter (where s.started_trial)
          / nullif(count(*) filter (where s.saw_offer), 0), 1)     as pct_offer_to_trial,
    round(100.0 * count(*) filter (where s.paying)
          / nullif(count(*) filter (where s.started_trial), 0), 1) as pct_trial_to_paid
from user_keyword k
join user_status s using (user_id)
group by k.campaign_id, k.keyword_id
order by payers desc nulls last, trials desc;


-- =====================================================================
-- 3. CAMPAIGN-LEVEL ROLLUP — same as #2 but grouped by campaign only.
-- Good for deciding which campaigns to shift budget between.
-- =====================================================================
with attributed as (
    select
        user_id,
        name,
        props ->> 'asa_campaign_id' as campaign_id
    from analytics_events
    where occurred_at >= now() - interval '30 days'
      and props ->> 'asa_campaign_id' is not null
)
select
    campaign_id,
    count(distinct user_id) filter (where name = 'trial_started') as trials,
    count(distinct user_id) filter (where name = 'pro_purchased') as payers
from attributed
group by campaign_id
order by payers desc nulls last;


-- =====================================================================
-- 4. WHO IS EACH PAYER, AND WHICH KEYWORD DROVE THEM.
-- The aggregates above say a keyword has "1 payer" but not WHICH customer or
-- how valuable they are. A single annual buyer is worth ~12 monthlies, so the
-- keyword that produced the annual is worth far more than its payer count of 1.
-- This lists every currently-active PRODUCTION payer next to the
-- campaign/keyword from their EARLIEST asa-stamped event (same attribution rule
-- as #2b), with entitlement length so the annual whale is obvious at a glance.
--
-- A payer whose campaign_id/keyword_id comes back NULL is ORGANIC — no ad ever
-- attributed to them. That split (ad vs organic) is what tells you how much of
-- your revenue ASA actually earned.
-- =====================================================================
with user_keyword as (
    select distinct on (user_id)
        user_id,
        props ->> 'asa_campaign_id' as campaign_id,
        props ->> 'asa_keyword_id'  as keyword_id
    from analytics_events
    where props ->> 'asa_keyword_id' is not null
    order by user_id, occurred_at asc
)
select
    c.email,
    c.entitlement_length,
    case
        when c.entitlement_length >= interval '300 days' then 'annual'
        when c.entitlement_length >= interval '20 days'  then 'monthly'
        else 'new/short'
    end                                     as plan_guess,
    coalesce(k.keyword_id,  '(organic)')    as keyword_id,
    coalesce(k.campaign_id, '(organic)')    as campaign_id
from public.real_paying_customers c
left join user_keyword k on k.user_id = c.id
order by c.entitlement_length desc;


-- ---------------------------------------------------------------------
-- Turning this into cost per payer (the number that decides everything):
--   1. Pull spend per keyword (or per campaign) from the ASA dashboard for the
--      SAME window as the interval above.
--   2. Match on keyword_id / campaign_id (the dashboard shows the id next to
--      the keyword text, e.g. 12345 = "ai calorie counter").
--   3. cost per payer = ASA spend / payers.
--   4. Cut keywords with high or infinite cost per payer (spend, zero payers);
--      scale the low ones. Judge by this, never by cost per install.
-- ---------------------------------------------------------------------
