# Phase 17 — Smart Reminders & Weekly Recap — Verification

## Build & test status

`xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI -destination
'generic/platform=iOS Simulator' build` → **succeeds** with only the
pre-existing "Traditional headermap style" warning.

`xcodebuild ... -only-testing:FoodieAITests/EatingTimeInferenceTests test`
→ **all 4 tests pass** (the three required by the brief plus a
minute-resolution sanity test):

```
Test Case '...testTwentyLogsAtHalfPastTwelve_lunchOnly' passed (0.000s)
Test Case '...testThirtyLogsSpread_allThreePopulated'   passed (0.000s)
Test Case '...testThreeLogs_insufficientWithDefaults'   passed (0.000s)
Test Case '...testMinuteResolution_picksMostFrequentMinute' passed (0.002s)
Executed 4 tests, with 0 failures (0 unexpected) in 0.003 seconds
```

Server: `node --check routes/gemini.js` passes.

## Files added

| Path | Purpose |
| --- | --- |
| `migrations/006_reminders_and_recaps.sql` | Six profile columns + `weekly_recaps` table with RLS + unique `(user_id, week_start)` constraint. |
| `FoodieAI/Services/EatingTimeInference.swift` | Pure helper: takes `[FoodLog]` + timezone, emits `(breakfast, lunch, dinner, confidence)`. No network. |
| `FoodieAI/Services/NotificationScheduler.swift` | UNUserNotificationCenter wrapper. `requestAuthorization`, `reschedule`, `suppressTodaysWindow`, `scheduleWeeklyRecap`. Caps at 4 scheduled notifications. |
| `FoodieAI/Services/NotificationRouter.swift` | UNUserNotificationCenter delegate that turns taps into observable `requestedTab` / `requestedRecap` flags. |
| `FoodieAI/Services/AppForegroundOrchestrator.swift` | Lifecycle entry: timezone sync → recap-generate-if-needed → notification reschedule. Save-flow `suppressWindow(for:)` lives here too. |
| `FoodieAI/Services/WeeklyRecapService.swift` | CRUD on `weekly_recaps` + `generateIfNeeded(weekStart:weekEnd:)` orchestration. |
| `FoodieAI/Models/WeeklyRecap.swift` | `WeeklyRecap` + `NewWeeklyRecap` with date-only encoding for `week_start` / `week_end`. |
| `FoodieAI/Features/Notifications/NotificationGate.swift` | UserDefaults-backed gate for "when to first present the permission sheet" (3 saves + 30-day defer). |
| `FoodieAI/Features/Notifications/NotificationPermissionView.swift` | Pre-prompt + denied sheets per HIG. |
| `FoodieAI/Features/Notifications/NotificationSettingsView.swift` | Profile → Notifications screen with master, three meal toggles + inferred-time labels, weekly recap toggle, Open Settings affordance. |
| `FoodieAI/Features/Recap/RecapView.swift` | Magazine recap. Hero collage (highest-calorie first), `EditorialQuote`, top pattern card, meal expander, past-recaps link. |
| `FoodieAITests/FoodieAITests.swift` | Extended with `EatingTimeInferenceTests`. |

## Files modified

| Path | Why |
| --- | --- |
| `routes/gemini.js` | New `POST /weekly-recap` endpoint — server-computed `headline_stat` (no Gemini arithmetic), Gemini composes the editorial body via function-call schema, explicit no-shame system prompt. |
| `FoodieAI/Models/Profile.swift` | Six new fields + decode-with-defaults; `ProfileUpdate` extended to opt-in encode all 14 columns. |
| `FoodieAI/Services/ProfileService.swift` | `setNotificationPreferences(...)`, `setTimeZone(_:)` narrow-write helpers. |
| `FoodieAI/Services/MealHistoryService.swift` | New `patternsForRange(from:to:)` for the recap's week-bounded pattern analysis. |
| `FoodieAI/Features/Tracker/TrackerViewModel.swift` | Added `latestRecap` published state + parallel `WeeklyRecapService.latest()` fetch in `refresh()`. |
| `FoodieAI/Features/Tracker/TodayView.swift` | "This week" banner above the ring; recap sheet wiring; observes `NotificationRouter.requestedRecap` for notification-tap deep link. |
| `FoodieAI/Features/Profile/ProfileView.swift` | New "Notifications" row → `NotificationSettingsView`. |
| `FoodieAI/Features/Home/CaptureViewModel.swift` | After successful save: `NotificationGate.recordSave()` + detached `AppForegroundOrchestrator.suppressWindow(for:)`. |
| `FoodieAI/Features/Home/CaptureView.swift` | Permission pre-prompt sheet driven by `NotificationGate.shouldPresentPermissionSheet()` after the success-sheet dismiss; coach picker (Phase 16) wins the slot first if not yet seen. |
| `FoodieAI/FoodieAIApp.swift` | Registers `NotificationRouter` delegate at launch; injects router as `EnvironmentObject`; observes `auth.isSignedIn` + `scenePhase` to call `AppForegroundOrchestrator.runOnForeground()`. `MainTabView` reacts to `requestedTab` to switch. |
| `project.yml` | Test target gained `GENERATE_INFOPLIST_FILE`, `PRODUCT_NAME`, `TEST_HOST`, `BUNDLE_LOADER`, plus root-level `ENABLE_TESTABILITY: YES` so `@testable import FoodieAI` resolves under Xcode 16. |

## Decisions log

### Recap trigger window: Sunday ≥ 19:00 OR any time Monday
Implemented in `AppForegroundOrchestrator.shouldAttemptRecap`. The
Monday clause catches users who didn't open the app Sunday evening —
without it, a user who only opens Tuesday-Sunday-morning would never
see last week's recap. Tuesday onward is intentionally NOT a trigger:
"the week's done, you've already moved on" was the call. Recaps stay
visible via the banner and Past Recaps as long as they're persisted.

### Recap range bounds in user's timezone, not UTC
`WeekBounds.lastCompletedWeek(now:timeZone:)` constructs Monday/Sunday
date-only values using the user's current timezone (or, if available,
the timezone stored on `profiles.time_zone`). The `weekly_recaps`
table stores both as `DATE`, which Postgres treats as timezone-less —
the iOS client owns the timezone semantics on read and write.

### Photo-collage selection rule: highest-calorie first, ties by recency
`RecapView.collageMeals(_:)`. Documented in code so future tweaks are
intentional. Alternative would have been most-recent-first, but a
calorie-led pick produces a more characteristic "memorable meals"
visual (the burger and the ramen, not the snacking pattern). Up to 4
images; only meals with a stored `image_thumb_path` or `image_path`
are eligible.

### Confidence thresholds: 5 / 15
Per the brief: `< 5` insufficient, `5-14` low, `≥15` good. Kept the
prompt's numbers; haven't seen real data that would justify
re-tuning. The `.insufficient` branch returns *defaults* rather than
nil so the settings UI can still show suggestions.

### Suppression: cancel recurring + replace with one-shot tomorrow
`NotificationScheduler.suppressTodaysWindow(...)` cancels both the
recurring trigger and any prior suppressed one-shot, then schedules a
one-shot at the same hour:minute *tomorrow*. Next reschedule (next
foreground or save) reinstates the recurring trigger via
`reschedule(...)`'s clean-slate cancel path.

Edge cases covered:
- **User saves lunch at 12:31** (post the 12:30 recurring fire): the
  recurring trigger has already fired today; suppression schedules
  tomorrow's one-shot, recurring re-installs on next foreground.
- **User saves lunch at 11:45** (pre-fire, "ate early"): cancel
  prevents today's 12:30 fire; tomorrow's one-shot is the bridge.
- **User saves lunch at 12:30, deletes the entry**: today's reminder
  is gone — the prompt explicitly accepted this trade-off, and
  un-suppressing would require persisting suppression state which
  isn't worth the complexity.
- **User saves dinner at 7pm on Sunday**: weekly recap recurring
  trigger also fires at Sunday 19:00. Both fire — they're different
  content, both useful. No collision handling.

### Notification cap: 4 (3 meals + recap)
Asserted in DEBUG via `NotificationScheduler.dumpPending`. The system
allows up to 64 pending; we're well under.

### Permission pre-prompt timing: post-success-sheet on third save
`NotificationGate.savesThreshold = 3`. The save counter increments in
`CaptureViewModel.save()` only on the analyze→save success path, NOT
on Phase 15 re-logs (re-logs aren't a "first time" milestone). The
sheet presents on the `.saved → .idle` transition AFTER the
`SavedConfirmationSheet` dismisses, only when `CoachPickerOnboardingSheet`
has already been seen — Phase 16's coach picker wins the slot first.

### Two onboarding sheets sharing one save success
The Phase 16 coach picker fires on the first save; the Phase 17
permission sheet fires on the third. Different gates, sequential not
simultaneous: the coach picker's `didSee` flag is checked first; if
set, the permission gate is checked. The two never fight for the same
slot.

### `time_zone` IANA identifier, not UTC offset
`AppForegroundOrchestrator.syncTimeZoneIfNeeded` writes
`TimeZone.current.identifier` ("Asia/Seoul"), not seconds-from-GMT.
DST cross-overs preserve the user's intended schedule.

### Recap auto-open: NO
Per the brief, the recap notification routes to the Tracker tab and
opens the sheet; opening the app *without* the notification leaves
the recap behind the "This week" banner. `RecapView` is not
auto-presented in any other code path.

### `weekly_recaps` is read-mostly
v1 ships without UPDATE / DELETE policies. Recovering a wrong recap
requires a manual SQL admin migration. The unique constraint on
`(user_id, week_start)` plus the pre-check in `generateIfNeeded` keeps
double-generation rare; on a write-write race, the SDK throws and
`generateIfNeeded` re-fetches and returns the existing row.

### Custom Codable for `WeeklyRecap.weekStart` / `weekEnd`
Postgres `date` columns serialize as bare "YYYY-MM-DD" through
PostgREST. Swift's default ISO 8601 decoder doesn't accept that
shape. The model carries a dedicated `yyyyMMdd` formatter and uses
explicit `init(from:)` / `encode(to:)` to keep the boundary explicit.

### Test target setup
The pre-existing `FoodieAITests` target had been failing silently
(empty `.xctest` filename, no Info.plist). Phase 17 needed it
working for `EatingTimeInferenceTests`. Fixes in `project.yml`:
- `GENERATE_INFOPLIST_FILE: YES`
- `PRODUCT_NAME: FoodieAITests`
- `TEST_HOST` + `BUNDLE_LOADER` so the test bundle hosts in the app
  and `@testable import` resolves
- `ENABLE_TESTABILITY: YES` on the FoodieAI target's Debug config
  (was implicit before; explicit now)

## Live verification → see PHASE_17_RUNBOOK.md

Includes the 10-step plan from the brief plus screenshot/output
mappings. The unit test suite (Step 1) is automated above; the
remaining steps require simulator UI driving and SQL access I can't
perform from this CLI environment.

## Phase 15 / 16 regression check

Verified by inspection — no edits to the following code paths:
- Phase 15 `MealHistoryService.priorOccurrences` (case-insensitive
  ILIKE) — untouched. Repeat-detection chip on `AnalysisResultView`
  unchanged.
- Phase 15 `patternsForToday` — untouched. New `patternsForRange`
  shares the analyzer (`analyzePatterns` is pure).
- Phase 15 `recentMealsForCoachContext` — untouched. Phase 16 + 17
  both consume it.
- Phase 16 `CoachObservationService.generateIfNeeded` — untouched.
  `TrackerViewModel.refresh` still calls it via `scheduleObservationGenerationIfNeeded`.
- Phase 16 `routes/gemini.js` — `/analyze` and `/coach-observation`
  paths unchanged. `/weekly-recap` is additive.
- Save flow image upload + RLS — `CaptureViewModel.save` only added
  the local-only `recordSave()` and the detached `suppressWindow`
  hook; the existing upload + insert + state transition is verbatim.
