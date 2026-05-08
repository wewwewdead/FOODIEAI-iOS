# Setup

End-to-end instructions for getting a fresh checkout to a buildable,
runnable, and signed-in app on the iPhone 17 simulator.

## Prerequisites

- macOS with Xcode 16+ installed (project uses iOS 17 deployment target,
  iOS 26.4 simulator runtime tested).
- Node 18+ for the Express analyze proxy.
- A free Supabase project (database + storage + auth).
- A Google Gemini API key for the analyze proxy.

## 1. Generate the Xcode project

The repo bundles `tools/xcodegen` (a prebuilt arm64 macOS binary).

```sh
./tools/xcodegen generate
```

This produces `FoodieAI.xcodeproj` from `project.yml`. The generated project:
- Adds the `supabase-swift` Swift package.
- Wires `Secrets.xcconfig` to both Debug and Release.
- Sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` for Debug (so
  `#if DEBUG` blocks aren't stripped from CLI builds — see Phase 5
  verification for the incident).
- Sets iOS 17 deployment target, iPhone-only device family, light-mode lock.
- Bundles `FoodieAI/PrivacyInfo.xcprivacy` (App Store privacy manifest).

Re-run `./tools/xcodegen generate` whenever you add or remove source
files; the `.xcodeproj` is recreated from scratch every time.

## 2. Provide secrets

```sh
cp Secrets.local.xcconfig.template Secrets.local.xcconfig
```

Edit `Secrets.local.xcconfig` and fill in:

```
SUPABASE_HOST   = your-project-ref.supabase.co
SUPABASE_ANON_KEY = ey...        // long JWT
ANALYZE_HOST    = localhost:3001 // for the local Express proxy
```

`Secrets.local.xcconfig` is gitignored. The tracked `Secrets.xcconfig`
`#include?`s it so build settings resolve real values without exposing
them in version control.

`AppConfig` (in `Core/FoodieClient.swift`) prepends `https://` to
`SUPABASE_HOST` and `http://` to `ANALYZE_HOST` if it starts with
`localhost` or `127.0.0.1`. Don't include the scheme yourself —
xcconfig's `//` is a comment escape.

## 3. Run the Supabase schema

In the Supabase Dashboard → SQL Editor:

1. Paste and run all of `foodie_schema.sql`.
2. Run the migration `migrations/001_profiles_insert_own.sql` to
   install the `profiles_insert_own` RLS policy. Without this, the iOS
   self-heal won't be able to backfill a profile if the
   `handle_new_user` trigger ever fails to fire.

Verify in Authentication → Policies → public.profiles that all three
expected policies are present:

- `profiles_select_own`
- `profiles_update_own`
- `profiles_insert_own`  (added by migration 001)

Verify in Storage → Buckets that the private `food-images` bucket
exists with the per-user folder RLS policy.

## 4. Configure auth providers

Supabase Dashboard → Authentication → Providers → Google:
- Enable
- Paste your Google OAuth Client ID and Client Secret
- Under URL Configuration → Redirect URLs, add
  `com.foodieai.FoodieAI://login-callback` (matches
  `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).

Sign in with Apple is **not** wired in v1 — see project memory
`personal_team_no_siwa` (free Apple Developer Program can't enable the
SIWA entitlement). The `AuthService.signInWithApple` entry point
remains as dead code for future re-enable; the entitlement is
commented out in `project.yml`.

## 5. Run the Express analyze proxy

The proxy is a minimal Node service that takes a multipart JPEG, calls
Gemini, and returns the structured analysis. The Gemini API key
**stays on the server** — iOS only knows the proxy URL.

```sh
cd /path/to/foodieAi.-main/server
npm install
```

Create `.env` in that directory:

```
GEMINI_API_KEY=<your Google Gemini key>
PORT=3001
# These are only used by /save and /getFoodLogs (which iOS doesn't call).
# Stub values prevent createClient() from throwing at module-load time.
SUPABASE_URL=https://stub.invalid
SERVICE_KEY=stub
```

```sh
npm run dev   # nodemon; restarts on edits
```

Confirm `Server running at http://localhost:3001` appears, then
`curl http://localhost:3001/` returns `server is working`.

The iOS app's `ANALYZE_HOST=localhost:3001` from step 2 will then be
reachable. The simulator's `localhost` resolves to the host Mac.

## 6. Build & run

```sh
./tools/xcodegen generate   # if you skipped it earlier
open FoodieAI.xcodeproj
```

In Xcode: select the `iPhone 17` simulator, Cmd+R.

Tap **Try for FREE** → **Continue with Google** → complete the OAuth
flow. After the callback dismisses you'll land on the Home tab.

## 7. (Optional) Verification helpers

DEBUG-only env-var bypasses for screenshot capture and ad-hoc testing,
all wired in `FoodieAIApp.rootScene`. Pass via
`SIMCTL_CHILD_<name>=<value>` when launching with `xcrun simctl launch`:

| Env var | Purpose | Phase |
|---|---|---|
| `LAUNCH_THEME_PREVIEW=1` | Render the theme palette swatches | 2 |
| `LAUNCH_COMPONENT_GALLERY=1` | Render every reusable component | 3 |
| `LAUNCH_SIGNIN_DIRECT=1` | Skip Landing, open Sign In | 4 |
| `LAUNCH_CAPTURE_DIRECT=1` | Render `CaptureView` without auth | 5 |
| `LAUNCH_CAPTURE_SAMPLE=<state>` | Render a specific Capture state with mocked data | 5 |
| `LAUNCH_CAPTURE_LIVE=<mode>` | Drive a live `/analyze` round-trip (food/nofood/save) | 5,6 |
| `LAUNCH_TRACKER_DIRECT=1` | Render the Tracker tab in isolation | 6 |
| `LAUNCH_PROFILE_DIRECT=1` | Render the Profile tab in isolation | 7 |
| `LAUNCH_PROFILE_UPDATE_PROBE=1` | Drive a live profile UPDATE round-trip | 7 |
| `LAUNCH_SIGN_OUT_PROBE=1` | Programmatically sign out, then render Landing | 7 |

All bypasses are `#if DEBUG`-gated; release builds ignore them entirely.

## Troubleshooting

- **`No such module 'Supabase'`** — `./tools/xcodegen generate`
  (package reference only lives in the generated `.xcodeproj`).
- **`SUPABASE_URL missing in Info.plist`** at launch — your
  `Secrets.local.xcconfig` is missing or has the wrong key names.
  Check the launch console for `=== AppConfig ===` to see what
  resolved.
- **Storage upload fails with 403 RLS** — verify the path's first
  segment is the **lowercased** auth.uid() (Phase 6 incident). The
  fix is in `FoodImageService.upload`; if you see this on a fresh
  install, your local code is older than the Phase 6 patch.
- **Profile load fails with PGRST116** — `handle_new_user` didn't
  fire when this user signed up. Either re-run `foodie_schema.sql`
  to install the trigger and sign up fresh, or run migration 001
  and let the iOS self-heal create the row on first read (Phase 8).
- **Sim doesn't see localhost:3001** — confirm the proxy is running
  on the host Mac. Sim's `localhost` is the Mac, not the sim itself.
- **Build fails with `linker command failed for x86_64`** — pass
  `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` to `xcodebuild`. The Supabase
  package only ships arm64 simulator slices.

## Files reference

| Path                                       | What it is |
|--------------------------------------------|------------|
| `project.yml`                              | xcodegen project spec — single source of truth |
| `Secrets.xcconfig`                         | Tracked. `#include?`s the local override |
| `Secrets.local.xcconfig.template`          | Tracked template you copy |
| `Secrets.local.xcconfig`                   | Gitignored — actual credentials |
| `migrations/001_profiles_insert_own.sql`   | Phase 8 RLS migration |
| `foodie_schema.sql`                        | Initial Supabase schema |
| `FoodieAI/PrivacyInfo.xcprivacy`           | App Store privacy manifest |
| `FoodieAI/Info.plist`                      | Camera/photo strings, custom URL scheme, font list |
| `FoodieAI/FoodieAIApp.swift`               | App entry, root routing, env-var bypasses |
| `FoodieAI/Core/FoodieClient.swift`         | Supabase client + AppConfig |
| `FoodieAI/Core/Theme/`                     | AppColor, AppFont, AppSpacing, AppRadius, AppShadow |
| `FoodieAI/Core/Components/`                | PillButton, BrandCard, DashedDropZone, etc. |
| `FoodieAI/Models/`                         | Codable types: Profile, FoodLog, DailyTotals, GeminiAnalysis |
| `FoodieAI/Services/`                       | Auth, FoodLog, FoodImage, Analyze, Profile |
| `FoodieAI/Features/`                       | Onboarding, Home, Tracker, Profile screens |
| `tools/xcodegen`                           | Prebuilt xcodegen binary |
| `PHASE_<N>_VERIFICATION.md`                | Per-phase verification reports (0…8) |
