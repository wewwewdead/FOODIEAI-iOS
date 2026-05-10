# Phase 18 — Verification

> Build is green (`xcodebuild ... build → ** BUILD SUCCEEDED **`).
> Existing test suite is green (6/6 passed on iPhone 17 sim, iOS 26.4.1).

## What was implemented

| Area | File(s) |
| --- | --- |
| Schema | `migrations/007_meal_mood.sql` (mood column + partial index + `weekly_recaps.mood_summary`) |
| Models | `FoodLog.Mood` enum + `mood: Mood?` field; `WeeklyRecap.moodSummary` |
| Service: mutation | `FoodLogService.setMood(_:on:)` |
| Service: reads | `MealHistoryService.recentMoodsForCoachContext()`, `.moodLog(filter:)` |
| Service: pattern | `MealHistoryService.Pattern.Kind.moodCluster` + analyzer rule (tough-only, 3+ in 7d) |
| Service: analyze ctx | `AnalyzeService.analyze(jpegData:recentMeals:preferredCoaches:recentMoods:)` |
| Service: coach obs | `CoachObservationService.generateIfNeeded(patterns:preferredCoaches:recentMoods:)` |
| Service: recap | `WeeklyRecapService` — per-meal `mood` on wire, `mood_summary` round-trip |
| UI: pulse | `MoodPulseSheet.swift` — 280pt, brand-ivory bg, 3 emoji buttons + Skip |
| UI: state machine | `CaptureViewModel` — new `.moodPulse(image, response, log)` state, `recordMood` / `skipMoodPulse` / `cancelMoodPulseIfPresent` + auto 1.2s transition |
| UI: presentation | `CaptureView` — sheet wired to `state.isMoodPulse`; `scenePhase` guard |
| UI: pattern card | `TodayView.PatternCard` — icon mapping for `.moodCluster` (`cloud.rain` / inkMute) |
| UI: profile | `MoodLogView.swift` — filter chips + thumbnail rows + edit-on-tap; new ProfileView row |
| Recap UI | `RecapView` — new `moodSummaryBlock` rendered after the headline |

## How the post-save flow looks now

```
.idle
  → setPhoto                 → .picked
  → analyze                  → .analyzing → .ready | .noFood | .failed
.ready
  → save                     → .saving   → .saved | .saveFailed
.saved
  ──┬─ user closes sheet     ─→ .moodPulse  (via discardSaved)
    └─ 1.2s auto-transition  ─→ .moodPulse  (scheduleMoodPulseTransition)
.moodPulse
  → recordMood(.loved|.fine|.tough)         → .idle  (writes mood async)
  → skipMoodPulse / drag-dismiss            → .idle  (no write)
  → cancelMoodPulseIfPresent (background)   → .idle  (no write)
```

## Manual checks (run after merging the matching server changes)

> See `PHASE_18_RUNBOOK.md` for the SQL the server-side checks below
> rely on. The full list mirrors the brief's Step 11.

1. **Pulse appears after save.** Save a meal → SavedConfirmationSheet
   for ~1.2s → MoodPulseSheet appears. Tap "Loved" → confirm bump
   animation lands → sheet dismisses → Capture is back to idle.
2. **DB write.** SQL: `select mood from food_logs order by eaten_at desc limit 1;` → `loved`. `update … set mood='happy';` → constraint error.
3. **Skip path.** Save another meal → tap Skip → row's `mood` stays NULL.
4. **Background-during-pulse.** Save a meal → background while
   SavedConfirmation/MoodPulse is up → wait 5s → foreground →
   no MoodPulseSheet, app at `.idle`, `mood IS NULL`.
5. **Edit from Profile.** Profile → Mood log → tap a Loved row → pick
   Tough → row reflects the change after the reload.
6. **Server context with moods.** Save 5+ meals across all three
   moods, then analyze a fresh meal — Xcode console:
   `[Analyze] POST … recentMoods=N` with N > 0.
7. **Mood cluster pattern.** Insert 3 `mood='tough'` rows in the last
   7 days → refresh Today → "3 meals you marked as tough this week"
   pattern card with `cloud.rain` icon appears.
8. **Coach observation references mood.** Force a fresh observation
   generate (Tracker refresh after dismissing the active card) →
   server includes `recent_moods` in body → over multiple
   regenerations, at least one observation references the cluster.
9. **Weekly recap mood_summary.** With 3+ mood-labeled meals in the
   completed week, force a regenerate → `mood_summary` is non-null
   in the row → renders as a small caption under the headline in
   `RecapView`.
10. **RLS.** Mood is a column on `food_logs`. The existing
    `food_logs_select_own / update_own / insert_own / delete_own`
    policies cover it without modification.

## Decisions worth flagging back

- **1.2s saved → moodPulse timer.** Picked because the existing
  SavedConfirmationSheet success choreography stabilizes at ~t+550ms;
  1.2s gives the user a moment to absorb the checkmark before the
  question lands. If user testing shows this feels rushed (or
  conversely, that the pulse arrives too late), tune
  `scheduleMoodPulseTransition` in `CaptureViewModel`.
- **SavedConfirmationSheet does not auto-dismiss.** It still requires
  user dismissal OR the 1.2s transition. We preserve the visible
  "Close" button so the user is never trapped if they want to leave
  faster than the timer.
- **moodCluster only emits for `tough`.** Documented inline.
  Clustering on `loved` reads as the app applauding the user; `fine`
  is the boring middle and produces filler. The framework supports
  the other two moods — if a future phase wants them, swap the
  filter in `MealHistoryService.analyzePatterns`.
- **Mood log uses reload-after-write rather than in-place patch.**
  `FoodLog` is a value type with all-`let` properties; in-place
  mutation needed JSON-strategy gymnastics that weren't worth the
  ergonomic gain. The server round-trip is cheap on a single user's
  30 days of mood-labeled meals.
- **No avatar on Mood log rows.** Sticks to the Phase-7 deferral.

## Server changes (not in this commit; out of scope for this iOS repo)

The Express proxy lives in a sibling repo. The runbook documents the
required additions to `routes/gemini.js`, `routes/coach-observation.js`,
and `routes/weekly-recap.js`. iOS sends the new fields opt-in: empty
arrays are omitted entirely so the multipart/JSON body stays
byte-identical to Phase-17 shape against an un-upgraded server.

## Files added

- `migrations/007_meal_mood.sql`
- `FoodieAI/Features/Home/MoodPulseSheet.swift`
- `FoodieAI/Features/Profile/MoodLogView.swift`
- `PHASE_18_RUNBOOK.md`
- `PHASE_18_VERIFICATION.md` (this file)

## Files modified

- `FoodieAI/Models/FoodLog.swift`
- `FoodieAI/Models/WeeklyRecap.swift`
- `FoodieAI/Services/FoodLogService.swift`
- `FoodieAI/Services/MealHistoryService.swift`
- `FoodieAI/Services/AnalyzeService.swift`
- `FoodieAI/Services/CoachObservationService.swift`
- `FoodieAI/Services/WeeklyRecapService.swift`
- `FoodieAI/Features/Home/CaptureViewModel.swift`
- `FoodieAI/Features/Home/CaptureView.swift`
- `FoodieAI/Features/Home/CapturePreview.swift` *(switch exhaustiveness)*
- `FoodieAI/Features/Profile/ProfileView.swift`
- `FoodieAI/Features/Recap/RecapView.swift`
- `FoodieAI/Features/Tracker/TodayView.swift`
- `FoodieAI/Features/Tracker/TrackerViewModel.swift`
- `FoodieAI/Core/Components/MealCard.swift` *(preview literal)*
- `FoodieAI/Core/Components/MealRow.swift` *(preview literal)*
- `FoodieAI/Core/Components/ExpandableMealCard.swift` *(preview literal)*
- `FoodieAI/Core/Components/ComponentGallery.swift` *(preview literal)*
- `FoodieAI/Features/Tracker/DayDetailSheet.swift` *(preview literal)*
- `FoodieAITests/FoodieAITests.swift` *(test fixture literal)*
