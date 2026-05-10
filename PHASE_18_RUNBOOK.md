# Phase 18 — Mood Pulse & Adaptive Coach Tone — Runbook

## What ships in this phase

A first emotional dimension on every saved meal: a one-second post-save
pulse asking "Did this hit the spot?" with three emoji answers
(💚 Loved / 🙂 Fine / 🌧 Tough). The label flows into:

- The coach quote on `/analyze` (recent moods sent as context)
- The Today screen's editorial coach observation
- A new `moodCluster` Pattern card ("3 meals you marked as tough this week")
- The weekly recap (`mood_summary` field)
- A user-facing "Mood log" surface on the Profile screen

## Run order

### 1. Database migration (run once per environment)

In the Supabase SQL Editor, run `migrations/007_meal_mood.sql` top to
bottom. The migration is idempotent (`add column if not exists`).
Verifies:

```sql
-- column exists, defaults NULL, has check
\d+ public.food_logs
-- existing rows show NULL for mood
select count(*) filter (where mood is null) as null_count,
       count(*) filter (where mood is not null) as labelled
  from public.food_logs;
-- partial index appears
select indexname from pg_indexes
 where tablename = 'food_logs' and indexname = 'food_logs_user_mood_idx';
-- weekly_recaps gained mood_summary
\d+ public.weekly_recaps
```

Manual constraint check:

```sql
-- should reject:
update public.food_logs set mood = 'happy' where id = '<some-id>';
-- expect: ERROR: new row for relation "food_logs" violates check constraint "food_logs_mood_check"
```

### 2. iOS app

Regenerate the Xcode project after pulling:

```sh
./tools/xcodegen generate
```

Build & run on a simulator (requires the local Supabase + analyze proxy
env per `Secrets.xcconfig`).

### 3. Server (Express proxy — separate repo)

The iOS multipart/POST shapes already include the new fields. Three
server changes are required for the new context to actually shape
output. **None of these changes break old clients** — every new field
is optional with a default.

#### `routes/gemini.js` — `POST /analyze`

Accept a new `recent_moods` multipart field (JSON-encoded). Cap
defensively at 10 entries. Append a context paragraph to the Gemini
prompt:

> "The user has shared how they felt about some recent meals: [...].
> If a clear emotional pattern is relevant to today's analysis, you
> may reference it lightly — never lecturing, never therapy-speak.
> Only mention emotional patterns when genuinely useful."

Wire shape (matches what iOS sends):

```json
[
  { "food_name": "Margherita Pizza", "mood": "loved", "eaten_at": "..." },
  { "food_name": "Caesar Salad",     "mood": "fine",  "eaten_at": "..." },
  { "food_name": "Late ramen",       "mood": "tough", "eaten_at": "..." }
]
```

#### `routes/coach-observation.js` — `POST /coach-observation`

Same `recent_moods` field, same 10-entry cap. The observation prompt
should bias toward observation, not interpretation. Right:
"Aurelius noticed you've been logging tough-day meals this week."
Wrong: "you seem stressed" (clinical, presumptuous).

Pattern kinds the iOS client may now send: `frequent`, `firstThisWeek`,
`streak`, `moodCluster`. The server should treat unknown kinds as
plain-string subject text (no schema break).

#### `routes/weekly-recap.js` — `POST /weekly-recap`

Two extensions:

1. Each meal in `meals[]` may now carry a `mood` field (string or null).
2. Response gets a new optional field `mood_summary` (string or null).
   Prompt rule: **return null when fewer than 3 meals in the week
   carry mood labels.** Most weeks are mixed; that's fine to say.

Example response with mood:

```json
{
  "coach_name": "Aurelius",
  "body": "...",
  "headline_stat": "23 meals · 14,200 kcal",
  "top_pattern": "Margherita Pizza three Fridays running.",
  "mood_summary": "Three loved meals, four tough ones. A heavy week."
}
```

## What changes for the iOS code (summary)

| File | Change |
| --- | --- |
| `migrations/007_meal_mood.sql` | New `mood` column + partial index; `mood_summary` on `weekly_recaps` |
| `Models/FoodLog.swift` | New `Mood` enum + `mood: Mood?` field |
| `Models/WeeklyRecap.swift` | New `moodSummary: String?` round-tripped on read+write |
| `Services/FoodLogService.swift` | `setMood(_:on:)` UPDATE helper |
| `Services/MealHistoryService.swift` | `recentMoodsForCoachContext()` (10), `moodLog(filter:)` (Profile), new `moodCluster` analyzer rule (tough-only, 3+ in 7d) |
| `Services/AnalyzeService.swift` | New optional `recentMoods` parameter → `recent_moods` multipart |
| `Services/CoachObservationService.swift` | `recentMoods` forwarded to `/coach-observation` |
| `Services/WeeklyRecapService.swift` | Per-meal `mood` on the wire; `mood_summary` round-trip |
| `Features/Home/MoodPulseSheet.swift` | New 280pt sheet — three emoji buttons + Skip |
| `Features/Home/CaptureViewModel.swift` | New `.moodPulse` state + `recordMood`/`skipMoodPulse`/`cancelMoodPulseIfPresent`; auto-transition `.saved → .moodPulse` after 1.2s |
| `Features/Home/CaptureView.swift` | Mood-pulse sheet presentation; `scenePhase` guard |
| `Features/Profile/MoodLogView.swift` | New "Mood log" surface (filter chips + edit-on-tap) |
| `Features/Profile/ProfileView.swift` | New row → MoodLogView |
| `Features/Tracker/TodayView.swift` | New icon mapping for `.moodCluster` pattern (`cloud.rain` / inkMute) |

## Decisions log

- **Three values, not five.** Loved / Fine / Tough. Five would dilute
  signal; three forces a real choice.
- **mood is set after insert, not part of NewFoodLog.** Save stays fast;
  mood is optional reflection.
- **Auto-transition `.saved → .moodPulse` at 1.2s.** Existing
  SavedConfirmationSheet choreography lands at ~t+550ms; 1.2s gives
  the user a moment with the success state before the question lands.
  User-driven dismiss converges on the same `.moodPulse` state.
- **Background drops the pulse.** If the user backgrounds during the
  success sheet or pulse, we go to `.idle`. Better to lose the data
  point than to feel ambushed on next foreground.
- **`moodCluster` only fires on `tough`.** Clustering on `loved` reads
  as the app applauding the user; `fine` is the boring middle. Both
  produce filler. Documented in `MealHistoryService.analyzePatterns`.
- **Profile mood log is read-only-ish.** Filter + edit-on-tap. No
  charts, no "your week emotionally" dashboards. Just the data.
- **`mood_summary` is server-suppressed under 3 labels.** Most weeks
  are mixed. The recap should say so honestly rather than make up
  emotional shape.
