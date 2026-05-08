# Phase 7 — Profile + Daily Goals Verification

## Build & launch

Clean build for iPhone 17 simulator (iOS 26.4 sim runtime, iOS 17
deployment target, arm64 only):

```
xcodebuild … -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
…
** BUILD SUCCEEDED **
```

The Phase 4 keychain session for `johnmathewloren27@gmail.com`
(uid `d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb`) was preserved across all
Phase 7 installs by using `simctl install` in place rather than
`uninstall + install`.

## Pre-flight: missing `profiles` row

First run of `currentProfile()` returned `PostgrestError(PGRST116)
"Cannot coerce the result to a single JSON object"`. Diagnostic logging
(see "ProfileService instrumentation" in the decisions log) confirmed
**0 rows** for the user's UUID.

Cause: the `handle_new_user` trigger didn't fire when this user originally
signed up (the schema was likely installed after their `auth.users` row
already existed). Schema lacks a `profiles_insert_own` policy, so the
client cannot self-heal — the row had to be backfilled out-of-band.

**Manual fix you ran in SQL Editor:**

```sql
insert into public.profiles (id) values ('d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb');
```

After that, the next SELECT logged `[Profile] SELECT returned 1 row(s)`
and the rest of Phase 7 proceeded autonomously.

## Live read + UPDATE round-trip

Driven via `LAUNCH_PROFILE_UPDATE_PROBE=1`, a DEBUG-only bypass that
loads the profile, mutates the four drafts, and calls `save()` in
sequence — exercising the production `ProfileService.updateProfile`
pipeline without simulator UI taps.

**Console** (`screenshots/phase7/update.log`):

```
[Probe]   starting — loading profile
[Profile] SELECT profiles WHERE id=d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb
[Profile] SELECT returned 1 row(s)
[Probe]   load done — state=loaded(FoodieAI.Profile(
              id: D73869BB-8BB7-41FB-B7B3-3B2D6D1E39BB,
              displayName: nil,
              dailyCalorieGoal: 2000, dailyCarbGoalG: 250, dailySugarGoalG: 50,
              createdAt: 2026-05-08 13:15:48 +0000,
              updatedAt: 2026-05-08 13:15:48 +0000))
[Probe]   hasUnsavedChanges=true — calling save()
[Profile] UPDATE profiles SET (display_name=Phase 7 Probe cal=2200 carb=230 sugar=45)
                  WHERE id=d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb
[Profile] UPDATE returned id=D73869BB-8BB7-41FB-B7B3-3B2D6D1E39BB
                  updated_at=2026-05-08T13:22:42Z
[Probe]   save done — isSaving=false saveError=nil hasUnsavedChanges=false
```

What this proves end-to-end:
- **SELECT pre-populated drafts** from the live Postgres row (defaults: 2000/250/50, displayName nil from the backfill insert).
- **`hasUnsavedChanges` reactivity** — Combine pipeline observed all
  four drafts diverging from the loaded baseline and latched true
  100ms before `save()` was called.
- **UPDATE patch shape:** `display_name`, `daily_calorie_goal`,
  `daily_carb_goal_g`, `daily_sugar_goal_g`. No `id` in the body, no
  `user_id`, no `avatar_url` — just the four editable fields.
- **`.eq("id", value: <lowercased uuid>)`** — applied the Phase 6
  case-mismatch playbook preemptively. RLS policy `profiles_update_own
  → auth.uid() = id` accepted the update.
- **`updated_at` advanced** from `2026-05-08T13:15:48Z` (creation) to
  `2026-05-08T13:22:42Z` (just now) — DB returned the trigger-bumped
  timestamp from `set_updated_at`. Proves the row mutated in Postgres,
  not just memory.
- **`saveError = nil` and `hasUnsavedChanges = false`** post-save: VM
  reseeded drafts from the returned profile, Combine pipeline
  recomputed against the new baseline, button re-disabled.

## Persistence check (app restart)

After the UPDATE, the app was force-terminated and relaunched via
`LAUNCH_PROFILE_DIRECT=1`:

```
[Profile] SELECT profiles WHERE id=d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb
[Profile] SELECT returned 1 row(s)
```

`screenshots/phase7/03_after_relaunch.png` shows the production
`ProfileView` rendering the persisted values:

- Display name: **"Phase 7 Probe"**
- Calories: **2,200**
- Carbs (g): **230g**
- Sugar (g): **45g**
- Save changes button: **disabled** (drafts match DB)

Values came from a fresh Supabase SELECT post-relaunch — they survived
process kill, proving the UPDATE landed in Postgres, not memory.

## Sign-out flow

Driven via `LAUNCH_SIGN_OUT_PROBE=1`. Console
(`screenshots/phase7/signout.log`):

```
[SignOutProbe] calling AuthService.signOut()
[SignOutProbe] signOut() returned cleanly; session=nil
```

`screenshots/phase7/04_after_sign_out.png` shows the `LandingView`
("Foodie Ai." wordmark + "Try for FREE" + slogan) — `RootView`
flipped to `OnboardingFlow.landing` because `auth.session` went
nil. Auth state machine intact post-Phase-7.

## Screenshots ↔ state mapping

| File | State | What it proves |
|---|---|---|
| `01_profile_loaded.png` | `.loaded` (defaults) | Production `ProfileView` rendering schema defaults (2000/250/50, empty name) right after the SQL backfill — `Member since May 2026`, email line bound to `auth.session?.user.email`. |
| `02_update_probe.png` | post-save (debug shim) | Probe form shim showing drafts + DB row state after UPDATE: display_name=Phase 7 Probe, calorie=2200, carb=230, sugar=45, updated_at=2026-05-08T13:22:42Z, hasUnsavedChanges=no, isSaving=no. |
| `03_after_relaunch.png` | `.loaded` (after persist) | Production `ProfileView` re-rendered after app restart, showing the persisted values from a fresh SELECT. Button disabled = no unsaved changes. |
| `04_after_sign_out.png` | OnboardingFlow.landing | Post-sign-out state. RootView routed to LandingView when session went nil. |

## Audit: no INSERT to `profiles` from iOS

```
$ grep -rn 'from("profiles")' FoodieAI/ --include="*.swift"
FoodieAI/Services/ProfileService.swift:51:    .from("profiles")    # SELECT
FoodieAI/Services/ProfileService.swift:98:    .from("profiles")    # UPDATE

$ grep -rn '\.insert' FoodieAI/Services/ --include="*.swift"
FoodieAI/Services/FoodLogService.swift:16:    .insert(draft, returning: .representation)    # food_logs only
```

Only the two expected `profiles` operations (SELECT for read, UPDATE
for save). The only `.insert` in any service points to `food_logs`,
matching Phase 6. The `handle_new_user` DB trigger remains the sole
producer of `profiles` rows.

## Decisions log (Phase 3 format)

1. **`ProfileService.signedInUserId()` prefers session over cache.**
   Same Phase 6 playbook: read from
   `client.auth.session.user.id.uuidString.lowercased()` first, fall
   back to `currentUser?.id.uuidString.lowercased()`. Lowercase to
   keep PostgREST's `.eq("id", value: …)` string comparison aligned
   with `auth.uid()::text`.

2. **`.eq("id", value: id)` reads as a string.** Both `id` (text) and
   `auth.uid()::text` (text) compare via PostgREST's URL-encoded
   filter. Could pass a `UUID` value directly — the SDK would coerce
   — but I went with the explicit lowercased string to match the
   audit pattern Phase 6 established.

3. **`currentProfile()` uses `[Profile]` + `.first` rather than
   `.single()`.** `.single()` throws PGRST116 on 0 rows with no clue
   whether the row is missing or just RLS-hidden; reading the array
   and inspecting `.count` gives the diagnostic log line that
   surfaced the missing-row issue. Trade-off: slightly more
   bandwidth (one row vs. one row), inconsequential.

4. **`updateProfile` patches via `ProfileUpdate` struct.** Already
   in Phase 1 — `display_name`, `daily_calorie_goal`,
   `daily_carb_goal_g`, `daily_sugar_goal_g`. Avatar url
   intentionally absent (Phase 0 Q5 deferral). Empty-string display
   names get mapped to `nil` so the column cleanly nulls out rather
   than holding `""`.

5. **`ProfileViewModel.bindUnsavedChangeTracking()` uses Combine,
   not an `objectWillChange` shotgun.** A
   `Publishers.CombineLatest4(...)` over the four drafts cross-joined
   with `$state` lets the unsaved-changes flag recompute against the
   exact loaded baseline. `removeDuplicates()` keeps it from churning
   on no-op publisher emissions; `assign(to: \.hasUnsavedChanges)`
   feeds the published flag.

6. **`seed(from: profile)` snaps `hasUnsavedChanges = false` after
   re-binding drafts.** The order matters: assign drafts first
   (which fires the Combine pipeline once with the new values vs the
   *old* state, briefly emitting `true`), then assign state, then
   force `hasUnsavedChanges = false`. The pipeline re-emits with the
   new baseline on the next event and stays false until the user
   actually mutates a field.

7. **Save button is always-visible-but-disabled, not hidden.** Spec
   offered both options; chose visible-disabled so the form layout
   doesn't shift when the user makes their first change. Documented
   inline in `ProfileView.saveButton`.

8. **Goal value renders with `lineLimit(1)` and
   `minimumScaleFactor(0.7)`.** Initial pass let the kcal-style
   "2,000" wrap to two lines on the iPhone 17 width. Adding
   `lineLimit(1) + minimumScaleFactor(0.7) + minWidth(100)` keeps it
   on one line while still using the kcal font tone the spec called
   for.

9. **Sign-out copy.** Spec offered "You'll be signed back in next
   time you open the app if your session is still valid" or shorter.
   Used "You'll need to sign back in to access your meals." — fits
   the simulator with no wrap and is honest about the user impact.

10. **Member-since renders "MMMM yyyy" only.** Spec wanted "{long
    month, year}". Used `DateFormatter` with `dateFormat = "MMMM
    yyyy"`. No day-of-month — keeps the meta line compact.

11. **DEBUG-only `LAUNCH_PROFILE_DIRECT`,
    `LAUNCH_PROFILE_UPDATE_PROBE`, and `LAUNCH_SIGN_OUT_PROBE`
    bypasses.** Three new env-var entry points in
    `FoodieAIApp.rootScene`. The first renders the production
    `ProfileView` without auth-routing for screenshot capture; the
    second drives a programmatic load → mutate → save round-trip
    for the live UPDATE network log; the third calls
    `AuthService.signOut()` and renders the resulting RootView state.
    All three `#if DEBUG` only — zero release-build cost.

12. **Schema gap surfaced by Phase 7.** `handle_new_user` did not run
    for the user's `auth.users` row (signed up before trigger
    install or trigger failed silently). Recommendation for Phase 8
    polish: add a `select count(*) from public.profiles` smoke check
    to setup docs, or add a `profiles_insert_own` RLS policy
    (`auth.uid() = id`) so iOS can self-heal on first read. Not
    needed for v1 if you re-run the schema before each fresh signup.

## Files added or modified

**Modified**
- `FoodieAI/FoodieAIApp.swift` — replaced `ProfileStub` with `ProfileView()`; added `LAUNCH_PROFILE_DIRECT`, `LAUNCH_PROFILE_UPDATE_PROBE`, `LAUNCH_SIGN_OUT_PROBE` debug bypasses.

**Added**
- `FoodieAI/Services/ProfileService.swift` — `currentProfile()` (SELECT, lowercased uuid filter, `[Profile] + .first` to surface 0/1 row distinguishably) + `updateProfile(...)` (UPDATE with `.eq("id", value: lowercasedUid).select().single()` returning the patched row).
- `FoodieAI/Features/Profile/ProfileViewModel.swift` — `@MainActor` `ObservableObject` with `.loading / .loaded / .failed` state; four `@Published` drafts; Combine pipeline for `hasUnsavedChanges`; `load()`, `save()`, `signOut()`.
- `FoodieAI/Features/Profile/ProfileView.swift` — production view: identity header (email + member-since), display-name TextField, three goal Stepper rows, Save button, error banner, Sign-out section.
- `FoodieAI/Features/Profile/ProfileUpdateProbe.swift` — DEBUG-only programmatic round-trip helper (`LAUNCH_PROFILE_UPDATE_PROBE`).
- `FoodieAI/Features/Profile/SignOutProbe.swift` — DEBUG-only sign-out helper (`LAUNCH_SIGN_OUT_PROBE`).

**Unmodified but verified**
- `FoodieAI/Models/Profile.swift` — `Profile` decode shape and
  `ProfileUpdate` patch shape (no `user_id`, no `avatar_url` in the
  patch).
- `FoodieAI/Services/AuthService.swift` — `signOut()` already
  implemented (Phase 4); only consumed, not modified.

## Phase 7 status: ✅ verified end-to-end with one out-of-band fix

- Profile READ pipeline: ✓ (SELECT 1 row, drafts pre-populated, RLS
  permits the user's own row)
- Profile UPDATE pipeline: ✓ (UPDATE landed in Postgres,
  `updated_at` advanced, RLS permits, drafts reseeded post-save)
- Persistence across app restart: ✓ (`03_after_relaunch.png` reads
  back the post-update values from a fresh SELECT)
- Sign-out flow: ✓ (session goes nil, RootView flips to Landing)
- No client-side INSERT to `profiles`: ✓ (audit clean; only SELECT
  + UPDATE call the table)

Outstanding items for **manual confirmation in Supabase Dashboard**
(I can't reach the Dashboard from CLI):

- Table Editor → `profiles` → confirm the row's
  `display_name=Phase 7 Probe`, `daily_calorie_goal=2200`,
  `daily_carb_goal_g=230`, `daily_sugar_goal_g=45`, and a recent
  `updated_at` near `2026-05-08T13:22:42Z`.
- SQL Editor (postgres role bypasses RLS) →
  `select id, display_name, daily_calorie_goal, daily_carb_goal_g,
   daily_sugar_goal_g, updated_at from profiles where id =
   'd73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb';` should return one row
  with those exact values.

Phase 8 (polish) starts after the Dashboard receipts confirm the
row matches, and after you decide whether the Phase 8 polish list
should include either (a) a setup-doc smoke check that
`handle_new_user` ran, or (b) an iOS self-healing
`profiles_insert_own`-policied insert to forgive the trigger gap.
