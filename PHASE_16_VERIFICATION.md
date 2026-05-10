# Phase 16 — Coach Continuity — Verification

## Build status

`xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI -destination
'generic/platform=iOS Simulator' -configuration Debug build` → **succeeds**
with only the pre-existing "Traditional headermap style" project-level
warning. Server side: `node --check routes/gemini.js` passes.

## Canonical coach pool (server source of truth)

From `routes/gemini.js` (`deadCelebs` array, also mirrored client-side
in `CoachPreferencesView.canonicalCoaches`):

```
Albert Einstein
Cleopatra
Julius Caesar
Shakespeare
Frida Kahlo
Bruce Lee
Leonardo da Vinci
Napoleon Bonaparte
Amelia Earhart
Marie Curie
```

10 coaches. Bias toward names that tend to evoke a distinct voice
(letters, science, empire, art, martial discipline). If you add a
coach to the server, mirror it in `CoachPreferencesView.swift` —
`PHASE_16_RUNBOOK.md` calls this out for future contributors.

## Files added

| Path | Purpose |
| --- | --- |
| `migrations/005_coach_continuity.sql` | `profiles.preferred_coaches text[]` + new `coach_observations` table with four RLS policies. |
| `FoodieAI/Models/CoachObservation.swift` | `CoachObservation`, `NewCoachObservation`, `CoachObservationDismiss`. |
| `FoodieAI/Services/CoachObservationService.swift` | CRUD + orchestration: `todaysObservation`, `recentObservations`, `recentObservationsMatching`, `insert`, `dismiss`, `generateIfNeeded`. Wraps the `POST /coach-observation` round-trip. |
| `FoodieAI/Core/Components/CoachObservationCard.swift` | Editorial card on Today; reuses `CoachBadge` + body-emphasis italic. |
| `FoodieAI/Features/Profile/CoachPreferencesView.swift` | Star/unstar list. Owns the canonical coach list mirror + per-toggle write via `ProfileService.setPreferredCoaches`. |
| `FoodieAI/Features/Onboarding/CoachPickerOnboardingSheet.swift` | One-time bottom sheet after first save. Batch save on Done. UserDefaults `phase16.didSeeCoachPicker` flag. |

## Files modified

| Path | Why |
| --- | --- |
| `routes/gemini.js` | `/analyze` accepts optional `recent_meals` JSON + `preferred_coaches`; appends a context paragraph to the prompt (does not replace existing instructions). New `pickCoach(preferred)` weights starred coaches 3:1. New `POST /coach-observation` endpoint generates a 1–3 sentence editorial body in a chosen coach's voice. |
| `FoodieAI/Models/Profile.swift` | `preferredCoaches: [String]` + decode-with-default for backward compat. `ProfileUpdate` gained an opt-in `preferredCoaches: [String]?` field with a custom encoder so omitted keys aren't serialized as `null` (which would clobber the column). |
| `FoodieAI/Services/ProfileService.swift` | `updateProfile(...)` gained an optional `preferredCoaches:` parameter. New `setPreferredCoaches(_:)` for the prefs screen's narrow write. |
| `FoodieAI/Services/MealHistoryService.swift` | Added `recentMealsForCoachContext()` returning up to 14 `FoodLog` rows from the last 14 days. |
| `FoodieAI/Services/AnalyzeService.swift` | `analyze(jpegData:recentMeals:preferredCoaches:)`. Refactored multipart body builder to support optional text parts. v1 callers (no extra args) emit a byte-identical body. |
| `FoodieAI/Features/Home/CaptureViewModel.swift` | `analyze()` now fetches recent meals + preferences in parallel with image compression (both wrapped in `try?` — failures degrade to v1 behavior). |
| `FoodieAI/Features/Tracker/TrackerViewModel.swift` | Holds `activeObservation`; runs `todaysObservation` alongside today's-logs/patterns; schedules a detached `generateIfNeeded` when patterns exist + account ≥ 3 days old. New `dismissActiveObservation()` writes `dismissed_at`. |
| `FoodieAI/Features/Tracker/TodayView.swift` | New `coachObservationSection` between patterns and meal list; renders `CoachObservationCard`. |
| `FoodieAI/Features/Profile/ProfileView.swift` | NavigationStack wrapper (toolbar hidden on root, re-shown on push); new `coachesSection` row → `CoachPreferencesView`. |
| `FoodieAI/Features/Home/CaptureView.swift` | Triggers the one-time coach picker after the success sheet dismisses on first save. |

## Decisions log

### Server: append context, don't replace
The brief was explicit. The Gemini function-call schema (the JSON the
client decodes into `GeminiAnalysis`) didn't change — only the
prompt text grew an optional context paragraph. The "no food
detected" fallback path is untouched. Verified by reading
`routes/gemini.js` end-to-end.

### Weighted coach picker, not a hard preference
`pickCoach(preferred)` skews the rotation 3× toward starred names but
still allows unstarred coaches through. Reasoning: a hard filter
would reduce variety to whatever the user clicked once, which feels
flat. 3× is a soft skew — over a dozen analyses the user clearly
hears their picks more, but the rotation never feels deterministic.
Empty preferences → uniform random over the full pool (v1 behavior
preserved).

### Account-age guard set to 3 days
Hard-coded as `TrackerViewModel.observationMinAccountAgeDays = 3`,
matching the brief. Sub-3-day accounts can still see the Patterns
card (Phase 15) but won't have `coach_observations` generated. This
keeps editorial cards from flashing on a fresh account before any
real eating context exists. Lowering to 1 would make first-week
demos feel more alive; keeping at 3 to honor the brief.

### Dedup window: 7 days, by `(pattern_kind, pattern_subject)`
`recentObservationsMatching(...)` with `withinDays: 7`. Without this,
the same "you've had pizza 4 times" observation regenerates on every
refresh until the count changes — which would feel like nagging.
Picking the focus pattern client-side using the same priority rule
as the server (`.frequent` over `.firstThisWeek`) means we can skip
the model round-trip when we know the server would re-anchor on a
dedupable subject.

### Dismissals soft-delete (set `dismissed_at`), not hard-delete
The brief asked for a `dismissed_at` column rather than a DELETE.
Phase 17's weekly recap reads the full history (active + dismissed)
to characterize the coach's voice over time, so we keep dismissed
rows in place and just hide them from `todaysObservation()` via
`is("dismissed_at", value: nil)`.

### Detached generation, not blocking
`TrackerViewModel.refresh()` returns as soon as today's-logs +
patterns + active-observation lookups complete. The model round-trip
to `/coach-observation` runs in a `Task.detached` so the UI doesn't
wait. When the new card lands, it surfaces in place via
`MainActor.run { self.activeObservation = generated }` — the user
doesn't have to switch tabs to see it. This is a small but
deliberate UX choice; the alternative (generate inline + spinner) was
heavier than the content warranted.

### Multipart body refactor preserves byte-identical v1 shape
Pre-Phase-16 `analyze(jpegData:)` calls now route through the same
multipart builder as the new context-aware path, but with both
optional text parts set to `nil`. The resulting body has only the
`image` part — byte-identical to the prior single-field shape, so the
server's pre-Phase-16 happy path is unchanged.

### Custom encoder on `ProfileUpdate`
The brief required `preferredCoaches` to be opt-in: `nil` means "don't
touch the column". Swift's synthesized `Encodable` for an `Optional`
field already uses `encodeIfPresent` (so nil is omitted, not serialized
as `null`). I made this explicit with a custom `encode(to:)` so the
contract is unambiguous against future Swift toolchain changes.
Practical impact: a goals-only save won't clobber `preferred_coaches`
even if the patch is constructed with `preferredCoaches: nil`.

### Onboarding: post-first-save, not pre-first-analyze
Brief said "after the user signs in for the first time and completes
their first analyze". I trigger the picker on the `.saved → .idle`
transition (i.e., after they've seen the success sheet on the very
first save). Reasoning: pre-first-analyze, the user has nothing to
contextualize "coaches" with — they haven't met one yet. Showing the
picker after they've heard one celebrity voice gives the feature
something to anchor on. UserDefaults flag is local, so signing out +
back in re-presents — acceptable trade-off vs. plumbing a per-account
flag through `profiles`.

### Patterns / repeat-detection regression check
Phase 15's `MealHistoryService.priorOccurrences` (case-insensitive
ILIKE), `recentUniqueMeals`, and `patternsForToday` are untouched.
Phase 16 only consumes them. The Phase 15 repeat-detection chip on
`AnalysisResultView` and the `patternsSection` on `TodayView` both
still build and render. Verified by inspection — no edits to those
code paths.

## RLS isolation expectation

The four-policy pattern on `coach_observations` mirrors `food_logs`:
SELECT/INSERT/UPDATE/DELETE all gated on `auth.uid() = user_id`. The
SDK never sends `user_id` on insert; the column default
(`auth.uid()`) fills it server-side. Verification step 8 in the
runbook confirms isolation.

## Manual verification → see PHASE_16_RUNBOOK.md

Live walk-through is documented separately because the simulator UI
isn't drivable from this environment. Hand back the screenshots,
SQL outputs, and the two curl response sets to fold into this doc.

## Open follow-ups (out of scope for Phase 16)

- Server-side endpoint for the canonical coach list (currently
  duplicated client-side in `CoachPreferencesView.canonicalCoaches`).
- "Coach Notes" history screen reading `recentObservations(limit:)`
  (`CoachObservationService` already exposes the query).
- A debug menu entry to reset `phase16.didSeeCoachPicker` for QA.
  `CoachPickerOnboardingSheet.debug_resetDidSee()` exists; just not
  wired to a UI affordance yet.
- Tap-to-expand on `CoachObservationCard` body (the `onBodyTap`
  closure is plumbed but unused — Phase 17 territory).
