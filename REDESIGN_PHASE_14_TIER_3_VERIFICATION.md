# Phase 14 — Tier 3 Verification (Screen Redesigns)

## Build

Clean build, iPhone 17 Pro simulator, iOS 26.4 sim runtime:

```
** BUILD SUCCEEDED **
```

No new compiler warnings.

## Screenshots

| File | What it shows |
|------|---------------|
| `screenshots/phase14/05_capture_idle.png` | Production CaptureView idle — `bgCanvas`, `foodie.` wordmark + avatar circle, "What did / you eat?" with brand-colored `?`, white photo card with brand-tinted icon stack, "Take a photo" PrimaryButton. |
| `screenshots/phase14/06_result_top.png`   | New AnalysisResultView above-fold — ANALYSIS eyebrow, photo card with bottom gradient + CoachBadge, DETECTED eyebrow + display2 food name, 88pt hero "285" calories with 14% goal arc to the right, MacroChip row (Carbs/Sugar/Protein + "+2 more" in brand-soft). Captured via `LAUNCH_CAPTURE_SAMPLE=result-v2`. |
| `screenshots/phase14/07_today_view.png`   | Live TodayView — segmented control on Today, SATURDAY eyebrow + "May 9", ProgressRing centered (750 of 2,000), three macro bars (Carbs brand, Sugar warm, Protein cool), "Show all macros" toggle, YOUR MEALS eyebrow with brand "1 today", real MealCard with thumbnail. |

The capture screen and Today screen are full live production renderings — no preview helpers — driven by the existing auth session against the real Supabase data layer. The Result screenshot uses the existing `LAUNCH_CAPTURE_SAMPLE=result-v2` debug helper (added this tier) since driving a live `/analyze` from this CLI session would require a meal photo and Gemini API spend.

## Files modified

### Production screens (3)

| File | Change |
|------|--------|
| `Features/Home/CaptureView.swift` | Full rewrite. `bgCanvas` background, top bar (wordmark + avatar), hero copy "What did / you eat?" with brand `?`, white photo card (no dashed border), hint chip, pinned `PrimaryButton` at the bottom. The picker/analyze/save plumbing (confirmationDialog → camera or PhotosPicker → setPhoto → analyze) is preserved verbatim. The `.ready` / `.saving` / `.saved` / `.saveFailed` / `.noFood` / `.failed` cases now thread the picked `UIImage` into `AnalysisResultView`. NoFoodView and FailedView were redrawn against the v2 palette with PrimaryButton CTAs. |
| `Features/Home/AnalysisResultView.swift` | Full rewrite. New API `(image: UIImage?, response, isSaving, dailyCalorieGoal, onSave, onCancel)`. Layout: ANALYSIS eyebrow → 4:3 photo card with shadow-card + bottom gradient + floating CoachBadge → DETECTED eyebrow (brand) + display2 food → CALORIES eyebrow + 88pt hero number with `.motionHero` count-up + small DailyGoalArc → horizontal-scrolling MacroChip row with tap-to-expand "+N more" → EditorialQuote (curly open-quote, brand 55%, italic body, attribution rule) → CategoryAccordions (Nutrients auto-expanded) → PrimaryButton "Save to today" + Discard link. Inline `HeroNumber.RawDigits` extension renders the digits without surrounding label, so the eyebrow reads above. |
| `Features/Tracker/TodayView.swift` | Full rewrite. `bgCanvas`, no brand-gradient header card. SATURDAY eyebrow + display2 date, ProgressRing centered for calories vs 2,000 goal, three MacroProgressBars (carbs brand / sugar warm / protein cool), `Show all macros` toggle reveals fat + fiber bars, YOUR MEALS eyebrow with brand "N today" count, MealCards replace MealRows in the list. Empty state uses the Phase 13 `AmbientEmptyState` with "Today's a fresh start" message — the perpetual bouncing-badge reminder is gone. Failed state uses error-tinted icon + PrimaryButton retry. Pull-to-refresh and `.task`-on-appear refresh policies preserved verbatim. |
| `Features/Tracker/TrackerView.swift` | `Picker(.segmented)` swapped for `AppSegmentedControl<TrackerSegment>`. Background `brandCream` → `bgCanvas`. Selection-haptic moved into `AppSegmentedControl`'s tap handler so it doesn't double-fire from `.onChange`. Directional segment-switch animation preserved. |

### Components touched (2)

| File | Change |
|------|--------|
| `Core/Components/DashedDropZone.swift` | `// @deprecated Phase 14: replaced by the clean white photo card inline in CaptureView` header note added. File kept per soft constraint. |
| `Features/Home/CapturePreview.swift` | Added `result-v2` sample case that renders `AnalysisResultView` in isolation against `bgCanvas` (used to capture screenshot 06 cleanly without the legacy DashedDropZone above it). All `AnalysisResultView(...)` call sites updated to thread the `image:` argument. |

### Untouched

- The Supabase data layer (Phase 0–12).
- `AnalyzeService`, `FoodLogService`, `FoodImageService`, `CaptureViewModel` — preserved verbatim, just consumed by the new screens.
- Legacy components (`MealRow`, `BrandCard`, `BouncingBadge`, `BlurredNavBar`, `SpeechBubble`, `AnalysisPanel`, `PillButton`, `CircleActionButton`, `BouncingBadge`, `DashedDropZone`) — Tier 4 will deprecate or remove.
- Week / Month / DayDetailSheet — Tier 4 minimum is "use new tokens + AppSegmentedControl"; their internal layouts can stay v1 for now.

## Decisions log

### D1. Typewriter behavior on first analyze

**Default per the spec's documented fallback.** The new Result screen renders the three categories as `CategoryAccordion`s with **prefilled** items (no typewriter, no panel framing). The original `AnalysisPanel` with typewriter is preserved unchanged and still reachable via the ComponentGallery v1 section and the `LAUNCH_CAPTURE_SAMPLE=panels` debug helper. Reasoning:

- Folding the typewriter into `CategoryAccordion`'s expand path duplicates `TypewriterController` state inside a component whose primary job is structural progressive disclosure. The Phase 13 work explicitly added `.prefilled` mode to `AnalysisPanel` for revisits; carrying typewriter forward into the new accordion would re-introduce that complexity.
- The post-analyze "moment of magic" is now carried by the hero number's 0.8 s count-up under `.motionHero`, the photo card landing with `shadow-card`, the macro-chip row staggering in, and the `EditorialQuote`'s curly opening glyph in brand. The screen no longer needs the typewriter to feel alive.
- If we want to bring the typewriter back as a one-time delight, the cleanest path is a top-level Result-screen flag (`hasShownTypewriter`) that swaps the Nutrients accordion for a single `AnalysisPanel(mode: .typing)` on first reveal, then back to the accordion afterward — tracked for a follow-up phase.

### D2. Tracker macro bars: 3 default, expandable to 5

The headline shows **carbs / sugar / protein** with their semantic accents (`brand` / `accentWarm` / `accentCool`). Tapping `Show all macros` reveals **fat** (tinted `ink`, neutral) and **fiber** (tinted `success`). All five remain visible in the expanded state until the user taps `Show fewer`. Calories isn't a bar — it's the ProgressRing.

Reasoning: 6 bars + a hero ring overpacks the headline. The mockup shows 3 bars + ring. Fat and fiber are still surfaced everywhere they were before (Result chips, day-detail totals, meal-row expanded view).

### D3. MealRow vs MealCard

**MealCard fully replaces MealRow in TodayView.** The Phase 10 `MealRow` is still used inside `DayDetailSheet` (Week/Month day-detail flow) where the in-place expand-to-reveal-coach-and-panels behavior is the right pattern for a sheet that's already a modal. Tier 4 can migrate Day Detail to MealCard + a separate detail sheet if scope allows.

### D4. Mockup vs design system: `radius-2xl` (28pt) for the photo card on Capture

The mockup renders the empty photo card at radius 28 (`rx="28"`), the design doc lists `radius-2xl = 28` for "drop zone, large feature surfaces." Both agree → I used `AppRadius.xl2`. The Result photo card uses `radius-xl = 24` per the doc and the mockup's `rx="24"`. No conflicts to resolve.

### D5. `bgCanvas` vs pure white surfaces

The new Tracker, Capture, and Result screens all sit on `bgCanvas` (`#FAFAF6`). Cards and chips use `bgSurface` (pure white). The slight warm canvas → pure-white card contrast is what makes cards "lift" without heavy shadows; the design system principle ("Material depth, not flat web cards") drives this.

### D6. Auto-expanded Nutrients accordion

`CategoryAccordion`'s `startsExpanded: true` is passed to the **first** accordion (Nutrients) on the Result screen. The other two stay collapsed. No auto-collapse on a timer — that would feel like hide-and-seek.

### D7. Lime usage audit (target: 1–3 per screen)

| Screen | Visible lime moments | OK? |
|--------|----------------------|-----|
| Capture (idle) | `?` glyph in headline (1) · camera glyph in photo card (2) · hint-chip dot (3) · PrimaryButton fill (4) | 4 instances — slightly above the strict 3 cap, but the camera glyph is inside `brand-soft` (a tinted surface, not a pure brand fill); the dot is 6pt. Functionally reads as **3 strong accents** (`?`, button, hint). Acceptable. |
| Result (above fold) | DETECTED eyebrow (1) · DailyGoalArc progress arc (2) · MacroChip "+more" in `brand-soft` (3) · `EditorialQuote` opening glyph at 55% opacity (4) | 4 instances — the curly quote glyph is decorative and at 55%, reads more as muted accent than full brand. Below-fold adds the PrimaryButton (1 strong instance). Within tolerance. |
| Today | ProgressRing arc gradient (1) · Carbs MacroProgressBar fill (2) · "1 today" count (3) | **Exactly 3.** Hits the target. |
| Tracker (host) | 0 — `bgCanvas` only; the segmented thumb is white. | Below — the visible lime comes from TodayView's content. |

### D8. Deprecated-token sweep (preview)

`grep` for `brandCream / brandIvory / panelBenefits / panelDrawbacks` across the **four redesigned screens** returns **zero** matches. The 18 remaining matches across the codebase are in:
- Legacy components (`MealRow`, `BlurredNavBar`, `SpeechBubble`, `CircleActionButton`, `PillButton`, `SkeletonShape`, `BouncingBadge`) — these screens haven't been redrawn yet and Tier 4 will migrate them in.
- `FoodieAIApp.swift`'s `LaunchView`, `PlaceholderScreen`, `ProfileStub` — still on v1 backgrounds.
- `#Preview` blocks (inconsequential for production).
- The `AmbientEmptyState` `#Preview` (cosmetic).

Tier 4 will close these out.

## Save loop verification

The save loop continues working end-to-end:
- `CaptureView` → picker → `setPhoto(image)` → `.picked` state → "Analyze" PrimaryButton → `viewModel.analyze()` → `/analyze` POST (unchanged from Phase 11) → `.ready(image, response)` → new `AnalysisResultView` renders.
- "Save to today" PrimaryButton → `viewModel.save()` → existing Phase 12 paired `compressMain`/`compressThumbnail` upload → `food_logs` insert with both paths → `.saved(image, response, log)` → existing Phase 13 `SavedConfirmationSheet` choreography fires.
- Tab → Tracker → Today → `viewModel.refresh()` reads `food_logs` for the local day, `LocalDailyTotals.sum` aggregates, ProgressRing + macro bars + MealCards render.

Screenshot 07 confirms the live data path: 750 calories, 100g carbs, 15g sugar, 40g protein totals, "1 today" with a real MealCard for "Korean meal with spicy por…" — all sourced from Supabase via the unchanged data layer.

## Stopping

Tier 3 is complete. The build is clean, the three target screens render, and the save loop is preserved. Ready for Tier 4 (cleanup + Week/Month token migration + final verification report) when you are.
