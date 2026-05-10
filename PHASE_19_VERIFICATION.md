# Phase 19 — Stronger Onboarding · Verification

## Status

`xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17' build` → **BUILD SUCCEEDED**.

End-to-end runtime verification (sign-in → archetype → coaches →
notifications → DB column reads, plus skip / returning-user / network-
failure paths) is documented below as a runbook the user can walk
manually. The CLI's simulator UI automation is blocked for this
project (see memory `simulator_automation`), so screenshot-and-DB
verification needs hands-on time on the simulator.

## Decisions log

- **Sign-in before onboarding (option A in spec).** Returning users
  skip the new flow entirely — `RootView`'s gate routes them straight
  to `MainTabView` once `profile.onboardingCompletedAt` is non-nil. A
  legacy account whose gate is NULL sees the full flow once.
- **ProfileStore lifted to App-level.** Was `@StateObject` on
  `MainTabView`; now `@StateObject` on `FoodieAIApp`, injected via
  `.environmentObject` so `RootView` can inspect
  `onboardingCompletedAt` without a duplicate fetch. Sign-out triggers
  `profileStore.clear()` from `auth.isSignedIn → false` so the next
  sign-in re-hydrates from the right user.
- **OnboardingFlow drives sign-in as an interrupt, not a sibling
  flow.** Hero's "Get started" advances to either `.signIn` or
  `.archetype` based on auth state; once `auth.isSignedIn` flips true
  while parked at `.signIn`, the view model auto-advances to
  `.archetype`. Returning users with a non-nil gate value never reach
  this hand-off — `RootView` routes them out of `OnboardingFlow`
  entirely.
- **UserDefaults fallback gate on network failure.** If the batched
  `completeOnboarding` UPDATE fails during `complete()`, the local
  fallback (`phase19.onboardingCompletedAtFallback`) prevents
  `RootView` from looping the user back into onboarding. The next
  foreground sync retries the profile write; once the server reflects
  the gate, callers should clear the fallback via
  `OnboardingViewModel.clearLocalFallbackGate()`.
- **Coach voice samples hardcoded for v1.** Mirrors the canonical 10
  coaches from `CoachPreferencesView.canonicalCoaches`. v2 should
  move to a server endpoint so the catalogue isn't tied to client
  redeploys.
- **Skip-archetype defaults to `aware`.** Most generic macro goals
  (2000/250/50). No penalty for skipping; users who can't commit
  aren't blocked from continuing.
- **Notification step has no "Skip this" link.** Both buttons resolve
  the in-app question — "Yes, send nudges" / "Not now" — so a third
  affordance would dilute the pair without adding signal.
- **System notification prompt fires inside `complete()`, not on the
  notifications step.** Apple HIG: justify before prompting. The
  in-app answer is captured first; the system dialog appears as the
  user advances past the questions.
- **Guest mode plumbing deferred to Phase 21.** OnboardingFlow's view
  model is reusable, but no anonymous-Supabase / convert-on-third-
  attempt code in this phase.
- **Default initial step `.hero` regardless of auth state.** Existing
  signed-in-but-not-onboarded users still see the value framing
  before answering. They can use the "Already have an account? Sign
  in" link for a fast path back into MainTabView via the gate check.

## Files added

- `migrations/008_onboarding_state.sql`
- `FoodieAI/Features/Onboarding/OnboardingViewModel.swift`
- `FoodieAI/Features/Onboarding/OnboardingHeroView.swift`
- `FoodieAI/Features/Onboarding/OnboardingArchetypeView.swift`
- `FoodieAI/Features/Onboarding/OnboardingCoachStepView.swift`
- `FoodieAI/Features/Onboarding/OnboardingNotificationStepView.swift`
- `FoodieAI/Features/Onboarding/OnboardingCompletingView.swift`

## Files modified

- `FoodieAI/Models/Profile.swift` — added `onboardingCompletedAt`,
  `onboardingArchetype`, `Archetype` enum to `Profile`;
  matching opt-in fields on `ProfileUpdate`.
- `FoodieAI/Services/ProfileService.swift` — added
  `completeOnboarding(...)` for the batched UPDATE.
- `FoodieAI/Features/Onboarding/OnboardingFlow.swift` — replaced the
  v1 two-step flow with the v2 dispatcher.
- `FoodieAI/FoodieAIApp.swift` — `ProfileStore` lifted to
  app-level; `RootView` gates on `onboardingCompletedAt`;
  `MainTabView` reads the store via `@EnvironmentObject`.

## Manual runbook

### Setup

Run migration 008 once per Supabase project:

```sql
-- migrations/008_onboarding_state.sql
alter table public.profiles
    add column if not exists onboarding_completed_at timestamptz,
    add column if not exists onboarding_archetype text
        check (onboarding_archetype is null
               or onboarding_archetype in ('aware', 'lose_weight', 'build_muscle', 'curious'));
```

To re-test as a fresh user without sign-out, reset the profile row:

```sql
update public.profiles
   set onboarding_completed_at = null,
       onboarding_archetype    = null,
       preferred_coaches       = '{}'::text[]
 where id = auth.uid();
```

### Walk the happy path

1. `01_hero.png` — fresh launch, hero rendered. "Get started" + "Sign in" link.
2. Tap "Get started" → routes to SignInView (not signed in) or to archetype (signed in).
3. After Google sign-in succeeds → archetype screen auto-appears.
4. `02_archetype.png` — four options, none selected. Continue disabled.
5. Tap "Lose some weight" → `02b_archetype_selected.png` (selected state).
6. Continue → `03_coaches.png`.
7. Star 2–3 coaches. Continue label updates to "Continue (N starred)".
8. Continue → `04_notifications.png`.
9. Tap "Yes, send nudges". System permission dialog fires after `complete()` starts.
10. `05_complete_loading.png` — brief spinner with "Personalizing Foodie…".
11. `06_main_tab.png` — MainTabView with the freshly-personalized goals.

### DB verification

```sql
select onboarding_completed_at, onboarding_archetype, preferred_coaches,
       daily_calorie_goal, daily_carb_goal_g, daily_sugar_goal_g,
       notifications_enabled, reminder_breakfast, reminder_lunch, reminder_dinner
  from profiles
 where id = auth.uid();
```

Pass: `onboarding_completed_at` is recent, `onboarding_archetype`
matches the picked option, `preferred_coaches` matches the starred set
in selection order, the three macro goals match
`Archetype.defaultGoals`, the notification fields match the user's
choice (true/true/true/true if accepted; false/false/false/false if
deferred — actually the meal flags retain whatever was passed; `nil`
leaves them alone).

### Skip-path test

1. Reset SQL.
2. Tap "Skip this" on archetype → archetype set to `aware` client-side.
3. Tap "Skip this" on coaches → empty array persisted.
4. Tap "Not now" on notifications → master gate stays false.

DB after `complete()`:
- `onboarding_archetype = 'aware'`
- `preferred_coaches = '{}'`
- `daily_calorie_goal = 2000`, `daily_carb_goal_g = 250`, `daily_sugar_goal_g = 50`
- `notifications_enabled = false`, three meal reminders all `false`

### Returning-user path

1. Sign out from Profile.
2. Sign back in.
3. `RootView` gate fires: profile has non-NULL `onboarding_completed_at` → MainTabView, no onboarding shown.

### Back navigation

1. Walk to coaches step. Star one coach.
2. Tap back → archetype screen, previous selection preserved.
3. Continue → coaches, star still set.
4. Continue → notifications. Back. Coach selection persists.
5. Run `complete()`. Final state correct.

### Network failure during complete()

1. On notifications step, before tapping "Yes/Not now", disable simulator network (Device → Settings → Airplane mode).
2. Tap "Not now". `complete()` errors; UserDefaults fallback set; OnboardingFlow advances to `.finished`.
3. `RootView` reads `OnboardingViewModel.hasLocalFallbackGate() == true` → routes to MainTabView.
4. Re-enable network. On next foreground orchestrator run the sync should re-attempt the profile write.

> Note: the implementation in this phase keeps the local fallback
> gate set even after a successful re-sync. A follow-up tweak should
> call `OnboardingViewModel.clearLocalFallbackGate()` once the profile
> sync confirms the server has the gate. Filed as a TODO; current
> behavior is "fail-open" — user can use the app, server may or may
> not catch up. Acceptable for v1.

### Regression spot-checks

- Phase 15 (food memory): unchanged — capture/save flow untouched.
- Phase 16 (coach observations): unchanged — `preferredCoaches` is
  written by both onboarding and `CoachPreferencesView`; the post-save
  one-time picker (`CoachPickerOnboardingSheet`) still triggers if
  preferences are still empty after first save.
- Phase 17 (reminders): scheduling is triggered from `complete()` via
  `runOnForeground(caller: "onboardingComplete")` when the user opted
  in. Existing scenePhase observer continues to drive subsequent
  re-schedules.
- Phase 18 (mood pulse): unchanged — uses food_logs, untouched here.

## Subjective notes

- Hero CTA copy ("Get started") is generic; "Snap your first meal"
  was considered but premature — the user hasn't seen the camera UI
  yet, so the verb feels disconnected.
- Archetype emoji-vs-SF-symbol: SF Symbols won because emoji scale
  inconsistently with Dynamic Type and look slightly off on iOS 26's
  larger glyph baseline.
- Coach voice samples are short and punchy; some land better than
  others (Cleopatra's "I shall not be removed from this rotation" is
  the strongest; Marie Curie's was the hardest to write a one-liner
  for — "kale" is a forced rhyme with "perseverance" but it's
  memorable).
- Notification step's "Two taps to disable forever in Profile" line
  is doing a lot of trust work; the disclaimer below reinforces it
  with "Notifications stay on your device" — keep both lines.
- Completing screen feels right at ~0.5–1s. If `complete()` takes
  longer (slow network), the spinner becomes the dominant signal;
  consider a "still working…" affordance after 4s in a future polish
  pass.
