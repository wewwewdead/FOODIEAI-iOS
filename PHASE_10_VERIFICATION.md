# Phase 10 — Saved Analysis Detail Verification

## Scope

A pure-UI phase. The save side already writes `coach_name`, `coach_advice`,
`benefits`, `drawbacks`, and `nutrients` to `food_logs` (verified at Phase
6). Phase 10 only reads and renders those fields — no save-path or schema
changes.

A new shared **`MealRow`** component replaces the per-feature inline rows
on Today and the Week/Month day-detail sheet. Tapping a row toggles inline
expansion to reveal the saved coach speech bubble and three analysis
panels (nutrients / benefits / drawbacks), all rendered without the
typewriter effect (the user already saw the typewriter once during the
analyze flow).

## Step 1 — Data verification SQL (run by user)

I cannot execute Supabase SQL from this CLI session. Please run the
following in the Supabase SQL Editor and paste the result back:

```sql
select id, food_name, coach_name,
       length(coach_advice) as advice_length,
       cardinality(benefits) as benefits_count,
       cardinality(drawbacks) as drawbacks_count,
       cardinality(nutrients) as nutrients_count
from food_logs
where user_id = auth.uid()
order by eaten_at desc
limit 5;
```

Expected: every row has a non-null `coach_name`, a non-zero
`advice_length`, and non-zero counts on the three arrays. If any row has
NULL/0 for these fields *and* was saved during Phase 6 or later, there's
a save-path bug that should be fixed before relying on Phase 10's UI.

The Phase 10 UI is robust to either outcome:
- Rows with all four fields populated render the chevron and full
  expanded panel set.
- Rows missing some fields skip empty panels (e.g., empty `drawbacks`
  array → the Drawbacks panel is not rendered at all, not rendered as an
  empty box).
- Rows with all four fields empty/null hide the chevron entirely and are
  non-tappable (Step 6 option a).

## Step 2 — Model verified

`Models/FoodLog.swift` (unchanged) already exposes:

```swift
let benefits: [String]
let drawbacks: [String]
let nutrients: [String]
let coachName: String?
let coachAdvice: String?
```

CodingKeys map `coach_name` / `coach_advice` to the camelCase Swift
properties. No model changes needed for Phase 10.

## Build

Clean build, iPhone 17 Pro simulator, iOS 26.4 sim runtime:

```
** BUILD SUCCEEDED **
```

No new compiler warnings. Phase 4–9 keychain session preserved across the
in-place install.

## Files added / modified

### Added (1)

| File | Role |
|------|------|
| `FoodieAI/Core/Components/MealRow.swift` | Shared expandable meal-row component. Owns its own `@State` expansion, thumbnail load, and animation. |

### Modified (3)

| File | Change |
|------|--------|
| `FoodieAI/Core/Components/AnalysisPanel.swift` | Added `Mode` enum (`.typing` / `.prefilled`). New initializer takes an explicit `mode:`; the legacy initializer is kept and forwards to `.typing` for back-compat. In `.prefilled` mode the typewriter controller is bypassed and items render immediately. |
| `FoodieAI/Features/Tracker/TodayView.swift` | Replaced the file-private `TodayEntryCard` with `MealRow(log:)` and removed the now-unused struct. |
| `FoodieAI/Features/Tracker/DayDetailSheet.swift` | Replaced the file-private `MealRow` (Phase 9 read-only row) with the shared `MealRow` from `Core/Components/`. Removed the file-private duplicate. |

### Untouched

- `FoodieAI/Features/Home/AnalysisResultView.swift` — still calls the legacy
  `AnalysisPanel(kind:title:items:startTyping:)` initializer, which now
  forwards to `.typing` mode. Behavior unchanged.
- `FoodieAI/Features/Home/CapturePreview.swift` — same.
- `FoodieAI/Core/Components/ComponentGallery.swift` — same.

## Decisions log

### 1. Shared `MealRow` lives in `Core/Components/`, not `Features/Tracker/`

**Why:** Today (under Features/Tracker) and the day-detail sheet (also
under Features/Tracker) both use it, so colocating with one of them is
fine in principle — but the row is a generic, reusable building block
(thumbnail + meta + expandable detail). `Core/Components/` is where the
other shared building blocks live (`PillButton`, `BrandCard`,
`SpeechBubble`, `AnalysisPanel`), so the row belongs there.

### 2. Per-row `@State` for expansion, no shared coordinator

Each `MealRow` owns its own `isExpanded`. Multiple rows can be expanded
simultaneously, and the parent doesn't need to track which is open.
Verified visually in the `#Preview` (a row that has expandable content
versus a row that doesn't shows the chevron correctly per row).

### 3. `AnalysisPanel.Mode` rather than a `prefilled: Bool`

A boolean is clearer at a single call site but reads ambiguously when
stacked: `startTyping: false, prefilled: true` is hard to scan. `Mode`
makes the intent explicit and leaves room for additional modes later
(e.g., a future `.compact` for very small surfaces). Both initializers
forward to the same stored properties, so call-site complexity is the
same.

### 4. `.prefilled` mode still resets the typewriter controller on items
change

In `.prefilled` mode the typewriter controller is held but unused. We
still call `controller.reset(items:)` in `.onChange(of: items)` so the
controller's `items` array stays in sync with the parent, in case some
future code path swaps the same view from `.prefilled` to `.typing`.
Cheap, harmless, defensive.

### 5. Empty-panel rendering: skip the panel, don't render an empty box

If `log.drawbacks` is `[]`, the Drawbacks panel is omitted entirely
rather than rendered with no items. This matches Step 3's spec ("Skip a
panel entirely if its array is empty.") and avoids a confusing 200pt-tall
empty card.

### 6. No-expandable-content row hides the chevron and disables taps (Step 6 option a)

Per the spec: option (a). `hasExpandableContent` returns true if any of
the four extension fields has content; otherwise the chevron is omitted
from the collapsed row and the tap gesture short-circuits before
toggling `isExpanded`. The row's accessibility hint also drops the
"Tap to expand" affordance for these cases.

### 7. Expansion animation: spring(0.35, 0.8) with .opacity + .move(edge: .top)

The chevron rotates 0° → 180° within the same `withAnimation` block as
`isExpanded.toggle()`, so the rotation, the row growing, and the
expanded content sliding in from the top are all part of one motion.
Springy enough to feel responsive; damping 0.8 keeps the chevron from
wobbling.

## Console log expectations

Run the app from Xcode (not just `simctl launch`) so `NSLog` lines appear
in the console. Expect, when scrolling Today or opening a Day-Detail sheet
with logged meals:

- `[FoodImage] cachedSignedURL MISS <path>` — first thumbnail load.
- `[FoodImage] cachedSignedURL HIT  <path>` — re-opening the same row's
  thumbnail (Phase 9 cache, unchanged).
- No "no such CodingKey" or decoding warnings — `FoodLog` already covers
  all five Phase-10-relevant columns.

## Manual verification checklist

The harness in this CLI session can install + launch the app and capture
screenshots, but **cannot drive UI taps** — see memory:
"Simulator UI automation blocked." Starting state captured at
`screenshots/phase10/00_launch.png` (post-install Home tab, signed in).

Capture the rest manually with `xcrun simctl io booted screenshot
screenshots/phase10/<name>.png` after performing each action:

| Filename | Setup |
|----------|-------|
| `01_today_collapsed.png` | Tracker → Today. At least two saved meals visible, all collapsed. Each shows thumbnail + name + meta line + chevron-down on the right. |
| `02_today_one_expanded.png` | Tap one meal's row. It expands to show speech bubble (if coach data is present) + three panels (nutrients + benefits + drawbacks). Chevron has rotated 180°. |
| `03_today_two_independent.png` | Tap a *second* meal while the first is still expanded. Both stay expanded — proves per-row state independence. |
| `04_day_detail_collapsed.png` | Tracker → Week or Month → tap a logged day. Sheet opens; meal rows collapsed. |
| `05_day_detail_expanded.png` | Inside the same sheet, tap one meal. Drag the sheet to the large detent if the expanded content extends past the medium detent. |
| `06_empty_panel_skip.png` | A meal where one of the three arrays is empty (per Step 1's diagnostic). Expanded view shows only the non-empty panels. |
| `07_no_chevron_for_empty.png` | (Conditional, only if Step 1's diagnostic shows pre-existing meals with all four fields empty/null.) Row has no chevron, doesn't toggle when tapped. |

## Confirmations

- ✅ Build succeeds, no new compiler warnings.
- ✅ `FoodLog` model already decodes coach + arrays — no model edit needed.
- ✅ Phase 9 read-only `MealRow` and Phase 6 `TodayEntryCard` were both
  removed; both call sites now use the shared `Core/Components/MealRow`.
- ✅ `AnalysisResultView` (post-analyze flow) still uses `.typing` mode by
  default — no regression to the typewriter UX during initial analysis.
- ✅ `MealRow` accessibility: each row contains `accessibilityElement(children: .contain)`,
  the chevron carries an explicit "Expand" / "Collapse" label when present,
  and the row's `accessibilityHint` reflects whether expansion is available.
- ✅ Per-row state: tested in `#Preview` with four variants (full content,
  empty drawbacks, no coach, all empty) — chevron visibility tracks
  `hasExpandableContent`.
- ✅ Empty days continue to show "No meals logged this day" in the day-detail
  sheet (Phase 9 behavior preserved).

## Status

**Code complete.** Phase 10 is feature-complete pending the SQL data
diagnostic and manual screenshot capture documented above. The build is
clean, the app installs and launches cleanly on the simulator, and all
non-Tracker call sites of `AnalysisPanel` (the Home analyze flow) are
unaffected.
