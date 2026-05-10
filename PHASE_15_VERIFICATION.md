# Phase 15 — Food Memory & Repeat Detection — Verification

## Build status

`xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI -destination
'generic/platform=iOS Simulator' -configuration Debug build` → **succeeds**.
Only the pre-existing "Traditional headermap style" project-level warning
remains (carried over from prior phases, unrelated to Phase 15).

## Files added

| Path | Purpose |
| --- | --- |
| `migrations/004_food_log_origin.sql` | Adds `origin`, `source_log_id`, and `food_logs_user_food_name_idx`. **Note: numbered 004**, not 003 as the brief proposed — `003_profiles_macro_goals.sql` already shipped earlier. |
| `FoodieAI/Services/MealHistoryService.swift` | `priorOccurrences`, `recentUniqueMeals`, `patternsForToday` + the pure `analyzePatterns(logs:now:calendar:)` and `Pattern` value type. Single entry point for all "food memory" reads. |
| `FoodieAI/Features/Home/RecentMealsSheet.swift` | Quick Re-log picker. Owns its own `RecentMealsViewModel`. |

## Files modified

| Path | Why |
| --- | --- |
| `FoodieAI/Models/FoodLog.swift` | Added `origin` enum + `sourceLogId` to both `FoodLog` and `NewFoodLog`. `NewFoodLog` gets an explicit init defaulting to `.analyzed` / `nil` so the existing `CaptureViewModel.save` path is untouched. |
| `FoodieAI/Features/Home/CaptureViewModel.swift` | New `relog(_:)` method, `relogToast` published state + `RelogToast` value type, `clearRelogToast()`. |
| `FoodieAI/Features/Home/CaptureView.swift` | "Or pick from your recent meals →" affordance on the idle Capture screen, sheet wiring, and a 1.6s in-flow `RelogToastView`. |
| `FoodieAI/Features/Home/AnalysisResultView.swift` | Repeat-detection `.task` + `repeatChip` rendered under the food name. Shows nothing when `priorCount` is 0 or `nil`. Failures are silent. |
| `FoodieAI/Features/Tracker/TrackerViewModel.swift` | Holds a `MealHistoryService`, publishes `patterns: [Pattern]`. `refresh()` now runs `todaysLogs` and `patternsForToday` in parallel via `async let`. Pattern failures are soft (try?) and never break the tracker refresh. |
| `FoodieAI/Features/Tracker/TodayView.swift` | New `patternsSection` rendered between macro bars and the meal list. `PatternCard` private subview. Section is hidden entirely when `patterns.isEmpty`. |
| Preview FoodLog inits in `MealCard.swift`, `MealRow.swift`, `ExpandableMealCard.swift`, `ComponentGallery.swift`, `DayDetailSheet.swift` | Added `origin: .analyzed, sourceLogId: nil` to keep the synthesized memberwise `FoodLog(...)` calls compiling. |

## Decisions log

### Migration numbering: 004 not 003
The brief specified `003_food_log_origin.sql` but `003_profiles_macro_goals.sql`
was already in the repo from an earlier phase. Using 004 preserves
ordered application; nothing else in the brief depended on the literal
number.

### Case sensitivity — fixed (post-review)

Initial implementation had a split: `priorOccurrences` used `.eq` on
`food_name` (Postgres case-sensitive) while `recentUniqueMeals` and
`patternsForToday` deduped on `foodName.lowercased()` (case-insensitive).
On the same screen, "Margherita Pizza" + "margherita pizza" would show
as 2 in the patterns card but 1 in the result-screen chip.

Fix: switched `priorOccurrences` to `.ilike("food_name", pattern: …)`
with `%`/`_`/`\` escaped via `escapeLikePattern(_:)` so the value is
treated as a literal (no wildcards leak through). All three surfaces
now agree on case-insensitive identity.

Future hardening: a generated `food_name_lower` column or a `citext`
migration would let `priorOccurrences` use a btree-indexed `.eq`
instead of `.ilike` for marginal speedup at user-data scale, but
isn't justified at v1 row counts.

### `NewFoodLog.origin` is sent explicitly
The DB has `default 'analyzed'`, so I could have omitted `origin` from
the insert and let the default fill it in. Instead I made `NewFoodLog`
require it (with a Swift default of `.analyzed`) so intent is visible
at every call site. The Quick Re-log path passes `.relogged` + a non-nil
`sourceLogId`; the analyze path takes the default. Easier to grep,
harder to accidentally forget when adding a new insert path.

### Image objects are NOT re-uploaded on re-log
`relog(_:)` copies the `image_path` and `image_thumb_path` from the
source row directly. Both rows are owned by the same authenticated user
(RLS guarantees the source row is visible only to its owner, which is
also the inserter), so the shared Storage object reference is safe.
This is the load-bearing reason re-logs are fast.

### Toast vs. sheet for re-log confirmation
The brief said re-log confirmation should feel "lighter than save success
— frequency action, not a moment." Reusing `SavedConfirmationSheet`
(centered modal with confetti) would have undercut that. Built a
dedicated `RelogToastView` — pill at the bottom, hairline border,
auto-fades 1.6s, separate `.success` haptic. Failure variant uses the
same shape with `Color.error` icon so layout doesn't reflow.

### `relogToast` lives on `CaptureViewModel`, not the State enum
The user can fire several re-logs in a row from the picker without
touching the photo flow. Adding `.relogging`/`.relogged` cases to the
existing `State` would have collided with the photo-driven state graph
(`.idle → .picked → .analyzing → …`). A separate published toast
property keeps both lifecycles independent.

### Patterns analysis is a pure function on `[FoodLog]`
`MealHistoryService.analyzePatterns(logs:now:calendar:)` is `static`
and side-effect-free. The async `patternsForToday()` only does the
fetch; analysis is callable from a unit test (or from a future
server-side replacement) without instantiating the actor.

### Edge cases for `analyzePatterns`
- **Empty logs**: returns `[]` immediately.
- **Single occurrence**: doesn't trigger frequent (needs 3+); may
  trigger first-this-week if it falls in the last 7 days.
- **Exactly 3 occurrences, all different weekdays**: surfaces frequent
  with `detail = nil` (no weekday cluster reached the 3-on-same-day
  threshold).
- **3 occurrences clustering on one weekday**: appends "Mostly Mondays."
- **Frequent food also "new this week"**: only the frequent pattern is
  emitted — we filter the firstThisWeek candidate against the already-
  emitted frequent id so the same food never appears twice in different
  framings.
- **More than 2 patterns viable**: cap at 2, frequent wins the first
  slot.

### Repeat-detection chip rendering rules
- `priorCount == nil` (query in flight or failed): chip hidden.
- `priorCount == 0`: chip hidden. Novelty messaging is the Today →
  Patterns section's job, not this view's.
- `priorCount >= 1`: chip shown with conversational date label —
  "today" / "yesterday" / weekday name within last week / "MMM d"
  beyond that.

### TodayView refresh continues even when patterns query fails
`async let patternsTask: [Pattern]? = try? history.patternsForToday()`.
If the patterns query throws, the result is `nil` → resolved to `[]` →
section hides. The today's-logs query runs independently and produces
the user-visible state. Either query failing alone never blocks the
other.

## Manual verification (to run with the live Express server + Supabase)

These steps require a signed-in session and are documented for the
user to walk through manually; auto-mode cannot reach the simulator UI
from this CLI (per `feedback_simulator_automation` memory).

1. **Migration apply** — paste `migrations/004_food_log_origin.sql`
   into the Supabase SQL Editor. Run. Verify Table Editor shows
   `origin = 'analyzed'` populated for all pre-Phase-15 rows.
2. **Repeat detection** — analyze a food whose name matches an
   existing row's `food_name` exactly. Result screen renders the
   "You've had this N times. Last time: …" chip below the food name.
   Capture `screenshots/phase-15/01_repeat_detection.png`.
3. **Quick Re-log empty state** — sign in as a brand-new user, tap
   "Or pick from your recent meals →" on the Capture screen. Sheet
   shows "No saved meals yet". Capture `02_relog_empty.png`.
4. **Quick Re-log picker** — same affordance with prior saves. Sheet
   lists deduplicated recent meals. Tap one. Toast appears at the
   bottom, fades in 1.6s. Capture `03_relog_picker.png` and
   `04_relog_toast.png`.
5. **Re-log row in DB** — Supabase Table Editor: new row has
   `origin = 'relogged'` and `source_log_id` pointing at the source
   row's id. The `image_path` matches the source's. Capture
   `05_relog_table_editor.png`.
6. **Patterns surfacing** — re-log the same meal until 3 instances in
   the last 14 days, then refresh Today. PATTERNS section appears
   between macros and meal list with "You've had {name} 3 times in
   the last two weeks." Capture `06_patterns.png`.
7. **No-pattern state** — temporarily push all eaten_at older than
   14 days; refresh Today. Section is hidden entirely (not "no
   patterns yet"). Don't forget to revert.
8. **RLS sanity** — in SQL Editor as `postgres`:
   ```sql
   select user_id, food_name, count(*) from food_logs
   group by user_id, food_name having count(*) >= 3;
   ```
   Confirm the surfaced count matches what the app showed for your
   user, and another test user's rows aren't visible to your user via
   the picker / patterns / repeat-detection queries.

## Phase 16 readiness

The brief asked me to confirm `MealHistoryService`'s API is general
enough for Phase 16's coach continuity needs. The service surface today is:

- `priorOccurrences(of:excluding:)` — already returns full `[FoodLog]`,
  not just a count, so the coach can read past calorie/macro/coachAdvice
  values to thread continuity into a new analysis prompt.
- `recentUniqueMeals(limit:)` — useful as "what has this user been
  eating lately" context for the coach prompt.
- `patternsForToday()` — already returns the `Pattern` value type, which
  the coach can read to ground references like "you've had pizza three
  times this week" without re-running its own analysis.

Nothing in this surface is screen-specific; all three methods are pure
data accessors that can be called from anywhere. Phase 16 should not
need to reach back into `FoodLogService` for memory queries.

## Live-loop regressions confirmed unaffected

Verified by inspection (no behavior change in the touched code paths):

- **Save flow**: `CaptureViewModel.save()` still uses the same
  `NewFoodLog` shape; `origin` defaults to `.analyzed` and
  `sourceLogId` to `nil`, so the inserted row matches the
  pre-Phase-15 shape modulo the two new columns.
- **Image upload**: untouched — `FoodImageService.uploadMealImages` is
  not called on the re-log path (we reuse the source's paths), and the
  analyze-then-save path still calls it as before.
- **RLS**: untouched. No policy changes in 004.
- **Today refresh**: switched from a single fetch to two parallel
  fetches with the patterns one wrapped in `try?` — the logs path is
  unchanged.
- **Meal expansion** in `ExpandableMealCard`: only the preview-helper
  `FoodLog(...)` call required updating; production code reads
  `FoodLog` from the network and decodes the new fields automatically.
