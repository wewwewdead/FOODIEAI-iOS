# Phase 0 Confirmation — FoodieAI iOS

I've read `DESIGN_SYSTEM.md`, `foodie_schema.sql`, and `FoodieSupabase.swift` end-to-end. Stopping here for review per CLAUDE.md.

---

## 1. Five visual decisions I must get exactly right

1. **Brand palette by hex, not approximation.** Twenty-two tokens in `DESIGN_SYSTEM.md` §Color (brand `#B8CA38`, brandBright `#E2F45D`, brandCream `#F8FFC5`, brandIvory `#FCFFF8`, greenSave `#006147`, greenCalorie `#133900`, panelBenefits `#ADD8E6`, panelDrawbacks `#A9A9A9`, orangeCancel `#CE4100`, etc.). Each becomes a Color Set in `Assets.xcassets` with the literal hex. No HSB drift. Brand `#B8CA38` is the most-used color and is non-negotiable.

2. **Custom fonts everywhere — display vs. body.** M PLUS Rounded 1c (300/400/500/700/800/900) for every display heading; Nunito (400/600/700/800) for body and nav. Bundled as static `.ttf` per weight, registered in `Info.plist > UIAppFonts`. SwiftUI system fonts are off-limits for branded text. The `kcal` token is the canonical example: weight 900, kerning 3, color greenCalorie — the calorie line on the result screen lives or dies on this.

3. **Three analysis panels (lime / blue / gray) with typewriter.** Radius 15pt, padding 16pt, **8pt white inner border `#FFF8F8`**, min-height 200pt, h2 + small icon. Body items render via a 20 ms/char typewriter that advances one item at a time only after the previous finishes. Slide-in transitions: Nutrients from left, Benefits/Drawbacks from right, staggered (0.5 / 0.8 / 1.2 / 1.5 s). This is the brand's signature interaction.

4. **Coach speech bubble with bottom-left corner squared.** `UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: 0, bottomTrailing: 20, topTrailing: 20))`, brand fill, 8pt padding, ~50% container width. The squared corner is what makes it read as a speech bubble; if I round it I've broken the design.

5. **The two button shapes that recur across screens.**
   - **PillButton** (Analyze / Sign Up / Try for FREE): radius 9999pt, 2pt brand border, transparent or brandCreamSoft fill, font 1.25rem weight 700, padding 16×64pt, press lifts –2pt.
   - **CircleActionButton** (Save / Cancel): 100×40pt, radius 20pt, greenSave + check / orangeCancel + X, scale 1.06 press.
   These two cover ~90% of CTAs in the app, so I'll build them once as parameterized `ButtonStyle`s.

## 2. iOS-specific gotchas I anticipate

- **Non-standard CSS weights (660 / 680 / 850 / 960) don't ship as font files.** I'll snap to the nearest bundled weight per the mapping table (660/680 → 700, 850 → 900, 960 → 900) inside a `AppFont.weight(_:)` helper so callers stay declarative.
- **No `:hover` on iOS.** Web `translateY(-5pt)` on cards and `scale(1.06)` on save/cancel become press states inside `ButtonStyle.makeBody`. I will not wire `.onHover` (it only fires on iPad with a pointer attached).
- **`backdrop-filter: blur(50px)` ≠ rolling my own.** `.background(.ultraThinMaterial)` on a sticky header. I won't try to fake it with `.blur()`, which blurs the layer's own content, not what's behind it.
- **`clamp()` typography has no SwiftUI equivalent.** I'll compute font sizes once at launch from `UIScreen.main.bounds.width` (linearly interpolated between min and max) and expose them via `AppFont.displayXL` etc. Dynamic Type scaling is layered on top via `.dynamicTypeSize(...)` clamps.
- **`landingpage-bg.png` is 9.1 MB.** Re-export to 1242×2208 max @ ~80% JPEG before adding to assets. The original is wasteful and bloats the .ipa.
- **Storage RLS depends on path prefix.** `FoodImageService.upload` already prepends `{auth.uid()}/` — must not "simplify" that away.
- **`daily_food_totals` view buckets by UTC date** while the UI says "Today, {long month} {day}" in local time. Edge case for users far from UTC near midnight; I'll surface this as a question (#2 below) before deciding.
- **Sign in with Apple is required** by App Store guideline 4.8 because we offer Google. Web has Apple disabled — I'm adding it.

## 3. Questions on ambiguous specs

1. **Web client path.** CLAUDE.md references `<FILL_IN_LOCAL_PATH_TO_foodieAi_REPO>/client/src/` as the second source of truth, but the placeholder isn't filled. Is the web repo cloned locally somewhere, or should I treat `DESIGN_SYSTEM.md` as the only available source for visual details?

2. **Tracker "today" — local day or UTC day?** The schema view groups by UTC date; the UI displays a local-formatted day label. For a PST user opening at 11 pm, the two disagree. Preference: local-day grouping in the iOS query (passing the user's local-day boundaries to `eaten_at` filters) and ignoring the view for the header total. OK?

3. **Dark mode.** CLAUDE.md says "default to forcing light mode if in doubt." Confirm: lock `.preferredColorScheme(.light)` app-wide in Phase 1 and revisit dark variants in Phase 8 only if you ask?

4. **`textIvory` color.** Mentioned once in §DailyTracker loading state but not present in the palette table. Best guess: `brandIvory` (#FCFFF8). Confirm or supply the intended hex.

5. **Avatar in Profile.** Schema has `avatar_url`; spec says "(optional)". Plan: ship Phase 7 with display-name + goals only, defer avatar upload. Acceptable?

6. **MyStory and Education routes.** CLAUDE.md scopes the iOS app to Onboarding / Home / Tracker / Profile — neither MyStory nor Education appear in the tab bar plan. Confirm these are dropped (or folded into a Profile/About sheet later)?

---

**Awaiting approval before starting Phase 1.**
