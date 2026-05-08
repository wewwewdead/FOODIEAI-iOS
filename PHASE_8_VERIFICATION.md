# Phase 8 — Polish + Ship Prep Verification

## Build & launch

Clean build for iPhone 17 simulator (iOS 26.4 sim runtime, iOS 17
deployment target, arm64 only):

```
** BUILD SUCCEEDED **
```

No new warnings. The Phase 4–7 keychain session for
`johnmathewloren27@gmail.com` (uid `d73869bb-…`) was preserved across
all Phase 8 installs by using `simctl install` in place rather than
`uninstall + install`.

## Step 1 — `profiles_insert_own` migration + iOS self-heal

`migrations/001_profiles_insert_own.sql` adds a third RLS policy to
`public.profiles`, parallel to `profiles_select_own` and
`profiles_update_own`:

```sql
create policy "profiles_insert_own"
    on public.profiles for insert
    with check (auth.uid() = id);
```

User confirmed the migration was applied in Supabase SQL Editor and
manually deleted their `profiles` row to set up the empty state.

**`ProfileService.currentProfile()` self-heal log** (`screenshots/phase8/self_heal.log`):

```
[Profile] SELECT profiles WHERE id=d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb
[Profile] SELECT returned 0 row(s)
[Profile] self-heal: trigger-skipped row, inserting defaults for d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb
[Profile] self-heal INSERT profiles (id=d73869bb-8bb7-41fb-b7b3-3b2d6d1e39bb)
[Profile] self-heal INSERT returned id=D73869BB-8BB7-41FB-B7B3-3B2D6D1E39BB
```

`screenshots/phase8/01_profile_self_heal.png` shows the production
`ProfileView` rendering the freshly self-healed row's defaults: empty
display name, Calories 2,000, Carbs 250g, Sugar 50g (column defaults),
"Member since May 2026" (just now).

What this proves end-to-end:
- `currentProfile()` correctly distinguishes 0-rows from RLS errors
  (Phase 7's failure mode).
- `selfHealMissingProfile(id:)` builds an INSERT payload with only `id`,
  letting Postgres column defaults populate the rest.
- Migration 001's `profiles_insert_own` policy gates the INSERT with
  `auth.uid() = id` — RLS permits since both match for the
  signed-in user.
- Loud `print(...)` on the heal path makes production occurrences
  obvious in Xcode console.

## Step 2 — App-wide error / empty / loading audit

Three states walked across every authoring screen. **A ✓ in a column
means the state is implemented; — means it's structurally
unnecessary.**

| Screen | Loading | Empty | Failed |
|---|---|---|---|
| LandingView | — (no fetch) | — | — |
| SignInView | ✓ ProgressView in Continue-with-Google button | — | ✓ `errorMessage` in redError below button |
| CaptureView (`.idle`) | — | ✓ welcome heading + drop-zone empty state | — |
| CaptureView (`.picked`) | — | — | — |
| CaptureView (`.analyzing`) | ✓ PillButton spinner | — | — |
| CaptureView (`.ready`) | — | — | — |
| CaptureView (`.saving`) | ✓ CircleActionButton.save spinner | — | — |
| CaptureView (`.saved`) | — | — | — |
| CaptureView (`.saveFailed`) | — | — | ✓ inline error + "Try again" via retrySave |
| CaptureView (`.noFood`) | — | ✓ "No food detected!" copy + "Try another photo" | — |
| CaptureView (`.failed`) | — | — | ✓ FailedView with localized AnalyzeError + "Try again" |
| TrackerView | ✓ centered ProgressView | ✓ "No data yet!" textMeta | ✓ "Couldn't load today's meals" + Try again |
| ProfileView | ✓ centered ProgressView | — (self-heal converts 0 rows to defaults) | ✓ "Couldn't load your profile" + Try again |

### Network error mapping (`AnalyzeService.map(urlError:)`)

`AnalyzeError` extended with a dedicated `.offline` case (Phase 8) so
the iOS user gets the right copy depending on whether the issue is
the device's connection or the analyzer host being unreachable:

| URLError code | AnalyzeError case | UI copy |
|---|---|---|
| `.timedOut` | `.timeout` | "The analyzer took too long to respond. Try again." |
| `.notConnectedToInternet` | `.offline` | "Looks like you're offline. Check your connection and try again." |
| `.networkConnectionLost`, `.cannotConnectToHost`, `.cannotFindHost`, `.dnsLookupFailed`, `.resourceUnavailable` | `.networkUnavailable` | "We can't reach the analyzer right now. Try again in a moment." |
| 4xx/5xx HTTP | `.serverError(status:body:)` | "Something went wrong on our end. Try again in a moment." |
| (other URLError) | `.networkUnavailable` | (same as above — generic fallback) |

`screenshots/phase8/02_offline_capture.png` captures a live failure
mode: server stopped, `LAUNCH_CAPTURE_LIVE=1` ran, `URLError code=-1004
desc=Could not connect to the server.` (`.cannotConnectToHost`) routed
through `.networkUnavailable`, UI rendered "Something went wrong /
We can't reach the analyzer right now. Try again in a moment." matching
the table.

Auth-expired routing is implicit: when Supabase's session goes nil,
`AuthService.authStateChanges` re-emits → `RootView` flips to
`OnboardingFlow` → user sees Landing → Sign In, no in-screen banner
needed. Verified Phase 7 (`SignOutProbe`).

## Step 3 — Dynamic Type pass

Tested with `LAUNCH_AX5=<screen>` bypass that wraps the target view
in `.environment(\.dynamicTypeSize, .accessibility5)`.

**Findings & fixes:**
- LandingView slogan ("Curious about your meal?…") originally
  truncated to "Curious…" at AX5 because the belowHero band has a
  fixed height. Added `.dynamicTypeSize(...DynamicTypeSize.xxLarge)`
  cap + `.minimumScaleFactor(0.7)`. Now wraps cleanly.
- "Foodie Ai." wordmark (LandingView + LaunchView) capped at
  `xLarge` so the brand mark doesn't blow past the hero card edge.
  Documented inline.
- ProfileView failed-view "Couldn't load your profile" displayMD
  heading clipped at AX5; added `.minimumScaleFactor(0.6)` +
  `.lineLimit(2)`.
- Calorie/macro values in the goal stepper rows already had
  `.lineLimit(1) + .minimumScaleFactor(0.7) + .frame(minWidth: 100)`
  from Phase 7's "2,000 wraps" fix.

`screenshots/phase8/04_dynamic_type_xl.png` shows LandingView at
accessibility5: capped wordmark renders cleanly at top, "Try for FREE"
button wraps inside its capsule at the new size, slogan and footer
both visible without truncation.

**Known scaling caveats (not fixed in v1):**
- The three `displayMD` headings inside the various failed/empty
  states across other screens (TrackerView "Couldn't load today's
  meals", CaptureView's `NoFoodView`/`FailedView`, the SavedConfirmation
  sheet title) don't have explicit `.minimumScaleFactor` clamps.
  At AX5 they wrap to two lines; with very long copy they could clip.
  Live screens haven't shown clipping in our sample copy. If you want
  belt-and-suspenders, copy the Profile fix to those four sites.

## Step 4 — Dark mode decision

**Shipped light-only.** Locked via
`.preferredColorScheme(.light)` in `FoodieAIApp.body` and a hard
`UIUserInterfaceStyle = Light` in `Info.plist`. Recommendation
in the spec was honored — the cream/lime palette doesn't have a
clean dark mapping and a half-converted dark mode would look worse
than a confidently-light app. Documented in `README.md`'s "Known
limitations" section.

## Step 5 — App icon

Source: `client/src/assets/foodie.png` (500×500 RGBA, transparent
background, brown sunny-side-up egg illustration).

Build: `python3` + `Pillow` (already installed) generated a 1024×1024
opaque PNG flattened against `(240, 248, 181)` (close to brand
cream) — Apple iOS icons require no alpha. Wrote to
`Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` and updated
`Contents.json` to reference it.

`screenshots/phase8/05_app_icon_home_screen.png` shows the icon
installed on the simulator home screen — labeled "FoodieAI",
recognizable egg illustration on a cream background.

**Quality note:** the 500→1024 upscale is not pixel-perfect. The icon
is acceptable for TestFlight / internal testing but should be
re-rendered from a 1024×1024-native source before App Store
submission. Pre-release blocker for a polished launch; non-blocker
for v1 internal beta.

## Step 6 — Privacy strings + manifest

**Info.plist usage descriptions (final Phase 8 copy in `project.yml`):**
```
NSCameraUsageDescription:    FoodieAI uses the camera to analyze meals you capture.
NSPhotoLibraryUsageDescription: FoodieAI uses your photos to analyze meals you've already taken.
```

(Confirmed `NSUserTrackingUsageDescription` is not declared — we
don't track.)

**`FoodieAI/PrivacyInfo.xcprivacy`** new file. Declares:
- `NSPrivacyTracking = false`
- `NSPrivacyAccessedAPITypes = []` (no Apple "required reason" APIs)
- `NSPrivacyTrackingDomains = []`
- Two `NSPrivacyCollectedDataTypes` entries:
  - **EmailAddress** — linked to user, app-functionality purpose, no tracking
  - **PhotosorVideos** — linked to user, app-functionality purpose, no tracking

xcodegen picks up `.xcprivacy` files under the `FoodieAI/` source path
automatically (Xcode treats them as resources by extension).

## Step 7 — About sheet

`FoodieAI/Features/Profile/AboutSheet.swift` — `.sheet(.medium)`
presented from a small "About FoodieAI" link below the Sign Out
button on the Profile tab. Contents:
- "Foodie Ai." wordmark (M PLUS Rounded 1c Medium 40pt, dynamic-type
  capped)
- Version + build read from `Bundle.main.infoDictionary` —
  `v0.1.0 (1)` for the current build
- "FoodieAI v1 by Loren"
- "Powered by Google Gemini and Supabase."
- Close `PillButton.primary` that dismisses

`screenshots/phase8/06_about_sheet.png` — sheet presented via
`LAUNCH_ABOUT_SHEET=1` for clean capture; production wiring goes
through `ProfileView.signOutSection`'s "About FoodieAI" button.

## Step 8 — README + SETUP

- `README.md` — new at repo root. Covers: what the app does, tech
  stack, auth model, privacy summary, **known limitations / gaps**
  (light-only, no SIWA, no avatar, tab-appear refresh, placeholder
  Google "G" mark), how to run pointing at SETUP.md, phase index,
  repo layout.
- `SETUP.md` — full rewrite. Covers prerequisites, project
  generation via the bundled `tools/xcodegen` binary, Secrets
  configuration with `Secrets.local.xcconfig`, schema + migration
  001, Google OAuth provider setup, the Express analyze proxy
  (cd `~/Downloads/foodieAi.-main/server`, npm install, .env
  contents, npm run dev), build & run, the full DEBUG bypass
  table (every `LAUNCH_*` env var across phases 2–8),
  troubleshooting playbook (No such module 'Supabase',
  PGRST116 → migration 001 hint, etc.), and a complete files
  reference table.

## Screenshots ↔ state mapping

| File | What it shows | How captured |
|---|---|---|
| `01_profile_self_heal.png` | Production ProfileView rendering the freshly-self-healed row's defaults (2000/250/50, empty name) after deleting the row + applying migration 001 | `LAUNCH_PROFILE_DIRECT=1` after manual SQL backfill of empty state |
| `02_offline_capture.png` | CaptureView `.failed` with "Something went wrong / We can't reach the analyzer right now. Try again in a moment." | `LAUNCH_CAPTURE_LIVE=1` with the Express server stopped (URLError -1004) |
| `03_offline_tracker.png` | TrackerView failed state — header card placeholders + "Couldn't load today's meals" + "Looks like you're offline. Check your connection and try again." + "Try again" | `LAUNCH_TRACKER_FAILED=1` (synthetic — same code path the production VM transitions to on caught error) |
| `04_dynamic_type_xl.png` | LandingView at `.accessibility5` — wordmark capped, "Try for FREE" wraps in capsule, slogan readable, footer visible | `LAUNCH_AX5=landing` |
| `05_app_icon_home_screen.png` | Sim home screen showing FoodieAI icon (egg-on-plate on cream) | App-installed home screen capture |
| `06_about_sheet.png` | AboutSheet presented at `.medium` detent | `LAUNCH_ABOUT_SHEET=1` |

## Decisions log (Phase 3 format)

1. **Migration 001 is a SQL migration, not a schema rewrite.** Adding
   the `profiles_insert_own` policy via a separate migration file
   (rather than editing `foodie_schema.sql`) keeps the schema as the
   "fresh-deploy" reference and lets existing deployments adopt the
   new policy with a single `CREATE POLICY` statement.

2. **Self-heal logs via `print(...)`, not just NSLog.** Dual-channel
   (NSLog for debug-only, print for any build) so production
   occurrences surface in any standard Xcode console attach. The
   stated intent is exactly that: "if these show up in production,
   investigate trigger health."

3. **`AnalyzeError.offline` separate from `.networkUnavailable`.**
   The user-facing copy distinction is real: "you're offline" tells
   the user to check airplane mode/wifi; "we can't reach the
   analyzer" tells them the issue is server-side and to wait. Code
   maps `URLError.notConnectedToInternet` to the former, everything
   else to the latter.

4. **`.minimumScaleFactor + dynamicTypeSize cap` over reflowing
   layouts.** Dynamic Type fixes were targeted: cap the brand
   wordmark, scale-down the slogan, scale-down headings that lived
   in fixed-height bands. Wrapping every screen in a ScrollView would
   have been the more thorough fix but would change visual layouts
   at default sizes. Targeted clamps preserve the design intent.

5. **App icon flattened on a cream-ish background, not white.**
   Apple icons can't be alpha-channel; chose `(240, 248, 181)`
   (close to brand cream) over pure white so the icon visually
   integrates with the LaunchScreen color. Renders close to white
   at thumbnail scale, which is acceptable.

6. **PrivacyInfo.xcprivacy includes only Email + Photos.** No other
   data types are touched: we don't read crash logs, advertising
   identifier, contacts, location, financial data, etc. Keeping the
   manifest minimal makes Apple review faster and gives less surface
   for the manifest to drift from reality if a dependency
   accidentally adds a tracking signal.

7. **About sheet uses iOS-native `.sheet(.medium)` like the saved
   confirmation.** Consistent pattern; users learn that
   "drag-down dismiss" works the same in both places.

8. **DEBUG-only verification bypasses for Phase 8:**
   `LAUNCH_AX5=<mode>`, `LAUNCH_ABOUT_SHEET`, `LAUNCH_TRACKER_FAILED`.
   Total of 13 bypass routes now live in `FoodieAIApp.rootScene`
   (counting all phases). All `#if DEBUG` only — they ship out of
   release builds completely.

## Files added or modified

**Modified**
- `FoodieAI/Services/ProfileService.swift` — `currentProfile()` now self-heals on 0 rows; new `selfHealMissingProfile(id:)` private method.
- `FoodieAI/Services/AnalyzeService.swift` — added `.offline` case + URLError mapping for `notConnectedToInternet`; revised user-facing copy.
- `FoodieAI/Features/Onboarding/LandingView.swift` — slogan dynamic-type cap + scale factor; wordmark dynamic-type cap.
- `FoodieAI/FoodieAIApp.swift` — wordmark dynamic-type cap on LaunchView; added `LAUNCH_AX5`, `LAUNCH_ABOUT_SHEET`, `LAUNCH_TRACKER_FAILED` bypasses; `ax5View(mode:)` helper.
- `FoodieAI/Features/Profile/ProfileView.swift` — added `showingAbout` state + `.sheet` binding to `AboutSheet`; About FoodieAI link added to Sign-out section; failed-view heading scale clamp.
- `project.yml` — Privacy strings final Phase 8 copy.

**Added**
- `migrations/001_profiles_insert_own.sql` — RLS policy for self-heal.
- `FoodieAI/PrivacyInfo.xcprivacy` — App Store privacy manifest.
- `FoodieAI/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` — generated app icon (500→1024, opaque, cream background).
- `FoodieAI/Features/Profile/AboutSheet.swift` — version/credits sheet.
- `FoodieAI/Features/Tracker/TrackerFailedSample.swift` — DEBUG-only Tracker failed-state renderer for offline screenshot capture.
- `README.md` — repo description, tech stack, known gaps, run instructions.
- `SETUP.md` — rewritten end-to-end setup guide with the bypass table and troubleshooting playbook.

**Migration applied (manual)**
- User confirmed `migrations/001_profiles_insert_own.sql` ran in Supabase SQL Editor; `profiles_insert_own` policy now appears in Authentication → Policies → public.profiles.

## TestFlight blockers found

Stop-ship for any externally-distributed build (TestFlight or App
Store):

1. **Google "G" mark is an SF Symbol `globe` placeholder.** Real Google
   sign-in button must use Google's officially-bundled mark per their
   brand guidelines. Replace `Image(systemName: "globe")` in
   `SignInView.googleButton` with the official asset before any
   external distribution.

Polish-recommended before App Store (non-blocking for TestFlight):

2. **App icon source resolution.** Generated from a 500×500 source;
   acceptable for internal testing, but a 1024-native (or vector)
   re-render is recommended before App Store submission.
3. **`displayMD` headings without scale clamps in the four sites
   noted in Step 3.** Cosmetic at default sizes; visible at AX5 with
   long copy variants we don't currently emit.
4. **Tab-appear refresh on Tracker.** Mild flicker on tab switch.
   Acceptable for v1; replace with shared event publisher in v1.1
   if user feedback warrants.
5. **No avatar upload** in Profile — Phase 0 deferral, documented in
   README. Either ship as-is or add Phase 9 work for image upload
   to the existing `food-images` bucket pattern.

Hard requirement before paid Developer Program migration:

6. **Sign in with Apple absent.** Apple requires SIWA as an
   alternative if you offer any third-party social sign-in (Google,
   Facebook, etc.) per App Store Review Guideline 4.8. v1 may pass
   internal beta but will fail formal review until a paid
   Developer team enables the SIWA entitlement and the existing
   `AuthService.signInWithApple` entry point gets wired into
   `SignInView`.

## Phase 8 status: ✅ verified

- Self-heal: live INSERT round-trip captured + UI rendered
- Offline analyze: live URLError → mapped error → UI rendered
- Offline tracker: failed state UI captured (synthetic injection)
- Dynamic Type AX5: layout-fix pass applied + screenshotted
- App icon: generated and home-screen-installed
- About sheet: rendered with correct version/build/credits
- README + SETUP: refreshed
- Privacy manifest: filed
- TestFlight blockers: enumerated above

This is the last code phase per CLAUDE.md. TestFlight submission
process and metadata work (App Store Connect setup, screenshots in
the listing format, beta tester invites, review notes) is separate
from the code.
