# Phase 9 — History Views (Week + Month) Verification

## Scope

Adds a segmented control to the Tracker tab with three views:

- **Today** — Phase 6 behavior, unchanged.
- **Week** — bar chart of daily calories for the current week (SwiftUI Charts).
- **Month** — calendar grid for the displayed month, prev/next chevrons,
  logged days tinted brand, today's cell outlined, future days disabled.

Tapping a Week day-cell or a Month calendar cell opens a shared
**DayDetailSheet** with that day's totals and a chronological meal list
(thumbnail + food name + time/macros). Empty days show a static
"No meals logged this day" empty state. Drill-down into a single meal's
full analysis is out of scope.

## Build

Clean build, iPhone 17 Pro simulator, iOS 26.4 sim runtime, iOS 17
deployment target:

```
** BUILD SUCCEEDED **
```

No new compiler warnings. The Phase 4–8 keychain session for
`johnmathewloren27@gmail.com` was preserved by reusing `simctl install`
in place over the existing app bundle.

## Files added / modified

### Added (8)

| File | Role |
|------|------|
| `FoodieAI/Features/Tracker/TrackerSegment.swift` | Segment enum (Today / Week / Month). |
| `FoodieAI/Features/Tracker/TodayView.swift` | Extracted Today UI from the old TrackerView, verbatim — no behavioral change. |
| `FoodieAI/Features/Tracker/WeekViewModel.swift` | Loads logs for the current week, buckets into 7 daily slots. |
| `FoodieAI/Features/Tracker/WeekView.swift` | Header card + bar chart + tappable day-cell row. |
| `FoodieAI/Features/Tracker/MonthViewModel.swift` | Loads logs for displayed month, prev/next-month nav (next gated to current month). |
| `FoodieAI/Features/Tracker/MonthView.swift` | Header card with chevrons + 7-column calendar grid. |
| `FoodieAI/Features/Tracker/DayDetailSheet.swift` | Reusable sheet shown by Week and Month with meal rows + thumbnails. |
| `screenshots/phase9/` | (directory for screenshots) |

### Modified (3)

| File | Change |
|------|--------|
| `FoodieAI/Models/DailyTotals.swift` | Added `DailyBucket` struct + `DailyBucketing.bucket(_:from:to:calendar:)` helper, and `LocalDailyTotals.from(_:)` alias. |
| `FoodieAI/Services/FoodLogService.swift` | Added `logs(from:to:)` half-open date-range query. |
| `FoodieAI/Services/FoodImageService.swift` | Added `cachedSignedURL(for:)` with per-actor 60-min cache + 60-second buffer. |
| `FoodieAI/Features/Tracker/TrackerView.swift` | Rewrote as host: segmented `Picker` + `switch` on segment, owns three view models. |

The previously-existing `TrackerFailedSample.swift` is unchanged. The
existing `TrackerViewModel.swift` is unchanged — `TodayView` consumes
it as before.

## Decisions log

### 1. Tap target for Week chart bars: row of buttons below the chart, not in-chart taps

**Spec said:** chartOverlay + DragGesture mapping screen X → date via
`proxy.value(atX:)`, with a fallback row of buttons noted as acceptable.

**Chose:** the fallback. A `HStack` of 7 small day cells sits directly
below the chart, each containing the weekday letter, day number, a
small brand dot if the day has logs, and a brand-tint background if
the day is today. Each cell is a `Button` that sets
`@State selectedBucket` and triggers the `.sheet(item:)`.

**Why:** chartOverlay's `proxy.plotFrame` and `proxy.value(atX:)`
APIs have shifted across iOS 17 minor SDK revisions and across
Xcode-bundled Charts versions. A row of explicit `Button`s is:
- discoverable (visible tap targets, not invisible overlay regions);
- accessible by default (each cell carries its own `accessibilityLabel`
  with date + calorie summary or "no meals logged");
- platform-agnostic across Charts revisions;
- doubles as the X-axis label row, so we hide the chart's own X axis
  via `.chartXAxis(.hidden)` to avoid duplication.

### 2. Signed-URL cache TTL: 60 minutes with a 60-second freshness buffer

**Spec said:** "1 hour" cache; "60-second buffer prevents handing out a
URL that's about to expire while the image is loading."

**Chose:** exactly that. `signedURLTTL = 60 * 60`, `signedURLBuffer = 60`.
Per-actor dictionary keyed by storage path. Cache lives for the process
(no on-disk persistence — per-launch rebuild is fine).

### 3. No shared save-event publisher across segments

**Spec said:** could be a shared `EnvironmentObject` save-token, OR
"refresh all three when the Tracker tab appears" — pick the simpler.

**Chose:** simpler. Each segment has its own `.task` that triggers
`refresh()` on segment selection. When the user saves a new meal and
switches back to Tracker, every segment re-fetches the next time it's
shown. This matches the existing v1 sync model documented in
`TrackerViewModel.swift` (Phase 6 decision).

The trade-off: a brief flicker on segment switch and one round-trip
per switch. Justified because save→tracker is the only mutation path,
query latency is low, and the alternative requires plumbing an
`@EnvironmentObject` through the auth-routed view tree.

### 4. Month calendar: future days are visible but disabled, not hidden

A future day in the displayed month renders with `Color.brandIvory`
at half opacity, day-number text in `textMeta @ 50%`, and the `Button`
is `.disabled(true)`. The next-month chevron is gated by
`viewModel.isCurrentMonth`, so future days only ever appear in the
*current* month (after today's date).

**Why:** the gate on the chevron is the primary defense; the disabled
cell is defense in depth, and visually marking the days that haven't
happened yet matches what users expect from a calendar.

### 5. Meal-count badge on Month cells: subtle dot/number in bottom-right

`bucket.logs.count` is rendered in `meta` (12pt Nunito-Bold) at
`Color.greenAnalysis @ 60%`, bottom-right corner of the cell. Easy to
ignore on a glance; informative on a closer look.

### 6. DayDetailSheet rows: no chevron, non-tappable

Phase 9 explicitly drops drill-down to single-meal full analysis. To
make the row read as static info rather than a broken affordance,
we omit the trailing chevron entirely — the row reads as a record,
not a navigation target.

### 7. Empty days are tappable

Tapping a day with zero logs opens the sheet showing the empty state
(`fork.knife.circle` icon at `brand @ 30%` + "No meals logged this
day"). A no-op tap on those cells would be confusing; an explicit
"no, really, nothing here" dialog is more discoverable.

## Console log evidence

Recommended verification: run the app from Xcode (not just `simctl
launch`) so `NSLog` lines appear in the console. With Phase 9, expect:

- `[Tracker] todaysLogs returned N entries (tz=…)` — Today segment.
- `[Week] logs returned N entries for May 4 – May 10` — Week segment.
- `[Month] logs returned N entries for May 2026` — Month segment.
- `[FoodImage] cachedSignedURL MISS <path>` — first thumbnail load.
- `[FoodImage] cachedSignedURL HIT  <path>` — re-opening the same day.

## Manual verification checklist (screenshots)

The harness in this CLI session can install + launch the app and
capture screenshots, but **cannot drive UI automation** (taps/gestures
to the simulator are blocked from this environment — see memory:
"Simulator UI automation blocked"). The remaining screenshots below
must be captured on the simulator manually.

The starting state is captured: `screenshots/phase9/00_launch.png`
(post-install Home tab, signed in).

To complete the verification:

1. **Seed data.** Save 3–4 meals through the live app *today*. Then in
   the Supabase SQL Editor, backdate some so we have meals on
   different days — e.g.:
   ```sql
   update public.food_logs
     set eaten_at = (now() at time zone 'UTC') - interval '2 days'
     where id = '...';
   update public.food_logs
     set eaten_at = (now() at time zone 'UTC') - interval '5 days'
     where id = '...';
   update public.food_logs
     set eaten_at = (now() at time zone 'UTC') - interval '12 days'
     where id = '...';
   ```
   Use real `image_path` values (i.e., backdate existing rows rather
   than insert blank rows) so DayDetailSheet thumbnails resolve.

2. **Capture seven screenshots** with `xcrun simctl io booted screenshot`
   into `screenshots/phase9/`:

   | Filename | What to do before capturing |
   |----------|------------------------------|
   | `01_segmented_today.png` | Open Tracker tab — Today segment selected (default). Confirm Phase 6 layout is unchanged. |
   | `02_week_view.png` | Tap **Week** segment. Wait for bars to render. |
   | `03_week_day_detail.png` | Tap a day cell with a bar. Sheet opens with thumbnails + meal rows. |
   | `04_month_view.png` | Dismiss sheet. Tap **Month** segment. At least 2 days should be brand-tinted; today should be outlined. |
   | `05_month_empty_day.png` | Tap a day with no logs. Sheet shows "No meals logged this day". |
   | `06_month_logged_day.png` | Dismiss. Tap a brand-tinted day. Sheet shows totals + meal rows with thumbnails. |
   | `07_month_navigation.png` | Dismiss. Tap the left chevron. Header should show the previous month. |

3. **Verify thumbnails load.** From an Xcode session, scan the console
   for `[FoodImage] cachedSignedURL MISS …` followed by `HIT` on
   subsequent opens of the same day. No 403s.

4. **Confirm Today regression-free.** With Phase 9 installed, the Today
   segment should look identical to the Phase 8 Tracker (compare
   `screenshots/phase8/06_*.png` to the new `01_segmented_today.png`).

## Confirmations

- ✅ Build succeeds with no new warnings.
- ✅ Today view body (gradient header, totals, BouncingBadge reminder,
  meal cards with timestamp + macros) is moved into `TodayView.swift`
  verbatim — no logic changes. `TrackerView` now hosts the segmented
  picker and switches on `TrackerSegment`.
- ✅ `TrackerViewModel` (the existing today VM) is untouched.
- ✅ `FoodLogService.logs(from:to:)` reuses the existing `gte/lt`
  pattern with ISO8601 fractional seconds — same as `todaysLogs`.
- ✅ `FoodImageService.cachedSignedURL` is actor-isolated (no Sendable
  warnings) and falls back to the existing `signedUrl(for:expiresIn:)`
  on cache miss.
- ✅ No `user_id` is sent on any client-side insert. (`grep -n user_id`
  on Phase 9 files only matches the read-side `DailyTotals` mirror.)
- ✅ Future-month browsing is blocked: `MonthViewModel.isCurrentMonth`
  gates `goToNextMonth()` and disables the chevron.
- ✅ Empty days (Week and Month) open the sheet's empty state rather
  than a no-op.
- ✅ DayDetailSheet rows have no drill-down affordance (Phase 9 scope).
- ✅ Charts framework is the only new dependency, and it's a system
  framework (no third-party additions).

## Status

**Code complete.** Phase 9 is feature-complete pending the manual
screenshot capture documented above. The build is clean, the app
installs and launches cleanly on the simulator, and Today behavior is
preserved.
