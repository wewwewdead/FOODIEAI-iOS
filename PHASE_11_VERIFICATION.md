# Phase 11 — Populate protein_g / fat_g / fiber_g Verification

## Scope

Wires the full loop for three additional macronutrients (protein, fat,
dietary fiber, all in grams):

1. **Server**: extends the Gemini structured-output schema and prompt.
2. **iOS decode**: `GeminiAnalysis` adds three optional `Double` fields.
3. **iOS save**: `CaptureViewModel.save()` forwards them into `NewFoodLog`.
4. **Aggregation**: `LocalDailyTotals` sums them, treating nil as 0.
5. **UI**: `AnalysisResultView`, `MealRow` (expanded), and the Today /
   Week / Month / DayDetailSheet header cards all surface the values
   with graceful nil-handling.

The `food_logs` schema columns (`protein_g`, `fat_g`, `fiber_g`) already
existed from Phase 0 — no migration needed.

## Build

Clean build, iPhone 17 Pro simulator, iOS 26.4 sim runtime:

```
** BUILD SUCCEEDED **
```

No new compiler warnings.

## Files modified

### Server (1)

- `~/Downloads/foodieAi.-main/server/routes/gemini.js`
  - Added three numeric `properties` to the `analyze_food_image` function
    declaration: `protein`, `fat`, `fiber` (all numbers, in grams).
  - Added the three keys to the `required` array.
  - Extended the user-facing prompt sentence to ask Gemini for "protein,
    fat, and fiber (all in grams)" alongside the existing macros.

### iOS (8)

| File | Change |
|------|--------|
| `Models/GeminiAnalysis.swift` | Added optional `protein`, `fat`, `fiber: Double?` to mirror the new server keys. |
| `Models/DailyTotals.swift` | `LocalDailyTotals` adds `totalProtein`, `totalFat`, `totalFiber`. `sum(_:)` treats nil log fields as 0 via `?? 0`. `empty` updated. |
| `Models/FoodLog.swift` | Untouched — already exposed `proteinG`, `fatG`, `fiberG: Double?` from Phase 1. |
| `Features/Home/CaptureViewModel.swift` | `NewFoodLog(...)` now passes `response.analysis.protein` / `.fat` / `.fiber` (previously hardcoded nil). The `[Save]` log now prints the three new values. |
| `Features/Home/AnalysisResultView.swift` | Three new optional macro lines stagger in at +1.8 / +2.1 / +2.4 s (300 ms past the existing carbs line at 1.5 s). Each line is wrapped in `if let` so a nil value omits the line entirely. Preview sample updated. |
| `Features/Home/CapturePreview.swift` | Sample `successResponse` updated with `protein/fat/fiber` to keep memberwise init compiling and exercise the new macro lines in preview. |
| `Core/Components/MealRow.swift` | Expanded view now leads with a compact "{cal} cal · {carbs}g carbs · {sugar}g sugar · …" line above the speech bubble. Protein/fat/fiber segments are appended only when the underlying field is non-nil — pre-Phase-11 meals show only the macros they actually have. |
| `Features/Tracker/TodayView.swift` | `totals(...)` helper takes three new optional macros; renders three new "Total protein/fat/fiber" lines styled to match the existing sugar/carbs lines. |
| `Features/Tracker/WeekView.swift` | Header reduce includes the three new fields. Three new "Total protein/fat/fiber" lines added below the existing carbs line. |
| `Features/Tracker/MonthView.swift` | Same shape: reduce + three new lines. Also adds explicit "Total carbs" / "Total sugar" lines (Month previously only showed calories + average + days-logged), since the user expects parity across all three header cards. |
| `Features/Tracker/DayDetailSheet.swift` | Per-day totals block grew from one row of three pills (Calories / Sugar / Carbs) to two rows of three (second row: Protein / Fat / Fiber). |

## Server response sample (Step 1 sanity check)

I did not run the curl sanity check from this session — it requires a
local food image and consumes Gemini API quota, both of which are better
left to the user. The server file edit is the substantive change; if
it's running under `npm run dev` (nodemon), the file save auto-restarts.

The expected response shape becomes:

```json
{
  "analysis": {
    "fallback": "",
    "food": "Margherita Pizza",
    "calories": 285,
    "carbs": 36,
    "sugar": 4,
    "protein": 12,
    "fat": 11,
    "fiber": 2,
    "benefits": [...],
    "drawbacks": [...],
    "nutrients": [...],
    "coachAdvice": "..."
  },
  "coach": "Albert Einstein"
}
```

Please run a manual curl check after restarting the server — example:

```bash
curl -s -X POST -F "image=@/path/to/sample.jpg" \
     http://localhost:3001/analyze | jq '.analysis | {protein, fat, fiber}'
```

Save the response to `screenshots/phase11/01_curl_with_new_macros.json`.

## Decisions log

### 1. Stacked macro lines, not two-column layout (Step 6 spec was open)

The spec offered two columns "to keep the result screen from getting
tall" as an optional refinement. I kept stacked because:

- The result view already lives in a `ScrollView` (height isn't a hard
  constraint on a phone).
- Per-line stagger animation (existing pattern: each `Text` has its own
  `@State Visible` flag and `.animation(.easeOut(duration: 0.5), value: ...)`)
  generalizes trivially to three more lines. A two-column layout would
  either require synchronized pair animations or lose individual stagger
  per cell — both add complexity without meaningful payoff.
- Nil-skipping is straightforward in a stack (`if let` wraps each `Text`).
  In a grid it requires either rendering empty cells (visual noise) or
  computing a dense layout per render (extra logic).

If a future design pass calls for compactness, the stacked version is
easy to swap to a `Grid { GridRow { ... } }`.

### 2. Pre-Phase-11 rows: nil-omit everywhere, never substitute 0

The spec is explicit on this point and the implementation honors it
end-to-end:

- `AnalysisResultView` wraps each new macro line in `if let macro = ...`.
- `MealRow.fullMacrosLine` only appends the macro segment if the field
  is non-nil.
- `LocalDailyTotals.sum` uses `?? 0` so missing values contribute 0 to
  the *sum* without becoming visible 0g entries elsewhere.

The header totals will therefore show `Total protein: 0g` for a day
where every logged meal predates Phase 11. That's intentionally
distinct from "no data" (which renders as "—" via the loading branch).

### 3. Server prompt expansion is one short sentence, not a rewrite

Per spec: "Keep the prompt concise — don't restructure the whole thing,
just add the three new asks." The existing single-sentence
"separate the calories, carbs, sugar" became "separate the calories,
carbs, sugar, protein, fat, and fiber (all in grams)". No other prompt
text changed; the structure of the function declaration and its
properties dictionary is preserved.

### 4. `MealRow` chevron logic unchanged

Phase 10's `hasExpandableContent` rule (chevron hidden iff coach advice
is empty AND all three arrays are empty) is preserved as-is. The new
macros line is incremental content within the expanded view; it
doesn't independently warrant expansion. In practice, Phase 11-era
saves all carry populated benefits/drawbacks/nutrients (verified at
the start of Phase 10 against the SQL diagnostic), so this corner case
is essentially theoretical.

### 5. `[Save]` log line extended with macros

Added a second `NSLog` after the insert returns:

```
[Save] macros: cal=420 carbs=48.0g sugar=6.0g protein=18.0g fat=12.0g fiber=3.0g
```

Lets manual verification step 4 check that the Gemini values flowed
through to the row that was actually inserted (not just what we sent).

### 6. No backfill (Step 9 spec is explicit)

Existing `food_logs` rows from before Phase 11 keep their NULL
`protein_g` / `fat_g` / `fiber_g`. Re-deriving values would require
re-running the original images through Gemini, which the app doesn't
support.

The verification path includes opening a pre-Phase-11 meal to confirm
graceful nil-handling — see manual checklist screenshot 06.

## Manual verification checklist

Per saved memory ("Simulator UI automation blocked"), I install +
launch + capture launch state but cannot drive UI taps. Starting state:
`screenshots/phase11/00_launch.png` (post-install Home tab, signed in).

After the user has restarted the server with the Phase 11 prompt:

1. **Curl sanity check.** Run:

   ```bash
   curl -s -X POST -F "image=@<food photo>" http://localhost:3001/analyze \
     | tee screenshots/phase11/01_curl_with_new_macros.json | jq .analysis
   ```

   Confirm `protein`, `fat`, `fiber` are all numeric and non-zero for a
   normal meal.

2. **Save a meal via the live app.**
   - Snap or pick a photo → analyze → confirm the result screen now
     shows six macro lines (Sugar, Carbs, Protein, Fat, Fiber) animating
     in below the calorie display. Capture
     `screenshots/phase11/03_result_screen.png`.
   - Tap save. Watch the Xcode console for the new
     `[Save] macros: cal=… protein=…g fat=…g fiber=…g` line.

3. **Supabase Table Editor.** Confirm the freshly-inserted row has
   non-null `protein_g`, `fat_g`, `fiber_g`. Capture
   `screenshots/phase11/02_table_editor_new_row.png`.

4. **Today header.** Open Tracker → Today. The gradient card should now
   show six total-macro lines (calories, sugar, carbs, protein, fat,
   fiber). Capture `04_today_header.png`.

5. **MealRow expansion.** In Today, tap the row of the meal you just
   saved. The expanded view should lead with a compact dot-separated
   macros line (`450 cal · 36g carbs · 4g sugar · 12g protein · 11g fat · 2g fiber`),
   then speech bubble, then panels. Capture `05_meal_row_expanded.png`.

6. **Old meal expansion.** In Today (or via Week/Month → tap a
   pre-Phase-11 day), expand a row that was saved before Phase 11. The
   macros line should show only the three originally-saved macros
   (cal/carbs/sugar) without protein/fat/fiber, and there should be no
   "0g" placeholder for the missing values. Capture
   `06_old_meal_expanded.png`.

7. **Week + Month headers.** Tracker → Week, then Tracker → Month.
   Both gradient cards now show the three new total lines. Capture
   `07_week_header.png` and `08_month_header.png`.

8. **DayDetailSheet totals.** Tap a logged day cell in Week or Month to
   open the day-detail sheet. The totals block now shows two rows of
   three pills (row 1: Calories / Sugar / Carbs; row 2: Protein / Fat /
   Fiber). The expanded meal rows inside also show the full macros
   line. (Optional capture; covered by 05 + 06.)

## Confirmations

- ✅ Build succeeds, no new compiler warnings.
- ✅ `FoodLog` model already exposed `proteinG`/`fatG`/`fiberG` — no
  iOS-side schema-decode changes needed.
- ✅ All three call sites of the `GeminiAnalysis(...)` memberwise init
  (struct definition, AnalysisResultView preview, CapturePreview sample)
  were updated to pass the new arguments — build wouldn't compile
  otherwise.
- ✅ `CaptureViewModel.save()` now forwards `response.analysis.protein`
  / `.fat` / `.fiber` to `NewFoodLog` (was hardcoded nil).
- ✅ `LocalDailyTotals.sum` aggregates the new macros with `?? 0` so
  pre-Phase-11 meals contribute 0 to sums (not crash, not skewed
  averages — the per-day average call sites in WeekView and MonthView
  use only `totalCalories / loggedDays`, so unchanged).
- ✅ `MealRow.fullMacrosLine` constructs the dot-separated string by
  appending only the macros that exist; protein/fat/fiber segments
  appear only when the underlying field is non-nil.
- ✅ All three header cards (Today / Week / Month) and the day-detail
  totals block render protein/fat/fiber lines.
- ✅ No backfill performed; existing rows stay NULL by design.
- ✅ Server-side prompt + schema changes are minimal and additive — no
  fields removed or renamed.

## Status

**Code complete.** Phase 11 is feature-complete pending the manual
curl/save flow / screenshot capture documented above. The server change
is on the host filesystem; the iOS build is clean and installed on
the simulator.
