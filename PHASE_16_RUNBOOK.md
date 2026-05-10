# Phase 16 — Live Verification Runbook

15-ish minutes. Captures the artifacts the brief asked for plus a
few extras for the decisions log.

Prereqs:
- Latest `main` built on a sim, signed in.
- Local Express server pointing at the **updated** `routes/gemini.js`
  — restart `npm run dev` after pulling.
- Supabase SQL Editor open in another tab.
- Folder ready: `screenshots/phase-16/`.
- An account with at least 5–7 saved meals across multiple days.
  Re-use the Phase 15 seed (the four re-logs you may have created
  during that runbook are perfect).

---

## Step 0 — Apply the migration

Paste `migrations/005_coach_continuity.sql` into the SQL Editor.
Verify:

```sql
-- preferred_coaches column populated with empty array on existing rows
select id, preferred_coaches from profiles limit 5;

-- coach_observations table exists, RLS enabled, four policies present
select policyname from pg_policies where tablename = 'coach_observations';
```

Expected: `coach_observations_select_own`, `coach_observations_insert_own`,
`coach_observations_update_own`, `coach_observations_delete_own`.

Save SQL output as `00_migration_check.txt`.

---

## Step 1 — Server context-awareness via curl (verification step 1)

Find a real food photo (`pizza.jpg` if you have one). Run each curl
command **at least three times** so you can see the variance in coach
quotes. Capture as raw text:

```bash
# Without context — should sound like generic celebrity advice
curl -X POST -F "image=@pizza.jpg" \
     http://localhost:3001/analyze | jq .

# With context — same image, signal of repetition
curl -X POST -F "image=@pizza.jpg" \
  -F 'recent_meals=[
    {"food_name":"Margherita Pizza","eaten_at":"2026-05-08T12:00:00Z"},
    {"food_name":"Margherita Pizza","eaten_at":"2026-05-05T12:00:00Z"},
    {"food_name":"Margherita Pizza","eaten_at":"2026-05-02T12:00:00Z"}
  ]' \
  http://localhost:3001/analyze | jq .
```

Save responses as `01_curl_no_context.json` and `02_curl_with_context.json`
(append three samples in each file).

What to check:
- Both shapes parse as `{analysis: {...}, coach: "..."}` — the JSON
  contract is identical.
- Without-context quotes shouldn't reference frequency or repetition.
- With-context quotes occasionally — not always — should mention the
  pattern. Note in the verification report which samples did and
  didn't (3 out of 6 acknowledging is a fine ratio; 6/6 means the
  prompt is over-tilted, 0/6 means context isn't reaching Gemini).
- Server log line for the with-context request should read like
  `[analyze] coach=<Name> with N chars of recent-meals context`.

---

## Step 2 — End-to-end analyze with context (verification step 2)

In the app:
1. Take a photo of a food you've saved at least 3 times in the last 14
   days (re-use Phase 15's pizza seed).
2. Tap **Analyze**.
3. Tail the server log; you should see
   `[analyze] coach=<Name> with N chars of recent-meals context`.
4. Capture the iOS result screen (the coach quote may or may not
   reference frequency — both are valid) → `03_analyze_with_context.png`.
5. Capture the matching server log line as `03_analyze_server_log.txt`.

If the log reads `no context`, the iOS multipart isn't shipping
`recent_meals`. Most likely cause: Phase 15's
`MealHistoryService.recentMealsForCoachContext` returned 0 rows for
your account; populate at least one meal in the last 14 days first.

---

## Step 3 — Coach observation card on Today (verification step 3)

You need at least 3 saves of the same dish in the last 14 days for
the Patterns card (and therefore the observation) to fire.

1. Switch to **Tracker** tab → Today.
2. Pull-to-refresh. The **PATTERNS** card from Phase 15 should
   appear.
3. Wait 2–4 seconds (the detached generate runs after the initial
   refresh). Pull-to-refresh again.
4. The **CoachObservationCard** should appear between Patterns and
   the meal list — single-letter coach badge, italic body, "tap to
   dismiss" link.
5. Capture → `04_observation_card.png`.

If the card never lands: check the server log for a
`[coach-observation] coach=<Name> focus=<Kind>:<Subject>` line. If
that line is missing, the iOS client never POSTed — most likely cause
is the account-age guard (`< 3 days`). To get around it for QA:

```sql
-- one-time fudge for testing only; revert after
update profiles
   set created_at = now() - interval '7 days'
 where id = auth.uid();
```

---

## Step 4 — Dismiss flow (verification step 4)

1. On the card, tap **"tap to dismiss"**.
2. Card disappears immediately.
3. Pull-to-refresh — it should stay gone.
4. SQL Editor:
   ```sql
   select id, dismissed_at from coach_observations
    where user_id = auth.uid()
    order by created_at desc limit 5;
   ```
5. Newest row should have `dismissed_at` populated.
6. Capture both → `05_dismissed_db.png` (table editor row), `05_dismissed_sql.txt`
   (query output).

---

## Step 5 — Dedup behavior (verification step 5)

Without changing your data:

1. Force a regenerate: kill + relaunch the app, switch to Tracker,
   pull-to-refresh, wait a few seconds, refresh again.
2. SQL Editor:
   ```sql
   select id, pattern_kind, pattern_subject, dismissed_at, created_at
     from coach_observations
    where user_id = auth.uid()
    order by created_at desc;
   ```
3. **No new active row** should have been created with the same
   `(pattern_kind, pattern_subject)` as the dismissed one within the
   last 7 days. The dedup-by-subject guardrail in
   `CoachObservationService.generateIfNeeded` should have skipped the
   model round-trip.
4. Capture SQL output → `06_dedup_sql.txt` and confirm in
   the report whether duplicates were avoided.

To explicitly test dedup is working, check the iOS console for the
debug line `[CoachObs] skip generate — N prior observation(s) for
<kind>:<subject>` — that's the smoking gun.

---

## Step 6 — Coach preferences (verification step 6)

1. Profile tab → tap the new **Coaches** row (it should read
   "Tap to star your favorites" if zero are starred).
2. Tap two stars (e.g., "Albert Einstein", "Marie Curie"). Each
   tap should ripple a small saving spinner then fill the star.
3. SQL Editor:
   ```sql
   select preferred_coaches from profiles where id = auth.uid();
   ```
   Expected: `{Albert Einstein,Marie Curie}` in the order tapped.
4. Capture iOS view + SQL → `07_preferences_view.png` and
   `07_preferences_sql.txt`.
5. Run 5 analyses (real or curl) over the next few minutes. Tally
   the `coach` field in each response. Over 5 samples, the two starred
   names should appear together more often than ~20% of the time
   (uniform random would be 20% for any single name; the 3:1 weight
   gives starred names ~46% combined).

This is statistical, not deterministic — note the actual tally in the
verification report.

---

## Step 7 — Account-age guard (verification step 7)

Two ways to test:

**Option A (clean)** — sign in with a brand-new account, save 2
meals (different days if possible). Patterns card may not fire (need
3+); the **observation card** definitely should not. Capture a
screenshot of Today with no card → `08_account_age_guard.png`.

**Option B (faster, requires SQL)** — on your existing account:
```sql
update profiles
   set created_at = now() - interval '1 day'
 where id = auth.uid();
```
Pull-to-refresh Today; observation should be skipped (and you'll see
`[Tracker] skip generate — account age 1 < 3 days` in the iOS console).
Then revert:
```sql
update profiles
   set created_at = now() - interval '14 days'
 where id = auth.uid();
```
and confirm the card returns on the next refresh.

---

## Step 8 — RLS isolation (verification step 8)

In the SQL Editor, signed in as your account (anon-equivalent role,
RLS enforced):

```sql
select user_id, coach_name, body, created_at
  from coach_observations
 order by created_at desc
 limit 10;
```

Every `user_id` returned must equal `auth.uid()`. To prove isolation,
copy a row's id and try:

```sql
-- Should return zero rows when run as a different signed-in user.
select * from coach_observations where id = '<paste-id-here>';
```

Capture both outputs → `09_rls_check.txt`.

---

## Hand-back checklist

Reply with:

- [ ] `00_migration_check.txt`
- [ ] `01_curl_no_context.json` (3 samples)
- [ ] `02_curl_with_context.json` (3 samples)
- [ ] `03_analyze_with_context.png` + `03_analyze_server_log.txt`
- [ ] `04_observation_card.png`
- [ ] `05_dismissed_db.png` + `05_dismissed_sql.txt`
- [ ] `06_dedup_sql.txt`
- [ ] `07_preferences_view.png` + `07_preferences_sql.txt` + tally of
      coach picks across 5 analyses
- [ ] `08_account_age_guard.png`
- [ ] `09_rls_check.txt`
- [ ] Anything that didn't behave as described above

I'll fold these into `PHASE_16_VERIFICATION.md` and Phase 17 starts
once at least step 3 (the card has actually appeared on a populated
account) is confirmed.
