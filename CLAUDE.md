# FoodieAI iOS — Claude Code Build Prompt

## Mission

Build a native iOS app in SwiftUI that ports the FoodieAI web app to iOS
with **maximum visual parity** to the website's design system. The app uses
Supabase (via the Swift SDK) as its primary backend and a small Express
server only as a Gemini proxy for `POST /analyze`.

---

## The four files you must read before writing any code

1. **`DESIGN_SYSTEM.md`** (in this directory) — the extracted design audit.
   Every color, font size, spacing value, radius, shadow, animation, screen
   layout, and component spec is in there. **This is your contract.** Do not
   improvise visual decisions; if something is ambiguous, stop and ask.

2. **`foodie_schema.sql`** (in this directory) — the new Supabase schema.
   Run this top-to-bottom in the Supabase SQL Editor on a fresh project before
   any client testing. Note: `user_id` defaults to `auth.uid()` and RLS
   enforces per-user isolation; **never send `user_id` from the client on insert.**

3. **`FoodieSupabase.swift`** (in this directory) — starter Swift code with
   the Supabase client, Codable models, and service actors (auth, food log,
   image storage). Use this as the foundation; expand as needed.

4. **The web client source** at `<FILL_IN_LOCAL_PATH_TO_foodieAi_REPO>/client/src/`
   — original CSS and JSX for any detail not captured in `DESIGN_SYSTEM.md`.
   Treat this as the second source of truth after `DESIGN_SYSTEM.md`.

---

## Tech stack (non-negotiable)

- iOS 17+ deployment target
- Swift 5.9+ / SwiftUI only (UIKit only for unavoidable wrappers like camera)
- `supabase-swift` (https://github.com/supabase/supabase-swift) for auth, database, storage
- AuthenticationServices for Sign in with Apple
- PhotosUI / AVFoundation for image capture
- Native frameworks otherwise; async/await everywhere
- **No third-party UI libraries.** Recreate the web design in pure SwiftUI.

---

## The previous Supabase project was deleted

A fresh Supabase project is required. Set up:

1. New project at supabase.com
2. Run `foodie_schema.sql` in the SQL Editor
3. Enable Apple and Google providers under Authentication → Providers
4. Configure redirect URLs: `<your-bundle-id>://login-callback`
5. Capture the project URL + anon key for `Secrets.xcconfig`

---

## Project structure

```
FoodieAI/
├── FoodieAIApp.swift
├── Resources/
│   ├── Assets.xcassets        # color sets matching DESIGN_SYSTEM.md, app icon
│   └── Fonts/                 # M PLUS Rounded 1c (5 weights), Nunito (4 weights)
├── Core/
│   ├── FoodieClient.swift     # Supabase client singleton (from FoodieSupabase.swift)
│   ├── Theme/
│   │   ├── AppColor.swift     # 1:1 with DESIGN_SYSTEM.md color palette
│   │   ├── AppFont.swift      # 1:1 with DESIGN_SYSTEM.md type scale
│   │   ├── AppSpacing.swift   # xs/sm/md/lg/xl/2xl/3xl/4xl/5xl/6xl
│   │   ├── AppRadius.swift    # md/lg/xl/2xl/pill
│   │   └── AppShadow.swift    # nav/card/cardHover/image/upload
│   └── Components/            # Reusable views: PillButton, BrandCard, SpeechBubble,
│                              # DashedDropZone, AnalysisPanel, ProgressRing, etc.
├── Models/                    # Profile, FoodLog, NewFoodLog, DailyTotals, GeminiAnalysis
├── Services/
│   ├── AuthService.swift
│   ├── FoodLogService.swift
│   ├── FoodImageService.swift
│   └── AnalyzeService.swift   # multipart POST to /analyze
└── Features/
    ├── Onboarding/            # Landing + sign-in
    ├── Home/                  # Capture + analyze + result
    ├── Tracker/               # Daily totals + log list
    └── Profile/               # Daily goals + sign-out
```

---

## Build phases — work through these in order. Stop at each checkpoint.

### Phase 0 — Confirm understanding (CHECKPOINT)

Read `DESIGN_SYSTEM.md`, `foodie_schema.sql`, and `FoodieSupabase.swift`
in full. Then write a short `PHASE_0_CONFIRMATION.md` (max one page) that:

1. Lists the 5 most important visual decisions from `DESIGN_SYSTEM.md`
   that you'll need to get exactly right.
2. Lists any iOS-specific gotchas you anticipate (e.g., "M PLUS Rounded 1c
   weight 960 doesn't exist as a downloadable variant — will use 900").
3. States any questions about ambiguous specs.

**STOP and show me the confirmation. Do not start Phase 1 until I approve.**

### Phase 1 — Project scaffolding

- Create the Xcode project; set up the directory structure above.
- Add `supabase-swift` via Swift Package Manager.
- Create `Secrets.xcconfig` (gitignored) with:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
  - `ANALYZE_BASE_URL`
- Wire those into Info.plist via build settings; have `FoodieClient` read them at startup.
- Add `.gitignore` for `Secrets.xcconfig`, `xcuserdata/`, `*.xcuserstate`, `.DS_Store`.
- Drop `FoodieSupabase.swift` content into the appropriate files (don't keep
  it as one monolithic file).

### Phase 2 — Theme port

- Implement `AppColor`, `AppFont`, `AppSpacing`, `AppRadius`, `AppShadow`
  exactly per `DESIGN_SYSTEM.md`.
- Bundle font files. Register in Info.plist `UIAppFonts`. Verify with
  `UIFont.fontNames(forFamilyName:)` at app launch in DEBUG.
- Build a `ThemePreview` SwiftUI view that renders every color swatch (with
  hex label), every type style, every spacing block, every radius variant,
  and each shadow on a card. This is your visual regression check —
  reference it any time something looks "off."

### Phase 3 — Component library

Build the reusable components called out in `DESIGN_SYSTEM.md`. Each gets
a `#Preview` showing every state (default / pressed / disabled / etc.):

- `PillButton` — primary (brand-bordered), filled, ghost. The web "analyze"
  button and "sign-up" button both reduce to this.
- `BrandCard` — the shared `.card` style used on About / Education / Login.
  brandCream bg, radius 16, padding 28, card shadow, press-state lift (-5pt).
- `CircleActionButton` — Save (greenSave + check) / Cancel (orangeCancel + X).
  100×40, radius 20, scale-1.06 press state.
- `DashedDropZone` — 320×320 with dashed border per spec, "Meal Snap!" label
  + camera icon. Filled-state variant shows image with overlay on press.
- `SpeechBubble` — the coach-advice container with bottom-left corner squared.
  Brand fill, 8pt padding.
- `AnalysisPanel` — the lime/blue/gray panels with white border, h2 + icon,
  typewriter text rendering.
- `BouncingBadge` — the "free!" pill and the "resets at 12am" reminder.
- `BlurredNavBar` — fixed top bar with `.ultraThinMaterial`, logo + nav links
  / tab indicators + auth button.

### Phase 4 — Auth

- Implement Sign in with Apple via `SignInWithAppleButton` →
  `supabase.auth.signInWithIdToken(...)`.
- Implement Continue with Google via `ASWebAuthenticationSession` to the
  Supabase OAuth URL → SDK `exchangeCodeForSession`.
- Persist session across app launches using the SDK's session storage.
- Route logic: unauthenticated → Onboarding (Landing → Login); authenticated →
  TabView (Home, Tracker, Profile).
- Match the Login screen layout per `DESIGN_SYSTEM.md` Login section, but
  simplified for mobile: title + "free!" badge + two auth buttons + a single
  concise benefits paragraph (don't try to cram 3 cards on a phone screen).

### Phase 5 — Capture & analyze flow

- Native camera (AVFoundation) and photo picker (PhotosUI). Default to
  the photo picker; offer "Take Photo" as a secondary action.
- Compress to JPEG ~80% quality, max 2048pt long edge.
- `AnalyzeService.analyze(jpegData:)` → multipart POST to
  `{ANALYZE_BASE_URL}/analyze` with field name `image`.
- Decode response into `GeminiAnalysis`:

```swift
struct GeminiAnalysis: Codable {
    let fallback: String?
    let food: String
    let calories: Double
    let carbs: Double
    let sugar: Double
    let benefits: [String]
    let drawbacks: [String]
    let nutrients: [String]
    let coachAdvice: String
}

struct AnalyzeResponse: Codable {
    let analysis: GeminiAnalysis
    let coach: String?
}
```

- Result screen: implement per `DESIGN_SYSTEM.md` HomePage section.
  Calorie line with kerning 3, food name heavy, sugar/carbs in greenCalorie,
  speech bubble + coach name, three analysis panels stacked (mobile-first),
  typewriter at 20 ms/char advancing one item at a time.
- Save / Cancel circle buttons. On save → Phase 6.

### Phase 6 — Save & Tracker

On save:
1. `FoodImageService.upload(jpegData:)` → returns the storage path
   `{auth.uid()}/{uuid}.jpg`.
2. `FoodLogService.insert(...)` with `NewFoodLog`. **Do not include `user_id`.**

Tracker screen:
- Header card with brand→brandBright gradient, today's date, bouncing
  reminder pill.
- Read totals from `daily_food_totals` view via `FoodLogService.todaysTotals()`.
- List today's logs (most recent first), each card per spec.
- Empty state: "No data yet!" Loading state: spinner + "Loading...".

### Phase 7 — Profile

- Display name, avatar (optional), three daily-goal steppers
  (calories / carbs / sugar).
- Sign out button.
- Persist via `profiles` table updates.

### Phase 8 — Polish

- Dynamic Type support (verify all text scales gracefully).
- Dark mode pass — the brand cream/lime palette needs a dark variant
  decision. Default to forcing light mode if in doubt.
- App icon based on `foodie.png` (export to all required sizes).
- Privacy nutrition labels (Apple): camera, photo library, network.
- Empty / error / offline states for every screen.

---

## Done criteria

- Builds and runs cleanly on the iOS 17 simulator.
- Full loop works: Apple sign-in → photo → analyze → save → appears in
  Tracker with totals updated and the entry persisting after relaunch.
- Side-by-side screenshots of any web screen and its iOS equivalent show
  matching brand color, type, spacing, radii, shadows, and component shapes
  as much as platform conventions allow.
- `grep -r "user_id" Sources/` shows no occurrence in any client-side insert
  payload.
- All Supabase queries succeed using only the anon key (no service role on
  the client).
- Building the .ipa and grepping for the Gemini API key prefix returns nothing.

---

## Hard rules

- Do **not** invent design decisions. If `DESIGN_SYSTEM.md` is silent on
  something, check the web source under `client/src/`. If still ambiguous,
  stop and ask.
- Do **not** attempt to recover or use the deleted Supabase project.
- Do **not** call the deprecated `/save` or `/getFoodLogs` server endpoints.
  Use the Swift SDK against Supabase directly.
- Do **not** embed the Gemini API key in the iOS app.
- Do **not** introduce third-party UI, animation, icon, or networking libraries.
- Do **not** disable RLS, run anything as service-role from the client, or
  manually pass `user_id` on insert.
- Do **not** skip Phase 0.

---

## How to begin

Reply with: "Beginning Phase 0 — reading the design system and schema."
Read all four reference files, write `PHASE_0_CONFIRMATION.md` at the
project root, and stop for review.
