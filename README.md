# FoodieAI iOS

Native iOS port of the FoodieAI web app. Snap a meal, get a nutrition
breakdown from Gemini, log it to your daily tracker.

## What it does

1. **Capture** — pick or shoot a photo of a meal.
2. **Analyze** — the app sends a compressed JPEG to a small Express
   proxy, which calls Google Gemini and returns a structured
   nutrition response (calories, carbs, sugar, benefits, drawbacks,
   nutrients, plus a coach-attributed quip from a randomly-picked
   historical figure).
3. **Save** — store the meal + image to a per-user Supabase Storage
   folder and a `food_logs` row protected by row-level security.
4. **Track** — see today's saved meals (in your local time zone) with
   summed totals.
5. **Profile** — set your daily calorie / carb / sugar goals.

## Tech stack

- **iOS 17+ / SwiftUI** — no UIKit except for unavoidable bridges
  (camera picker, photos picker bridge, ASWebAuthenticationSession).
- **supabase-swift** — auth, database, storage. Sessions persist via
  the SDK's keychain storage.
- **Express + Multer + @google/genai** — the analyze proxy. Lives
  outside this repo.
- **xcodegen** — declarative project file generation.

No third-party UI, animation, or icon libraries; all visual primitives
recreated from the design system in pure SwiftUI.

## Auth

Google OAuth via `ASWebAuthenticationSession` → Supabase
`exchangeCodeForSession`. Sign in with Apple is **not** wired in v1;
the entitlement requires a paid Apple Developer Program membership
(see `migrations/`-adjacent project memory `personal_team_no_siwa`).

## Privacy & data

- **Email** is collected (from your Google identity, stored in your
  `profiles` row) for account identification. Never shared.
- **Photos** you analyze are uploaded to your private Supabase
  Storage folder (`{your-uid}/...`) for the analyze + save flow. Per-user
  RLS prevents anyone else from reading them. Never shared with
  third parties.
- The Gemini API key lives **only** on the Express proxy server. It
  never leaves the server, and the iOS app has no idea what it is.
- See `FoodieAI/PrivacyInfo.xcprivacy` for the full App Store privacy
  manifest.

No tracking, no analytics, no ad SDKs.

## Known limitations / gaps

- **Light mode only.** The cream/lime palette doesn't have an obvious
  dark-mode mapping; a half-converted dark mode would look worse than a
  confidently-light app. Locked via `.preferredColorScheme(.light)` at
  the WindowGroup level. Revisit in v1.1 if there's demand.
- **Sign in with Apple absent.** Free Apple Developer Program limitation
  (see Auth section). Unblocks once we move to a paid team.
- **Avatar upload absent** in Profile — Phase 0 deferral. Profile shows
  display name + goals only.
- **Tracker tab refreshes on appear**, not via a shared event publisher.
  Mild flicker on tab switch in exchange for not plumbing a global event
  bus. Can move to a publisher-based model in v1.1 if the flicker is
  noticeable.
- **Google "G" mark on the sign-in button** is currently an SF Symbol
  `globe` placeholder. Real mark requires bundling Google's official
  asset under their brand guidelines — pre-release blocker.

## How to run

See [`SETUP.md`](./SETUP.md) for end-to-end instructions: Xcode
project generation, secrets, Supabase schema + migrations, OAuth
provider setup, the Express proxy, and the verification env-var
bypasses.

Short version:

```sh
./tools/xcodegen generate
cp Secrets.local.xcconfig.template Secrets.local.xcconfig
# edit your secrets
# run foodie_schema.sql + migrations/001 in Supabase SQL Editor
# in another shell: cd /path/to/server && npm install && npm run dev
open FoodieAI.xcodeproj
# Cmd+R
```

## Phases

The build was scaffolded in nine numbered phases (0–8). Each has a
verification report in the project root (`PHASE_0_CONFIRMATION.md`
through `PHASE_8_VERIFICATION.md`) covering:

- 0 — Confirmation of design system + schema reading
- 1 — Project scaffolding + secrets + Supabase package
- 2 — Theme port (color, font, spacing, radius, shadow)
- 3 — Component library (PillButton, BrandCard, DashedDropZone, etc.)
- 4 — Auth (Google OAuth round-trip)
- 5 — Capture & analyze flow
- 6 — Save & Tracker (RLS UUID-case bug found and fixed here)
- 7 — Profile + daily goals (missing-row self-heal)
- 8 — Polish + ship prep (this phase)

## Repo layout

```
FoodieAI/
├── FoodieAIApp.swift          # app entry + DEBUG bypass routes
├── Info.plist
├── PrivacyInfo.xcprivacy
├── Resources/
│   ├── Assets.xcassets/       # colors, fonts, panel SVGs, app icon
│   └── Fonts/
├── Core/
│   ├── FoodieClient.swift     # Supabase client + AppConfig
│   ├── Theme/                 # AppColor, AppFont, AppSpacing, etc.
│   └── Components/            # PillButton, BrandCard, DashedDropZone…
├── Models/                    # Codable types
├── Services/                  # Auth, FoodLog, FoodImage, Analyze, Profile
└── Features/
    ├── Onboarding/            # Landing + SignIn
    ├── Home/                  # Capture + Analyze + Save
    ├── Tracker/               # Daily entries + totals
    └── Profile/               # Goals + sign-out + about

migrations/                    # SQL migrations applied post-schema
foodie_schema.sql              # Initial Supabase schema
project.yml                    # xcodegen project spec
tools/xcodegen                 # Prebuilt xcodegen binary
```
