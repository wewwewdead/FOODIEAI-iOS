-- 018_subscription_original_transaction_id.sql
--
-- Fixes stale pro_expires_at after an app-closed renewal.
--
-- App Store Server Notifications V2 (/subscription/notifications) is the ONLY
-- path that can refresh the entitlement when the app is never opened. It maps
-- each event to a user via the transaction's appAccountToken (== profiles.id),
-- which the iOS client only began stamping in Phase 23. Subscriptions bought
-- before that carry NO token, and every renewal INHERITS the original's
-- (missing) token — so DID_RENEW is unmappable forever and the column freezes
-- at whatever /subscription/validate last wrote (the initial app-open purchase).
--
-- Fix: give the webhook a second mapping key that legacy subs also carry.
-- Every StoreKit transaction (new or legacy) has a stable originalTransactionId.
-- /subscription/validate now stamps it onto the profile on the user's next
-- app-open / Restore, and /subscription/notifications falls back to it when
-- appAccountToken is absent.
--
-- Run in the Supabase SQL Editor.

alter table public.profiles
    add column if not exists app_original_transaction_id text;

-- The webhook looks a user up by this value on every token-less renewal, so
-- index it. Partial (non-null) keeps it small — only Pro rows ever set it.
create index if not exists profiles_app_original_transaction_id_idx
    on public.profiles (app_original_transaction_id)
    where app_original_transaction_id is not null;
