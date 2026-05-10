# Phase 15 — Live Verification Runbook

Walk-through to drive in roughly 10 minutes. Captures the four
screenshots and the SQL output the Phase 15 brief asked for.

Prereqs:
- Latest `main` built on a sim, signed in.
- Local Express `/analyze` server running.
- Supabase SQL Editor open in another tab on your project.
- A folder ready: `screenshots/phase-15/`.

---

## Step 0 — Apply the migration (one-time)

In the Supabase SQL Editor, paste the contents of
`migrations/004_food_log_origin.sql` and run. Then in Table Editor,
sort `food_logs` by `created_at` descending and confirm the
**`origin` column shows `analyzed`** for every existing row (this is
verification step 7). One screenshot of the Table Editor's column
view is sufficient — save as `00_origin_backfill.png`.

---

## Step 1 — Repeat detection (verification step 1)

You need at least one prior save of a recognizable dish. If you don't
have one, take a quick photo of pizza or a salad → analyze → save once
to seed.

Then:

1. Capture tab → take a photo of the **same dish** again.
2. Tap **Analyze**.
3. When the result screen lands, the **DETECTED** food name should be
   followed by a small chip:
   `↻ You've had this once before. Last time: today.`
4. Screenshot the result page with the chip visible →
   `01_repeat_detection.png`.

If the chip doesn't appear: confirm the `food_name` of the prior row
in Table Editor matches what Gemini returned this time (case-
insensitively, post-fix). If Gemini returned a wildly different name
("Cheese Pizza" vs. "Margherita Pizza") that's a Gemini variance, not
a Phase 15 bug — try a third photo.

Don't save yet — keep the result page on screen for the next step.

---

## Step 2 — Quick re-log picker (verification step 2)

1. Tap **Discard** on the result screen to get back to idle Capture.
2. Below the photo card, tap **"Or pick from your recent meals →"**.
3. Sheet should slide up titled "Re-log a meal" with a list of your
   recent unique meals as `MealCard` rows.
4. Screenshot the sheet → `02_relog_picker.png`.

If the sheet shows "No saved meals yet" but you do have saved meals
in the last 30 days: you're hitting the empty branch — capture
`02_relog_empty.png` instead and stop here, this is a bug to surface.

---

## Step 3 — Re-log inserts a row with the correct columns (verification step 3)

1. From the picker, tap any meal row.
2. Sheet dismisses, success toast slides up at the bottom for ~1.6s
   ("Re-logged · {meal name}").
3. Switch to Supabase Table Editor → `food_logs`, sort by `created_at`
   descending. The newest row should have:
   - `origin` = `relogged`
   - `source_log_id` = the `id` of the row whose data was copied
   - `image_path` and `image_thumb_path` **identical** to the source
     row (no new upload)
4. Screenshot the Table Editor with the new row + source row both
   visible → `03_relog_table_editor.png`. The source row's `id`
   should match the new row's `source_log_id`.

To find the source row easily: copy the `source_log_id` value, paste
into the `id` filter, confirm match.

---

## Step 4 — Patterns surface on Today (verification step 4)

You need 3+ saves of the same dish in the last 14 days. The fastest
way: do two more re-logs of the same source meal (Step 3 path, twice).
Now you have one `analyzed` + three `relogged` rows for that food.

1. Switch to **Tracker** tab → Today.
2. Pull-to-refresh (or background and reopen the tab).
3. A new **PATTERNS** section should appear between the macro bars and
   the meal list, with a card:
   `↻ You've had {meal name} 4 times in the last two weeks.`
   Possibly with a `Mostly {weekday}s.` detail if the cluster lines up.
4. Screenshot the Today tab with the Patterns card visible →
   `04_patterns.png`.

---

## Step 5 — Patterns hides when nothing to surface (verification step 5)

In the SQL Editor, push your recent rows out of the 14-day window
**but keep them, don't delete**:

```sql
-- Snapshot for restoration:
select id, eaten_at from food_logs where user_id = auth.uid()
order by eaten_at desc limit 20;
```

```sql
-- Push everything beyond the 14-day cutoff:
update food_logs
   set eaten_at = now() - interval '60 days'
 where user_id = auth.uid();
```

1. In the app, pull-to-refresh Today.
2. The **PATTERNS** section should be **gone entirely** (not "no
   patterns yet" filler). The meal list should be empty too because
   `todaysLogs` filters by local-day window.
3. Screenshot the Today tab with no patterns → `05_no_patterns.png`.

**Restore immediately** so you don't trash your real data:

```sql
-- Replace the timestamps with what you recorded above.
-- One UPDATE per row, or rerun the analyze flow if you don't mind
-- losing eaten_at precision.
```

If you want a softer test, just push a single row's `eaten_at`
forward and confirm Patterns hides — same principle, less to undo.

---

## Step 6 — RLS isolation (verification step 6)

In the SQL Editor, run as the default role (anon-equivalent, scoped
by RLS):

```sql
select user_id, food_name, count(*) as n
from food_logs
group by user_id, food_name
having count(*) >= 3
order by n desc;
```

Capture the entire result table as text and paste into the
verification doc under "RLS check output". Every `user_id` returned
must match your signed-in `auth.uid()`. If a different user_id appears,
RLS is broken.

To get your `auth.uid()` for the comparison:
```sql
select auth.uid();
```

(Run while signed in via the SQL Editor's user-impersonation if
available; otherwise pull the `id` from `profiles` filtered by your
email.)

---

## Step 7 — Migration backfill (verification step 7)

Already covered by Step 0's `00_origin_backfill.png`. To double-check
that pre-Phase-15 saves are tagged `analyzed`, the cleanest query is:

```sql
select origin, count(*) from food_logs group by origin;
```

You should see only `analyzed` and `relogged` (the latter = however
many re-logs you did during this verification). Paste output into
the doc.

---

## Hand-back checklist

Reply with:

- [ ] `00_origin_backfill.png`
- [ ] `01_repeat_detection.png`
- [ ] `02_relog_picker.png` (or `02_relog_empty.png` if applicable)
- [ ] `03_relog_table_editor.png`
- [ ] `04_patterns.png`
- [ ] `05_no_patterns.png`
- [ ] SQL output of the RLS group-by-count query
- [ ] SQL output of the `select origin, count(*)` query
- [ ] Anything that didn't behave as described above

I'll fold these into `PHASE_15_VERIFICATION.md` and we're greenlit
for Phase 16.
