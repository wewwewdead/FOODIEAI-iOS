# Account Deletion — Implementation & Verification

App Store Review Guideline 5.1.1(v) blocker. User-initiated account
deletion from the Profile tab, with a typed-phrase confirmation and
server-side cascade through every FK-referencing table.

## Files added / modified

### Server (`/Users/johnmathewloren/Downloads/foodieAi.-main/server`)
- **Added** `routes/account.js` — authenticated `DELETE /account`
  endpoint using the Supabase service-role key.
- **Modified** `server.js` — wires `accountRouter` into the express app.

### iOS (`FoodieAI/`)
- **Added** `Services/AccountDeletionService.swift` — orchestrates the
  4-step flow (fetch paths → delete storage → DELETE /account → local
  cleanup). `@MainActor`-isolated.
- **Added** `Features/Profile/DeleteAccountSheet.swift` — 4-stage UI:
  `warning` → `typedConfirmation` → `deleting` → `failed`.
- **Modified** `Features/Profile/ProfileView.swift` — adds the
  bottom-of-screen Account section + `.sheet` presentation.
- **Regenerated** `FoodieAI.xcodeproj` via `./tools/xcodegen generate`.

## Cascade audit

Schema FKs referencing `auth.users(id)` already declare
`on delete cascade` at every site:

| Table                 | Source                                           | Rule           |
|-----------------------|--------------------------------------------------|----------------|
| `profiles`            | `foodie_schema.sql:10`                           | CASCADE        |
| `food_logs`           | `foodie_schema.sql:65`                           | CASCADE        |
| `coach_observations`  | `migrations/005_coach_continuity.sql:30`         | CASCADE        |
| `weekly_recaps`       | `migrations/006_reminders_and_recaps.sql:30`     | CASCADE        |

No `restrict` / `no action` FKs exist on `user_id`, so
`auth.admin.deleteUser(user_id)` will succeed and cascade through the
full data graph.

Audit query to re-run before TestFlight:

```sql
select tc.table_name, kcu.column_name, rc.delete_rule
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
join information_schema.referential_constraints rc
  on tc.constraint_name = rc.constraint_name
where tc.constraint_type = 'FOREIGN KEY'
  and kcu.column_name in ('user_id', 'id')
  and tc.table_schema = 'public';
```

Every row should report `delete_rule = 'CASCADE'`.

## Required environment configuration

Add to Railway environment variables (and `.env` locally for the
server):

```
SUPABASE_SERVICE_ROLE_KEY=<service_role secret from Supabase dashboard>
```

(Supabase Dashboard → Project Settings → API → service_role.) Mark
secret in Railway. **Do not** add this key to `Secrets.xcconfig` —
the iOS client uses only the anon key, and the service role must
never reach a client binary.

## Decisions log

- **Confirmation phrase: `confirm delete`** — lowercase, single space,
  no quotes. Strict equality (no trim, no case-fold) keeps the gate
  intentional. Shown inline as a non-selectable pill so a user reading
  a translated UI in the future can still type the literal phrase.
- **Storage cleanup is best-effort** — partial failure logs in DEBUG
  and proceeds to the server call. An orphaned 60kB JPEG is a smaller
  harm than leaving an `auth.users` row the user believes is deleted.
- **Sign-out is the last step** — runs after `DELETE /account`
  returns 200, so `AuthService.session` going `nil` is the signal
  RootView already routes on (same path as ordinary sign-out).
- **No body in the DELETE request** — the server extracts `user_id`
  from the verified JWT via `adminClient.auth.getUser(token)`, so a
  client cannot impersonate another user even with their own token.
- **`interactiveDismissDisabled(vm.stage == .deleting)`** — the user
  cannot drag-dismiss while the deletion is in flight; on every other
  stage drag-dismiss is the right out for someone who tapped by
  mistake.
- **UserDefaults cleanup list** — explicit enumeration, no blanket
  wipe. Audited and seeded with:
  - `phase16.didSeeCoachPicker`
  - `phase17.savesSinceInstall`
  - `phase17.permissionDeferredUntil`
  - `phase17.didPresentPermissionOnce`
  - `phase19.onboardingCompletedAtFallback`
  - `phase19.onboardingArchetypeFallback`
  - `foodie.favorites.v1`
  - `foodie.loggingRhythm.v1`

  Comment in source: `// Account-deletion cleanup: keep this list in sync.`

## Verification steps (run before TestFlight submission)

⚠️ Account deletion is irreversibly destructive. **Use a throwaway
Google account, never your real one.**

### Setup
1. Create or sign in with a throwaway Google account.
2. Complete onboarding.
3. Save 3–4 meals (include photos so Storage has objects).
4. Note the `user_id` from Supabase Dashboard → Authentication → Users.

### Before deletion — record counts
```sql
select 'profiles'          as t, count(*) from profiles           where id      = '<uuid>'
union all select 'food_logs',           count(*) from food_logs           where user_id = '<uuid>'
union all select 'coach_observations',  count(*) from coach_observations  where user_id = '<uuid>'
union all select 'weekly_recaps',       count(*) from weekly_recaps       where user_id = '<uuid>';
```

In Supabase Storage → `food-images` bucket, filter by `<uuid>/`. Note
file count.

### Run the flow
- Profile → scroll to bottom → **Delete account**.
- Warning stage: confirm bullet list, tap **Continue to delete**.
- Typed stage: confirm `Delete my account` is disabled. Type
  `Confirm Delete` (wrong case) — still disabled. Type
  `confirm  delete` (double space) — still disabled. Type
  `confirm delete` exactly — button enables. Tap it.
- Deleting stage: cycle through step messages, eventually routes to
  landing screen.

### After deletion — verify
- Re-run the audit query: all four counts return **0**.
- Storage bucket: `<uuid>/` prefix has **zero** files.
- Authentication → Users: throwaway account is **not present**.
- Sign back in with the same Google account → fresh onboarding flow
  (no zombie profile row).
- `UNUserNotificationCenter` has no pending requests.

### Failure-path test (recommended)
- Temporarily point `ANALYZE_HOST` at a 404 endpoint.
- Trigger the flow on a fresh throwaway account.
- Confirm the failure stage appears with a Try again button and the
  underlying error message at the bottom.
- Restore `ANALYZE_HOST`, tap Try again, confirm completion.

## Smoke-test the server endpoint independently

```bash
# Get a JWT from a signed-in throwaway account's logs, then:
curl -X DELETE https://<railway-url>/account \
  -H "Authorization: Bearer <jwt>"
```

Expected: `{"deleted":true,"user_id":"..."}` with HTTP 200.

Then re-run the audit query and verify all counts go to 0.

## Build status

`xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI -configuration
Debug -destination 'generic/platform=iOS Simulator' build` → **BUILD
SUCCEEDED** (with one pre-existing headermap-style warning, unrelated
to this change).
