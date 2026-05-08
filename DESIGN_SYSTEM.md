# FoodieAI iOS — Design System

Extracted from the web client (`foodieAi/client`) on May 2026.
This document is the single source of truth for visual design.
If something is ambiguous here, stop and ask before improvising.

---

## What the app is

An AI food analyzer. The user snaps a photo of a meal; the server forwards
the image to Google Gemini and returns calories, carbs, sugar, a list of
benefits, drawbacks, key nutrients, and a piece of witty advice voiced by
a randomly chosen historical figure (the "celebrity coach"). Authenticated
users can save meals to a daily tracker that resets at midnight.

The web app has 7 routes; only 2 (HomePage and DailyTracker) are core. The
others (Landing, About, MyStory, Education, Login) are marketing/auth content
that should be simplified or consolidated for iOS.

---

## Color palette

These hex values are extracted directly from the web CSS. Do not approximate.

### Brand (lime / cream / dark green)

| Token            | Web value                 | Hex      | Use                                          |
|------------------|---------------------------|----------|----------------------------------------------|
| brand            | rgb(184, 202, 56)         | #B8CA38  | Primary lime — buttons, active states, accents |
| brandActive      | rgb(172, 195, 0)          | #ACC300  | Active nav link                              |
| brandHover       | rgb(167, 173, 120)        | #A7AD78  | Nav link hover                               |
| brandBright      | rgb(226, 244, 93)         | #E2F45D  | Daily-tracker gradient end                   |
| brandCream       | rgb(248, 255, 197)        | #F8FFC5  | Landing bg, About/Education card bg          |
| brandCreamSoft   | rgb(247, 255, 196)        | #F7FFC4  | Sign-up button background                    |
| brandIvory       | #fcfff8                   | #FCFFF8  | Food-data card bg, modal bg                  |

### Accent

| Token            | Web value                 | Hex      | Use                                       |
|------------------|---------------------------|----------|-------------------------------------------|
| greenSave        | rgb(0, 97, 71)            | #006147  | Save button                               |
| greenCalorie     | rgb(19, 57, 0)            | #133900  | Calorie/sugar/carbs text                  |
| greenAnalysis    | rgb(49, 56, 3)            | #313803  | Analysis-column text                      |
| oliveQuote       | rgb(130, 139, 65)         | #828B41  | Pull-quote marks (My Story)               |
| oliveDrab        | olivedrab                 | #6B8E23  | "free!" badge                             |
| orangeBadge      | rgb(255, 145, 28)         | #FF911C  | Free-pop-up badge, daily-tracker reminder |
| orangeCancel     | rgb(206, 65, 0)           | #CE4100  | Cancel button                             |
| redError         | rgb(255, 39, 39)          | #FF2727  | "No food detected", validation errors     |
| panelBenefits    | #add8e6                   | #ADD8E6  | Benefits column background                |
| panelDrawbacks   | #a9a9a9                   | #A9A9A9  | Drawbacks column background               |
| pinkGlow         | rgba(255, 105, 180, 0.6)  | —        | Modal close-button hover glow             |

### Neutrals

| Token        | Web value                                  | Use                                |
|--------------|--------------------------------------------|------------------------------------|
| textPrimary  | #212120 (--clr-dark-900)                   | Headlines                          |
| textBody     | #242424                                    | Body text                          |
| textMeta     | #7d7d7d                                    | Timestamps, captions               |
| siteBg       | linear-gradient(to right, #f8fffc, #fff9f1) | Default page background            |
| navBg        | rgba(232, 255, 198, 0.094)                 | Nav background under blur          |

---

## Typography

### Fonts

Both fonts must be bundled as `.ttf` files in `Resources/Fonts/`, registered
in `Info.plist` under `UIAppFonts`, and surfaced via a `Font` extension.
SwiftUI's system fonts will not match the brand identity.

- **M PLUS Rounded 1c** (Google Fonts). Display/brand. Weights 300, 400, 500, 700, 800, 900.
- **Nunito** (Google Fonts). Body. Weights 400, 600, 700, 800.

### Type scale

| Token        | Size                            | Weight | Family            | Use                                           |
|--------------|----------------------------------|--------|-------------------|-----------------------------------------------|
| displayXL    | clamp(3rem, 6vw, 5rem) ≈ 48–80pt | 500    | M PLUS Rounded 1c | Landing hero "Foodie Ai."                     |
| displayLG    | clamp(2.5rem, 5vw, 4rem) ≈ 40–64pt | 800  | M PLUS Rounded 1c | Page titles (About, Education)                |
| displayMD    | 2rem ≈ 32pt                      | 800    | M PLUS Rounded 1c | "Become a member!", welcome message           |
| bodyLG       | 1.5rem ≈ 24pt                    | 600    | Nunito            | Page descriptions                             |
| foodName     | 2.2rem desktop / 1.5rem mobile   | 800    | Nunito            | Detected food name                            |
| kcal         | ≈ 28pt                            | 900, kerning 3 | Nunito    | Calorie number with letter-spacing            |
| nav          | 1.1rem ≈ 17.6pt                  | 700    | Nunito            | Nav links                                     |
| body         | 1.125rem ≈ 18pt                  | 400–700 | Nunito           | Default body                                  |
| meta         | 0.7–0.8rem ≈ 11–13pt             | 700    | Nunito            | Timestamps, small captions                    |

iOS weight mapping for the non-standard CSS weights used: 660≈semibold, 680≈semibold,
800≈heavy, 850≈heavy, 900≈black, 960≈black.

---

## Spacing scale

The web uses ad-hoc rem values. Standardize for iOS:

| Token | Points | Web equivalent |
|-------|--------|-----------------|
| xs    | 4 pt   | 0.25rem |
| sm    | 8 pt   | 0.5rem |
| md    | 16 pt  | 1rem |
| lg    | 24 pt  | 1.5rem |
| xl    | 32 pt  | 2rem |
| 2xl   | 48 pt  | 3rem |
| 3xl   | 64 pt  | 4rem |
| 4xl   | 96 pt  | 6rem |
| 5xl   | 112 pt | 7rem (page padding) |
| 6xl   | 160 pt | 10rem (home top padding) |

---

## Border radius

| Token   | Value    | Use                                                       |
|---------|----------|-----------------------------------------------------------|
| md      | 10 pt    | Reminder pill, free pop-up, image preview                 |
| lg      | 15 pt    | Saved-meal modal, food-data card, save/cancel buttons     |
| xl      | 16 pt    | About / Education / Login cards (1rem)                    |
| 2xl     | 20 pt    | Photo upload zone (1.25rem)                               |
| pill    | 9999 pt  | Sign-up, analyze, "Try for FREE" buttons (50rem)          |

---

## Shadows

| Token       | Value                                                                                      |
|-------------|--------------------------------------------------------------------------------------------|
| nav         | 1px 1px 0 rgba(66, 70, 24, 0.094)                                                          |
| card        | rgba(50, 50, 93, 0.25) 0 2 5 -1, rgba(0, 0, 0, 0.3) 0 1 3 -1                               |
| cardHover   | rgba(50, 50, 93, 0.35) 0 4 10 -2, rgba(0, 0, 0, 0.4) 0 2 6 -2 (also translateY −5pt)        |
| image       | 2 2 2 rgba(34, 0, 0, 0.413)                                                                |
| upload      | rgba(50, 50, 93, 0.25) 0 13 27 -5, rgba(0, 0, 0, 0.3) 0 8 16 -8                            |

In SwiftUI, approximate with a single `.shadow(color:, radius:, x:, y:)` plus an
optional second shadow modifier. The exact filter syntax doesn't translate;
match by perceptual closeness.

---

## Critical effect mappings (web → SwiftUI)

| Web idiom                                                       | SwiftUI equivalent                                                                                  |
|------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `backdrop-filter: blur(50px)` on translucent navbar              | `.background(.ultraThinMaterial)` on a sticky header. **Do not** try to roll your own blur.          |
| Inline-SVG dashed border on photo upload                         | `RoundedRectangle(cornerRadius: 20).strokeBorder(.gray, style: StrokeStyle(lineWidth: 6, dash: [6, 14]))` |
| Speech bubble with corner squared (`20px 20px 20px 0`)           | `UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: 0, bottomTrailing: 20, topTrailing: 20))` |
| `letter-spacing: 3px`                                            | `.kerning(3)`                                                                                        |
| `clamp()` typography                                             | Use a Dynamic Type style or compute size from `UIScreen.main.bounds.width` once at app launch        |
| Multiply blend + sepia hue-rotate on hero image                   | Apply `.blendMode(.multiply)` over a colored overlay; skip sepia/hue-rotate (they're decorative)     |
| Hover states (`:hover`)                                          | iOS has no hover. Map to **press state** via `.scaleEffect(isPressed ? 1.06 : 1.0)`                  |
| `linear-gradient(to bottom left, ...)`                            | `LinearGradient(colors: [...], startPoint: .topTrailing, endPoint: .bottomLeading)`                  |

---

## Animation patterns (framer-motion → SwiftUI)

| Web pattern                                                                                       | SwiftUI                                                                                            |
|----------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `initial={{opacity: 0, y: 20}} animate={{opacity: 1, y: 0}} transition={{duration: 0.3}}`         | `.transition(.opacity.combined(with: .move(edge: .bottom)))` with `.easeOut(duration: 0.3)`        |
| `transition: { type: "spring", stiffness: 110, damping: 12 }`                                     | `.spring(response: 0.5, dampingFraction: 0.7)`                                                     |
| Three columns slide in from `x: -200/200 → 0`                                                     | `.transition(.move(edge: .leading))` and `.move(edge: .trailing)`                                  |
| Staggered scale-in on analysis (durations 0.5/0.8/1.2/1.5)                                        | `withAnimation(.easeOut(duration: 0.5).delay(Double(index) * 0.3))`                                |
| Typewriter at 20 ms/char on nutrients/benefits/drawbacks (sequential array items)                 | Custom: `Timer.publish(every: 0.02)` or `AsyncStream` emitting one char then advancing index       |
| `whileHover={{scale: 1.06}}` (save/cancel buttons)                                                | Press state via `Button` with `ButtonStyle` that scales on `configuration.isPressed`                |
| Reminder bouncing y `[0, 5, -4, 1, -3, 0]` repeating                                              | `.offset(y: animate ? -3 : 0).animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: animate)` |
| `.free` badge `bounce 1.2s infinite`                                                              | Same pattern as above with shorter duration                                                        |
| Sidebar slide-in from right                                                                       | `.transition(.move(edge: .trailing))` + dim background overlay                                     |

---

## Routes / Screens

### 1. LandingPage `/landingpage`
- Cream bg `#F8FFC5`. Full-bleed.
- Top-left: "Foodie Ai." in M PLUS Rounded 1c at displayXL, weight 500.
- Hero region (60% of viewport height): hero photo `landingpage-bg.png` with multiply blend over `rgba(40, 50, 0, 0.4)`. White text/CTA.
- Bottom-of-hero CTA: pill button "Try for FREE" — white border 1pt, transparent fill, weight 800, font 1.25–1.5rem.
- Below hero: slogan h2 at displayMD weight 500 in textPrimary: "Curious about your meal? Foodie uses a little AI magic to break down what you're eating."
- Footer: simple `© 2025 Foodie @loren.`

### 2. HomePage `/` and `/homepage` (the core flow)
- Welcome headline at top (M PLUS Rounded 1c, 2rem, weight 900, color #343633): "Upload or snap a meal to get insights!"
- **FoodUploadForm** (centered, 320×320pt):
  - Empty state: dashed-border square (color #999, lineWidth 6, dash [6, 14], radius 20pt). Inside: "Meal Snap!" plus camera icon. Background `#0000000e` (very subtle dark tint).
  - Picked state: image fills the square with `cardHover` shadow. Press reveals overlay with camera icon + "Change Photo".
- "Analyze" pill button below (only after image picked): 2pt brand border, padding 16×64pt, weight 700, font 1.25rem. Press lifts (-2pt) with shadow. While analyzing: text becomes "Analyzing..." and is disabled.
- After API response:
  - **Calorie line**: number + "calories" with kerning 3, weight 900, color greenCalorie.
  - **Food name**: 2.2rem heavy.
  - **Sugar / Carbs**: smaller, weight 600, color greenCalorie.
  - **Coach speech bubble**: brand fill, padding 8pt, radius `20pt 20pt 20pt 0pt`. Width ~50% of container. Below the bubble: small italic "{coachName} ~~".
  - **Save / Cancel buttons** (circular pill, 100w × 40h, radius 20):
    - Cancel: orangeCancel bg, white X icon (Material Symbol path).
    - Save: greenSave bg, white check icon.
    - Both use scale-1.06 press state.
    - On save: post to Supabase, show SavedMealModal.
- **Three analysis panels** (the showpiece):
  - Each is 30% width on desktop, full-width stacked on mobile.
  - Padding 16pt, radius 15pt, white border 8pt (`rgb(255, 248, 248)`). Min height 200pt.
  - Nutrients: brand bg, greenAnalysis text.
  - Benefits: panelBenefits bg.
  - Drawbacks: panelDrawbacks bg.
  - Each has h2 + small SVG icon (nutrients.svg / benefits.svg / drawbacks.svg).
  - Items render with **typewriter effect**: 20 ms per character, one item at a time, advancing only after the previous item finishes.
  - Slide-in transitions: Nutrients from left, Benefits from right, Drawbacks from right (staggered).

### 3. DailyTracker `/dailytracker` (auth required)
- Page top padding to clear nav (~80pt).
- Header card: gradient `linear-gradient(to bottom-left, brand, brandBright)`, padding 16×32pt, radius 15pt, white text.
  - "Today, {long month} {day}" h2.
  - Bouncing reminder pill: orangeBadge bg, font 0.5rem, "Daily tracker resets every 12:00 am". Bounces y subtly forever.
  - Totals block: total calories big (h1), then "Total sugar: X g" / "Total carbs: X g" rows below.
- List of food entries:
  - Each entry: `.brandIvory` bg, radius 15pt, padding 16pt.
  - Time stamp (12-hour) in textMeta, small.
  - food_name h3.
  - Calories / Sugar (g) / Carbs (g) lines.
  - Items fade in staggered (delay i × 0.2 s).
- Empty state: "No data yet!"
- Loading: spinner + "Loading..." in textIvory color.

### 4. Login `/login`
- Page padding 7rem 1rem.
- Title block (centered): "Become a member!" displayMD weight 800. To the right: bouncing "free!" pill (oliveDrab bg, white text, weight bold).
- Auth UI: currently `@supabase/auth-ui-react` with Google-only OAuth.
  - **iOS adaptation**: replace with two native auth buttons:
    1. Sign in with Apple (`SignInWithAppleButton` from AuthenticationServices)
    2. Continue with Google (`ASWebAuthenticationSession` flow → Supabase `signInWithIdToken`)
- Three benefit cards in a 3 / 2 / 1 column responsive grid:
  - "Daily tracker:" — calories/sugar/carbs bullets, save & track checkmarks.
  - "Health goals" — set-a-goal options + AI badge/warn behavior.
  - "Save scanned food:" — today's-foods view + totals.
- Each uses the shared `.card` style: brandCream bg, radius 16pt, padding 28pt, `card`/`cardHover` shadow, `translateY -5` hover.

### 5. About `/about`
- Title block: "Foodie Ai." displayLG weight 800 + description "A food analyzer tool that uses multi-modal AI — powerful and efficient." at bodyLG.
- Three `.card`s in same 3/2/1 grid:
  - "How It Works" — Upload → AI analyzes → "Get instant and structured results" output.
  - "Why I Built This" — vision statement.
  - "How I Built foodieAi." — tech credit (Google Gemini).
- Each card has a closing line in greenCalorie / weight 700 / labeled `.output`.

### 6. MyStory `/mystory`
Founder bio. **Optional for iOS** — consider folding into a Settings/About sheet to reduce navigation depth.
- Two-column desktop grid (article 3fr / profile 1fr); single column mobile (profile on top).
- Profile aside: rounded image (profileFb.jpg), "Hi! It's Loren" + "(Founder)", three social links (IG/FB/Twitter) at 20–30pt with scale-1.2 hover.
- Article: pull-quote at top with oversized open/close quote marks (oliveQuote, 7rem/3rem, opacity 0.3, positioned absolute), then 3 sections of paragraphs.

### 7. Education `/education`
- Title "Education mode" displayLG + description "Fun facts about foods!"
- Three `.card`s in 3/2/1 grid:
  - "Why fiber is important" — Cancer Prevention, Heart Health.
  - "Carbs" — Good vs. bad carbs.
  - "How sugar affects body" — single long paragraph.

---

## Navigation

### Public users
- Home, My Story, About, Education
- Right side: "Sign Up!" pill (brandCreamSoft bg, brand 2pt border, hover fills with brand and turns text white).

### Authenticated users
- Home, Daily Tracker
- Right side: "Log out" pill (same styling).

### Mobile (<48em / <768pt)
- Hamburger top-right.
- Slide-in sidebar from right (320pt wide on tablet, 200pt on phone).
- White bg, top padding 80pt, vertical link stack, auth pill button at bottom.
- Backdrop overlay 50% black; tap to close.

### iOS adaptation
- Use `TabView` for the authenticated app: Home, Daily Tracker, Profile.
- Public users (not signed in) see only the LandingPage → Login flow; gate everything else.
- Drop the slide-in sidebar; use a tab bar instead. Reserve hamburger pattern for occasional secondary menus.

---

## Auth flow

The web uses Supabase Auth UI with Google-only OAuth (`onlyThirdPartyProviders={true}`,
`providers={['google']}`).

### iOS requirements
- **Sign in with Apple is required** (App Store Review Guideline 4.8) when offering any third-party social sign-in. Add it.
- Use Supabase Swift SDK's native methods, not the web auth UI.
- Apple: `AuthenticationServices.SignInWithAppleButton` → get id-token → `supabase.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: token))`.
- Google: `ASWebAuthenticationSession` to the Supabase OAuth URL → exchange code for session via the SDK.

---

## Asset bundling

Copy these from `client/src/assets/` into `Resources/Assets.xcassets`:

| Web asset                                  | iOS asset / replacement                                         |
|--------------------------------------------|------------------------------------------------------------------|
| `foodie.png` (logo)                        | Bundle as 1x/2x/3x in Assets.xcassets                            |
| `landingpage-bg.png` (9.1 MB!)             | **Re-export** at 1242×2208 max for iPhone; original is wasteful  |
| `benefits.svg`, `drawbacks.svg`, `nutrients.svg` | Import as PDF-vector assets, or replace with SF Symbols (`leaf.fill`, `exclamationmark.triangle.fill`, `pills.fill`) |
| `upload.svg` (camera)                      | Replace with SF Symbol `camera.fill`                             |
| `Facebook_Logo_Primary.png`, `Instagram_Glyph_Gradient.png` | Skip if MyStory is cut. Otherwise SF Symbol `link` |
| `profileFb.jpg`                            | Bundle only if MyStory ships                                     |

Also bundle the font files:
- `M PLUS Rounded 1c` weights 400, 500, 700, 800, 900 → `Resources/Fonts/`
- `Nunito` weights 400, 600, 700, 800 → `Resources/Fonts/`
- Register in Info.plist `UIAppFonts` array.

---

## API contract (server `POST /analyze`)

Multipart upload, single field `image` (JPEG/PNG, max 10 MB).

Response on success:
```json
{
  "analysis": {
    "fallback": null,
    "food": "Margherita Pizza",
    "calories": 450,
    "sugar": 8,
    "carbs": 55,
    "benefits": ["Provides calcium...", "Contains lycopene...", "Source of protein..."],
    "drawbacks": ["High in refined carbs...", "Sodium content...", "Consider whole-grain crust..."],
    "nutrients": ["Calcium: bone health - Health score: 70", "Lycopene: ...", "Protein: ..."],
    "coachAdvice": "..."
  },
  "coach": "Albert Einstein"
}
```

If no food is detected:
```json
{ "analysis": { "fallback": "No food detected" } }
```

The response does **not** include protein/fat/fiber. The Supabase schema reserves
columns for them; they will be NULL until the Gemini schema is extended.

---

## Hard rules (carry into every phase)

1. The brand color `#B8CA38` is non-negotiable. It appears on every screen.
2. M PLUS Rounded 1c on every display heading. Nunito everywhere else.
3. The 3-color analysis panels (lime / blue / gray) are the brand's most
   recognizable visual element — get them right.
4. The typewriter effect on analysis output is a signature interaction;
   match the 20 ms/char timing.
5. The speech bubble for coach advice has the bottom-left corner squared off.
6. All Supabase calls go directly from iOS via the Swift SDK with RLS.
   Never include `user_id` in an insert payload.
7. The Gemini API key never leaves the server. iOS only knows `/analyze`.
