# Phase 22 — Pro/Free Tiers, Scan Limits, Paywall — Runbook

## What changed

### Server (`~/Downloads/foodieAi.-main/server`)

| File | Change |
| --- | --- |
| `lib/scanLimits.js` (new) | Shared JWT auth, local-date parsing, entitlement math, scan-count read/upsert. |
| `lib/storeKitVerify.js` (new) | StoreKit 2 JWS signature + Apple Root CA G3 chain verification. |
| `routes/gemini.js` | `/analyze` now JWT-auth'd; rejects over-limit users with structured 429; increments scan count on success. |
| `routes/subscription.js` (new) | `POST /subscription/validate`, `GET /subscription/status`. |
| `server.js` | Mounts `subscriptionRouter`. |

### iOS (`~/Desktop/foodieAi iOS`)

| File | Change |
| --- | --- |
| `migrations/013_subscription_and_scan_counts.sql` (new) | `profiles.tier`, `pro_expires_at`, `signup_date`; `daily_scan_counts` table; backfilled new-user trigger. |
| `FoodieAI/Services/SubscriptionManager.swift` (new) | StoreKit 2 load/purchase/restore + `Transaction.updates` + server mirror (`tier`, `dailyLimit`, `scansUsedToday`, `resetsAt`). |
| `FoodieAI/Services/AnalyzeService.swift` | Sends `Authorization: Bearer <jwt>` + `localDate` multipart field; decodes structured 429 into `AnalyzeError.scanLimitReached(ScanLimitInfo)`. |
| `FoodieAI/Features/Paywall/PaywallView.swift` (new) | Pro paywall — products from StoreKit, Restore Purchases, auto-renewal disclosure, Terms/Privacy links. |
| `FoodieAI/Features/Paywall/ScanLimitSheet.swift` (new) | Limit-reached sheet (Upgrade / Log Manually / Dismiss). |
| `FoodieAI/Features/Home/CaptureViewModel.swift` | `@Published scanLimitHit: ScanLimitInfo?`; increments mirror on success; routes 429 to sheet instead of `.failed`. |
| `FoodieAI/Features/Home/CaptureView.swift` | `.sheet(item: $viewModel.scanLimitHit) { ScanLimitSheet(...) }` + paywall sheet binding. Replaces `FreeTierLimits` placeholders with `SubscriptionManager`. |
| `FoodieAI/Core/FreeTierLimits.swift` | Deleted — superseded by `SubscriptionManager`. |
| `FoodieAI/FoodieAIApp.swift` | `subscriptions.bootstrap()` on launch; `refreshStatusFromServer()` on sign-in and foreground. |

Build status: `xcodebuild ... -scheme FoodieAI` → `** BUILD SUCCEEDED **`.

## Deploy order

1. **Run the SQL migration** in Supabase (Editor → New query → paste `migrations/013_subscription_and_scan_counts.sql`). Existing users will be backfilled to `signup_date` from `auth.users.created_at` so the first-7-days bonus computes correctly from day one.
2. **Deploy the server** (`server.js` + new `lib/*` + `routes/subscription.js`). Set the env var `APP_BUNDLE_ID` if it differs from `com.thefoodieai.foodieai` (e.g. `com.thefoodieai.foodieai.debug`). Existing env vars (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `GEMINI_API_KEY`) are unchanged.
3. **Build the iOS app** with the new files. The pbxproj has been updated to include the new sources and the `Features/Paywall` group.

## App Store Connect setup (manual — model owner)

These are blockers for App Review, **none of them is scriptable**, and they must be done before submitting the build that contains this code.

1. **Subscription group**
   - App Store Connect → your app → **Subscriptions** → create group **`FoodieAI Pro`**.
   - Add two auto-renewable products in the group (same group lets users upgrade/downgrade between them):
     - `com.thefoodieai.pro.monthly` — $2.99 / 1 month
     - `com.thefoodieai.pro.yearly` — $29 / 1 year
   - For each: localized **display name**, **description**, and a review **screenshot** of the paywall.
   - Add the auto-renewal legal text and link your EULA (or use Apple's standard).
   - Both must show **Ready to Submit** and be attached to the build's review submission.

2. **Sandbox tester**
   - Users and Access → Sandbox → **+** → create a tester account with a non-production email.
   - Settings → App Store → Sandbox Account on the device — sign in with this tester before tapping Purchase so charges don't hit a real Apple ID.

3. **Privacy + Terms URLs (BLOCKER)**
   - `https://thefoodieai.com/terms` and `https://thefoodieai.com/privacy` currently serve the homepage. App Review will reject. They must contain real policy text before submission.

4. **Receipt validation env var**
   - On Railway: set `APP_BUNDLE_ID` to match the build you're submitting (e.g. `com.thefoodieai.foodieai`). The validate endpoint rejects transactions whose `bundleId` doesn't match.

## Verification

### Server (CLI)

```bash
# Free user's 3rd scan in a day after first-week (limit=2) returns structured 429:
curl -i -X POST -F image=@/path/to/meal.jpg -F localDate=2026-05-24 \
  -H "Authorization: Bearer <user_jwt>" \
  https://foodieai-ios-server-production.up.railway.app/analyze
# Expect: HTTP/1.1 429
# {"error":"scan_limit_reached","limit":2,"tier":"free","resetsAt":"2026-05-25T00:00:00"}

# Status endpoint:
curl -s -H "Authorization: Bearer <user_jwt>" \
  "https://foodieai-ios-server-production.up.railway.app/subscription/status?localDate=2026-05-24" \
  | jq
# Expect: {"tier":"free","limit":2,"scansUsedToday":2,"resetsAt":"2026-05-25T00:00:00","proExpiresAt":null}
```

### iOS (Simulator + sandbox)

1. Sign in as a 7-day-old free account → status reports `limit: 2`. Brand-new account → `limit: 4`.
2. Take 2 photos (free, after week) → 3rd photo: limit sheet appears (NOT generic error).
3. Tap **Log this meal manually** on the limit sheet → manual log flow opens, save succeeds, manual log does **not** count against scans.
4. Tap **Upgrade to Pro** → paywall opens with both products' prices loaded from StoreKit (not hardcoded literals), monthly + yearly visible, yearly marked "Best value", Restore Purchases present.
5. Purchase yearly in sandbox → `tier=pro` server-side, status returns `limit: 10`, next /analyze succeeds.
6. Delete the app and reinstall while still signed into sandbox account → **Restore Purchases** re-grants Pro.
7. Sign in as a different account on a second simulator → independent count (no leakage).

## Known limitations / follow-ups

- **Renewals / cancellations**: V1 checks `pro_expires_at` on each request. A subscription that lapses mid-day will keep working until the next /analyze that re-reads `profiles`. The robust path is **App Store Server Notifications V2**: have Apple POST renewal/cancel events to a new route (`POST /subscription/apple-notification`) and update `pro_expires_at` server-side. Add this before scaling.
- **Privacy + Terms pages** are still pointing at the homepage. Update before submission.
- **No "Pro" badge** anywhere outside the paywall yet — v1 keeps the UI footprint minimal so Pro feels invisible aside from the higher cap. If a visible Pro badge is wanted post-launch, the `SubscriptionManager.tier` is already published and can drive a chip in Profile/Settings.
- **`/save` and `/getFoodLogs` legacy server endpoints** are unchanged (still deprecated; not used by iOS).
