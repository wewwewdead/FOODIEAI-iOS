# Phase 23 — 3-Day Free Trial: Ship & Test Runbook

What's already coded (this repo + the server repo):
- **Client** — trial-led paywall, trial eligibility plumbing, `trial_started`
  analytics, and (new) every purchase is tagged with `appAccountToken` = the
  user's Supabase id so server notifications map back to the account.
- **Server** (`foodieAi.-main/server`) — `/subscription/validate` already
  entitles trial transactions (no change needed); **new** `POST
  /subscription/notifications` handles App Store Server Notifications V2
  (trial→paid, expiry, refund, revoke) so entitlement stays correct even when
  the app is closed.

Your server base URL (from `Secrets.xcconfig` → `ANALYZE_HOST`):
`https://foodieai-ios-server-production.up.railway.app`

So the **notification URL** is:
`https://foodieai-ios-server-production.up.railway.app/subscription/notifications`

---

## STEP 1 — Deploy the updated server

The notification endpoint must be live before Apple can deliver to it.

1. Commit + push the server changes (`routes/subscription.js`,
   `lib/storeKitVerify.js`) and deploy to Railway.
2. Confirm the env var **`APP_BUNDLE_ID = com.thefoodieai.app`** is set on the
   Railway service. `storeKitVerify` defaults to `com.thefoodieai.foodieai`; if
   it falls back to the default, **every** validation (trial or not) fails with
   "Bundle mismatch". (If prod purchases already work today, it's already set —
   just confirm.)
3. Smoke test the route is reachable:
   `curl -i -X POST https://foodieai-ios-server-production.up.railway.app/subscription/notifications -H 'content-type: application/json' -d '{}'`
   → expect **HTTP 400 `missing_signedPayload`** (that's success — the route
   exists and rejects an empty body).

---

## STEP 2 — App Store Connect: create the 3-day free trial

This is the ONLY thing that makes the trial appear in the app. Until it exists,
the paywall shows the plain price (the client degrades gracefully).

1. App Store Connect → your app → **Monetization → Subscriptions**.
2. Open the subscription group **"TheFoodieAi Pro"** → open **Pro Yearly**
   (`com.thefoodieai.pro.yearly`).
3. Find **Introductory Offers** → **Create / Set Up Introductory Offer**.
4. Configure:
   - **Countries/Regions:** All (or your targets)
   - **Start Date:** today · **End Date:** None (ongoing)
   - **Offer Type:** **Free**
   - **Duration:** **3 Days**
5. Save. (Intro offers don't need a new app binary, but the subscription
   product itself must be Approved / "Ready to Submit".)

Eligibility note: an intro offer is available only to users who haven't used one
in this subscription group before — expected, and matches the client's
`isEligibleForYearlyTrial` gate.

---

## STEP 3 — App Store Connect: register the Server Notifications V2 URL

1. App Store Connect → your app → **General → App Information**.
2. Scroll to **App Store Server Notifications**.
3. Set **Version 2** and paste the URL into **both**:
   - **Production Server URL:** `https://foodieai-ios-server-production.up.railway.app/subscription/notifications`
   - **Sandbox Server URL:** same URL (the payload's `data.environment` tells the
     server which one it is; the handler logs it).
4. Save.

> Labels shift between ASC releases; if you don't see it under App Information,
> look for "App Store Server Notifications" in the app's sidebar.

---

## STEP 4 — Verify the endpoint with a TEST notification

The handler special-cases Apple's `TEST` notification and returns 200.

- If ASC shows a **"Request a Test Notification"** button near the URL field,
  click it. Otherwise call the App Store Server API
  `POST /inApps/v1/notifications/test` (needs an App Store Connect API key).
- **Success looks like:** Railway logs print
  `[subscription.notifications] TEST received env=Sandbox — endpoint OK`
  and Apple reports a 200/delivered.

If you see 400 `invalid_signature`, the body wasn't a genuine Apple JWS (or the
URL is wrong). If you see 5xx, check the Supabase admin client / env.

---

## STEP 5 — Sandbox end-to-end test (the real thing)

Sandbox uses your **App Store Connect** config (the real intro offer), NOT the
local `.storekit` file — and it chains to Apple Root CA G3, so your server's JWS
verification actually passes (local `.storekit` does not).

### 5a. One-time setup
1. **Create a sandbox tester:** ASC → **Users and Access → Sandbox → Testers →
   ➕**. Use a brand-new email (need not be a real inbox). Save the
   email/password.
2. **⚠️ Turn OFF the local StoreKit config for this test** — otherwise it
   overrides Sandbox:
   Xcode → **Product → Scheme → Edit Scheme → Run → Options → StoreKit
   Configuration → None**. (Set it back to `FoodieAI.storekit` later for offline
   UI work.)
3. Use a **real device** (most reliable for Sandbox). Sign the build with the
   real bundle id `com.thefoodieai.app`.
4. On the device: **Settings → App Store → scroll to Sandbox Account → Sign
   Out** (so the purchase sheet prompts for your sandbox tester).

### 5b. Run the trial
1. Build & run from Xcode onto the device. Complete onboarding to the offer
   step (or open the paywall from Profile).
2. You should see **"Try Pro, free for 3 days"**, the trial timeline, and CTA
   **"Start my 3-day free trial."** (If it shows the plain price, the intro
   offer isn't live/propagated yet — can take a bit after Step 2.)
3. Tap it → in the purchase sheet, sign in with the **sandbox tester** →
   confirm.
4. **Expect:**
   - App flips to Pro / "Unlimited".
   - Railway: `[subscription.validate] pro granted user=… product=com.thefoodieai.pro.yearly`.
   - Analytics: `pro_purchased` + `trial_started`.

### 5c. Watch the trial convert (this is what ASSN hardens)
Sandbox compresses time. Approx renewal durations:
`1 week → 3 min · 1 month → 5 min · 1 year → 1 hour`; a **3-day trial converts
in a few minutes**.

- Leave it a few minutes (you can even background/close the app to prove the
  server-side path). When the trial converts, Apple sends **DID_RENEW** to your
  Sandbox URL.
- **Expect** in Railway:
  `[subscription.notifications] type=DID_RENEW/… env=Sandbox user=<uuid> → pro expires=<~1h out> product=com.thefoodieai.pro.yearly rows=1`
- `rows=1` confirms the `appAccountToken → profiles.id` mapping worked. `rows=0`
  means the purchase had no token (a pre-change purchase) — re-test with a fresh
  sandbox buy from the updated build.

### 5d. Test cancel / expiry
- Cancel: **Settings → App Store → Sandbox Account → Manage → cancel**, or via
  the sandbox subscription management sheet. After the period, Apple sends
  **EXPIRED** → server sets the user back to **free** → app reflects it on next
  status refresh.

### 5e. Re-test the trial
Sandbox testers can only use the intro offer once per "lifetime" unless reset:
ASC → **Users and Access → Sandbox → Testers → (tester) → Clear Purchase
History** (or make a new tester).

---

## Gotchas checklist
- [ ] Server deployed with `/subscription/notifications` live (Step 1 curl → 400).
- [ ] `APP_BUNDLE_ID = com.thefoodieai.app` on Railway.
- [ ] Intro offer created on the **yearly** product (Step 2).
- [ ] ASSN **V2** URL set for **both** Production and Sandbox (Step 3).
- [ ] TEST notification logged 200 (Step 4).
- [ ] **StoreKit Configuration = None** in the scheme while Sandbox testing
      (re-enable `FoodieAI.storekit` for offline UI work afterward).
- [ ] Fresh sandbox purchase shows `rows=1` in the DID_RENEW log.

## Known simplifications (fine for launch; future hardening)
- Billing **grace period** isn't specially handled (your `.storekit` has grace
  disabled). A grace-period user would read `free` until billing recovers.
- Notification mapping relies on `appAccountToken`, set going forward. Purchases
  made **before** this change carry no token (`rows=0`, acked); those users are
  still covered by the client's own re-validation on launch. To also map legacy
  subs server-side, persist `original_transaction_id → user` in `validate` and
  look it up as a fallback.
