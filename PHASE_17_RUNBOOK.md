# Phase 17 — Live Verification Runbook

10 steps. Some require waiting (Sunday 19:00 fires, the next morning's
suppression check) — those are flagged "schedule it, observe later".

Prereqs:
- Latest `main` built, signed in, with **5–7 saved meals across
  multiple days** (re-use Phase 15 / 16 seed if available).
- Local Express server pointing at the **updated** `routes/gemini.js`
  (restart `npm run dev` after pulling).
- Supabase SQL Editor open in another tab.
- Folder ready: `screenshots/phase-17/`.

---

## Step 0 — Apply the migration

Paste `migrations/006_reminders_and_recaps.sql` into the SQL Editor.
Verify:

```sql
-- six new columns with defaults
\d+ profiles      -- in psql; or look in Table Editor

-- weekly_recaps exists with both policies and the unique constraint
select policyname from pg_policies where tablename = 'weekly_recaps';
select indexname  from pg_indexes  where tablename = 'weekly_recaps';
select conname    from pg_constraint where conrelid = 'public.weekly_recaps'::regclass;
```

Expected:
- `weekly_recaps_select_own`, `weekly_recaps_insert_own`
- `weekly_recaps_user_week_idx`, `weekly_recaps_pkey`
- `weekly_recaps_user_id_week_start_key` (the unique)

Save SQL output as `00_migration_check.txt`.

---

## Step 1 — EatingTimeInference unit tests

Already automated. From the repo root:

```bash
xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FoodieAITests/EatingTimeInferenceTests test
```

Expected: 4 tests pass (3 from the brief + 1 minute-resolution sanity).
Save output as `01_inference_tests.txt`.

I've already run this locally; the captured output is in
`PHASE_17_VERIFICATION.md`'s "Build & test status" section. Re-run
for fresh evidence.

---

## Step 2 — Notification permission flow

1. Settings.app → Foodie → Notifications → toggle off / delete + reinstall.
2. Open the app, sign in.
3. Save 3 meals. After the third's success-sheet dismisses, the
   `NotificationPermissionView` should appear.
4. Capture → `02_permission_sheet.png`.
5. Tap **Yes, send nudges**. The system permission dialog appears;
   tap Allow.
6. Pull to Profile → tap **Notifications**. The view should show:
   - Master toggle on
   - Three meal toggles, each labelled with your inferred time
     ("Usually 12:30 PM", or "Suggested time …" if confidence is
     insufficient)
   - Sunday recap toggle on
   - Open Settings link
7. Capture → `03_notification_settings.png`.

If your account has < 5 saves, the labels will read "Suggested time
8:00 AM" etc. — that's the `.insufficient` confidence branch and is
correct behavior.

---

## Step 3 — Reminder scheduling

Tail the iOS console for `[Notif]` lines. The console output is the
truth source — visual confirmation isn't possible without waiting for
the trigger to fire.

1. With permissions granted and master on, in Profile → Notifications,
   toggle Lunch off then on. The `[Notif] reschedule:` log lines
   should print, followed by a `[Notif] after reschedule: count=N`
   dump listing 1–4 pending requests.
2. Confirm a `reminder.lunch.recurring` line with
   `dateMatching: ... hour: <H>, minute: <M>` matching your inferred
   lunch time.
3. Capture the console output → `04_pending_notifications.txt`.

Pass criteria:
- The dump shows ≤ 4 pending requests.
- Lunch hour/minute matches the label in the settings UI.
- If `weekly_recap_enabled` is on, a `recap.weekly` request is also
  present with `weekday: 1, hour: 19, minute: 0`.

---

## Step 4 — Suppression on save

Time the test for inside one of your meal windows (lunch is easiest:
between 10:00 and 14:59 your local time).

1. Note your inferred lunch time from Step 3's log.
2. With the lunch reminder enabled, save a meal. The
   `[Save] inserted food_logs.id=` line appears, followed shortly
   by `[Notif] suppressed today's lunch — one-shot scheduled for
   tomorrow HH:MM`.
3. Dump pending again (toggle a setting or simply foreground after
   the next reschedule). `reminder.lunch.recurring` should be gone;
   `reminder.lunch.suppressed` should be present with a
   `year/month/day` matching tomorrow.

Capture both console snippets → `05_suppression_console.txt`.

If the meal lands outside any of breakfast / lunch / dinner windows
(e.g., a 3:30am snack), no suppression happens — `MealWindow.window(for:)`
returns nil. That's expected.

---

## Step 5 — Weekly recap generation

Two ways to trigger:

**Option A** — wait for the natural window (Sunday ≥ 19:00 local or
any time Monday). Foreground the app; recap generates in background.

**Option B (faster)** — temporarily relax the trigger in DEBUG by
forcing `runOnForeground` to attempt regardless. Easiest path:

```bash
# Terminal: confirm via direct curl that the server endpoint composes
# a recap given your real data.
curl -X POST -H "Content-Type: application/json" \
  -d '{
    "week_start":"2026-05-04",
    "week_end":"2026-05-10",
    "meals":[
      {"food_name":"Margherita Pizza","eaten_at":"2026-05-08T12:30:00+09:00","calories":285,"carbs":35,"sugar":4,"protein":12,"fat":14,"fiber":3},
      {"food_name":"Greek Salad","eaten_at":"2026-05-07T12:15:00+09:00","calories":220,"carbs":12,"sugar":4,"protein":8,"fat":18,"fiber":4}
    ],
    "patterns":[{"kind":"frequent","subject":"Margherita Pizza","detail":"4 times this week, mostly Fridays"}],
    "preferred_coaches":["Marcus Aurelius"]
  }' \
  http://localhost:3001/weekly-recap | jq .
```

Run twice. Both responses should:
- Have a `coach_name` from the preferred list when present.
- Have a 2-3 sentence `body` without "should", "too much", "indulged",
  or shame language.
- Have `headline_stat` of the form `"<n> meals · <total> calories"`
  computed server-side (NOT hallucinated by Gemini).

Save both as `06_curl_recap.json` (append). **Read the bodies** —
flag any prescriptive framing ("you should", "next week try…").

For the in-app DB write, simplest path: in the SQL Editor, manually
insert a recap row for last week:

```sql
insert into weekly_recaps (user_id, week_start, week_end, coach_name,
                           body, headline_stat, top_pattern)
values (auth.uid(),
        '2026-05-04', '2026-05-10',
        'Marcus Aurelius',
        'Twenty-three meals across seven days. Friday remained your pizza day...',
        '23 meals · 14,200 calories',
        'Pizza, 4 times — mostly Fridays')
returning *;
```

Then the iOS app on next foreground / Tracker refresh will surface
the "This week" banner. Capture the SQL output as `07_recap_db.txt`
and the Tracker tab as `07_recap_banner.png`.

---

## Step 6 — Recap view

Tap the "This week" banner. The recap sheet opens with a NavigationStack
(Close button top-left, "Past recaps" link at the bottom).

Layout pass:
- **WEEK OF** eyebrow + date range
- Hero collage (≤4 photos selected by highest-calorie, ties by
  recency — see RecapView.collageMeals)
- Headline stat in display1 ("23 meals")
- Sub-line ("14,200 calories")
- EditorialQuote with the body + coach attribution
- Top pattern card (if `top_pattern` is non-null)
- "View this week's meals" expander with all logs in the range
- "Past recaps" link

Capture → `08_recap_view.png`.

---

## Step 7 — Server endpoint sanity (already in Step 5)

Already covered by `06_curl_recap.json`. If you didn't, run it now.
Two samples; check for variability and absence of shame language.

---

## Step 8 — Reschedule on profile change

In Profile → Notifications, toggle Dinner off. Console should log:
- `[Profile] UPDATE profiles SET ... d=false`
- `[Notif] reschedule: ...` followed by a dump that no longer
  includes `reminder.dinner.recurring`.

Toggle back on; the recurring trigger reappears. Capture both dumps
to `09_reschedule_console.txt`.

---

## Step 9 — Cap verification

In the Step 3 / Step 8 dumps, the `[Notif] after reschedule: count=N`
line should never report `count > 4`. If it does, the assertion
warning `⚠️ Phase 17 cap exceeded` will print loudly. Note the max
count seen across all your toggles in the verification report.

---

## Step 10 — RLS isolation

```sql
select user_id, count(*) from weekly_recaps group by user_id;
```

Only your `auth.uid()` should appear. To prove cross-user isolation,
copy a known recap id and try to fetch it as a different signed-in
user — should return zero rows.

```sql
select user_id, coach_name, headline_stat, body
  from coach_observations  -- Phase 16 cross-check
  order by created_at desc limit 10;
select user_id, coach_name, headline_stat, body
  from weekly_recaps
  order by created_at desc limit 10;
```

Capture combined output as `10_rls_check.txt`.

---

## Hand-back checklist

- [ ] `00_migration_check.txt`
- [ ] `01_inference_tests.txt`
- [ ] `02_permission_sheet.png`
- [ ] `03_notification_settings.png`
- [ ] `04_pending_notifications.txt`
- [ ] `05_suppression_console.txt`
- [ ] `06_curl_recap.json` (2 samples)
- [ ] `07_recap_db.txt` + `07_recap_banner.png`
- [ ] `08_recap_view.png`
- [ ] `09_reschedule_console.txt`
- [ ] `10_rls_check.txt`
- [ ] Brief notes on any prescriptive language seen in step 5/7 bodies
- [ ] Confirmation that Phase 15/16 features still work
  (repeat-detection chip, patterns card, coach observation)

I'll fold these into `PHASE_17_VERIFICATION.md` and the trilogy is
closed once Step 5–6 (an actual recap rendered from real data) is
green.
