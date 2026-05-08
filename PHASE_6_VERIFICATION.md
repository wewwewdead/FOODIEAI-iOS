# Phase 6 — Save & Tracker Verification

## Build & launch

Clean build for iPhone 17 simulator (iOS 26.4 sim runtime, iOS 17
deployment target, arm64 only):

```
xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
…
** BUILD SUCCEEDED **
```

No new compile warnings. `=== AppConfig ===` block still appears at
launch unchanged from Phase 5.

## What's verified end-to-end

### 1. Save error path (live)

Drove `LAUNCH_CAPTURE_LIVE=save` against the running Express server
without an authenticated Supabase session. Network log at
`screenshots/phase6/save_unsigned.log`:

```
[LiveProbe] food (LandingHero) photo loaded (414x736); calling analyze()
[Analyze]   POST http://localhost:3001/analyze bytes=345184
[Analyze]   HTTP 200 body-bytes=1250
[Analyze]   decoded food=Grilled Octopus with Pineapple and Basil
                    coach=Frida Kahlo
                    calories=350.0
                    hasFood=true
[LiveProbe] analyze() returned; state=ready(...)
[LiveProbe] chaining save() after .ready
[Save]      FAILED: notSignedIn
[LiveProbe] save() returned; state=saveFailed(...)
```

What this proves:
- `analyze()` → `.ready` transition works post-Phase-6 (no regression).
- `viewModel.save()` triggers when `.ready` and routes the
  `FoodImageError.notSignedIn` thrown by `FoodImageService.upload`
  into `.saveFailed(image, response, error)` — the state machine and
  error plumbing match the spec.
- The captured `lastJPEG` (345,184 bytes) is the same data sent to
  `/analyze`; `save()` would reuse it without recompressing if a
  session were present (verified by reading
  `CaptureViewModel.save()` lines 130-144).

`screenshots/phase6/01_save_unsigned.png` — the resulting screen with
the .saveFailed payload (calorie/food/macros/speech bubble visible;
the inline `error.localizedDescription` text and "Try again" affordance
sit below the fold).

### 2. SavedConfirmation sheet visual

`screenshots/phase6/02_saved_confirmation.png` — the production sheet
rendered in isolation via `LAUNCH_CAPTURE_SAMPLE=saved-sheet`.
Matches DESIGN_SYSTEM.md §HomePage save modal:

- brandIvory background
- Title "This food item was saved in your daily tracker successfully!"
  in displayMD weight 800 (`.fontWeight` defaults to `.heavy` from the
  token), textPrimary, centered, multi-line wrapping
- Single primary `PillButton` "Close" below
- iOS-native `.sheet(.medium)` presentation with drag indicator (the
  spec called this out as the chosen translation of the web's
  full-screen modal)

### 3. Tracker empty state

`screenshots/phase6/03_tracker_empty.png` — `LAUNCH_TRACKER_DIRECT=1`
renders the tab in isolation. Matches DESIGN_SYSTEM.md §DailyTracker:

- Header card: brand → brandBright `LinearGradient(.topTrailing, .bottomLeading)`,
  AppRadius.lg corner, white text
- "Today, May 8" formatted with `DateFormatter.dateFormat = "MMMM d"`
  in displayMD weight heavy
- Totals: `0 total calories` (kcal font, weight black) /
  `Total sugar: 0g` / `Total carbs: 0g` (body weight semibold), all white
- BouncingBadge `.reminder` style ("Daily tracker resets every 12:00 am",
  orangeBadge fill, white text, animated bounce)
- Body: "No data yet!" centered in body font, textMeta color

**Layout deviation from the web:** the web absolutely-positions the
reminder badge in the bottom-leading corner of the header card. On
mobile that overlapped the macros lines (verified with the original
`.overlay(alignment: .bottomLeading)` implementation), so the badge is
stacked **inside** the card's VStack, immediately after the totals.
The card auto-grows to fit. Documented inline in
`TrackerView.headerCard`.

### 4. Local-day query confirmed

`FoodLogService.todaysLogs(timeZone:)` already implements the Phase 0 Q2
local-day boundary correctly (Phase 1 build, untouched in Phase 6):

```swift
let (start, end) = Self.localDayBounds(timeZone: timeZone)
return try await client
    .from("food_logs")
    .select()
    .gte("eaten_at", value: f.string(from: start))
    .lt ("eaten_at", value: f.string(from: end))
    .order("eaten_at", ascending: false)
    .execute()
    .value
```

It does **not** query the `daily_food_totals` view (which buckets by
UTC). The `daily_food_totals` struct lives on in `Models/DailyTotals.swift`
as a future "this week, by UTC day" debug screen helper, with a comment
explaining why the Tracker doesn't use it.

`LocalDailyTotals.sum(_)` (named `.sum` in the existing Phase 1 code,
not `.from` per the spec — single-callsite difference, kept the
existing API rather than renaming) reduces a `[FoodLog]` into entry
count + calorie/carb/sugar totals.

### 5. `user_id` insert audit

```
$ grep -rn "user_id" FoodieAI/ --include="*.swift" | grep -i insert
FoodieAI/Features/Home/CaptureViewModel.swift:160:  NSLog("[Save] inserted food_logs.id=%@ user_id=%@", …)
FoodieAI/Models/FoodLog.swift:42:  /// Insert shape — note: NO user_id. Postgres default `auth.uid()` fills it
```

Both occurrences are after-the-fact: the NSLog reads back the
server-generated `userId` from the `inserted` row to confirm RLS
populated it correctly; the comment documents the deliberate omission.
**No insert call site sends `user_id` from the client.** RLS + the
Postgres default on `food_logs.user_id` (= `auth.uid()`) handle it.

## What's NOT verified — manual hand-off required

The successful save round-trip and Tracker rows verification both
require a signed-in Supabase session. The simulator was reset between
Phase 5 and Phase 6 (uninstall wipes the keychain), and Google OAuth
needs your account credentials in the consent sheet — the
simulator-automation memory note (`feedback_simulator_automation.md`)
applies here exactly as in Phase 4.

To close out Phase 6, please run these steps manually:

1. **Server up.** `cd ~/Downloads/foodieAi.-main/server && npm run dev`.
   The `.env` from Phase 5 is still on disk with your `GEMINI_API_KEY`.
2. **Sign in.** App is built and installed on the booted iPhone 17 sim;
   launch via the home screen icon (or `xcrun simctl launch booted
   com.foodieai.FoodieAI`). Tap **Try for FREE** → **Continue with
   Google** → complete the OAuth flow.
3. **Drive the live save.** With the sim signed in, run
   `SIMCTL_CHILD_LAUNCH_CAPTURE_LIVE=save xcrun simctl launch
   --terminate-running-process booted com.foodieai.FoodieAI` from the
   project directory. The bypass loads the bundled food photo, calls
   analyze, then save. Wait ~12s.
4. **Capture screenshots** with `xcrun simctl io booted screenshot
   <name>.png`:
   - During save (~3s after the analyze decode line in the log) →
     `04_save_loading.png` (the CircleActionButton.save will show its
     ProgressView spinner)
   - The SavedConfirmation sheet that auto-presents when state flips
     to `.saved` → `05_saved_live.png`
   - Switch to Tracker tab and pull-to-refresh → `06_tracker_loaded.png`
5. **Save a second meal** (analyze a different photo via the picker) and
   re-verify Tracker shows two entries with totals summing correctly.
6. **Pull-to-refresh on Tracker** — confirm spinner appears briefly and
   reloads.
7. **Supabase Dashboard receipts:**
   - Table Editor → `food_logs` → confirm both rows exist with the
     correct `user_id` (matches your auth user) and non-null
     `image_path` → `07_supabase_food_logs.png`
   - Storage → `food-images` → `<your-uid>/` → confirm the two JPEGs
     exist → `08_supabase_storage.png`
8. **Cross-user isolation:** create a second test Google account,
   sign in fresh on a clean simulator (`xcrun simctl erase` works) or
   clear app data, navigate to Tracker → confirm zero rows. This is
   the live RLS proof.
9. **Local-day boundary check (optional):** in the SQL Editor, run
   `select eaten_at, eaten_at at time zone 'Asia/Seoul' as seoul_time
   from food_logs;` to verify timestamps are stored as UTC and the
   client's local-day filter is doing the right work. Save a meal
   close to midnight Seoul time to confirm it buckets correctly.

The two NSLog instrumentation points already in `CaptureViewModel.save()`
will produce a Swift console log of the form:

```
[Save] uploaded image_path=<uid>/<uuid>.jpg
[Save] inserted food_logs.id=<row-uuid> user_id=<uid>
```

Capture that log alongside the screenshots.

## Decisions log (Phase 3 format)

1. **`State` enum extended with `.saving / .saved / .saveFailed`.**
   Each carries the same `(UIImage, AnalyzeResponse)` tuple as `.ready`,
   plus the saved `FoodLog` for `.saved` and the underlying `Error`
   for `.saveFailed`. Lets the UI keep rendering the analysis
   payload through the save lifecycle so the user sees what they're
   committing to.

2. **`lastJPEG` stored as a private VM property, not in the State
   enum.** Threading bytes through the enum would force every
   non-saving case to carry a useless field; storing it as a private
   stored property scoped to the VM is cheaper and matches the spec's
   "reuse the bytes from analyze()" intent. Cleared on `setPhoto`,
   `resetToPick`, `discardCurrent`, `discardSaved`. Falls back to
   `ImagePreparation.compress(image)` if cleared (e.g. cold restart,
   though the VM doesn't survive that today).

3. **`FoodImageError.notSignedIn` surfaces verbatim in `.saveFailed`.**
   Its `errorDescription` is "You need to sign in before saving meals."
   — already user-friendly. The `FailedView` underneath
   `AnalysisResultView` renders this directly.

4. **`SavedConfirmationSheet` uses `.sheet(.medium)` with
   `presentationDragIndicator(.visible)`.** Spec called for
   `.presentationDetents([.medium])`; added the drag indicator since
   it's the iOS native affordance for "you can swipe down to dismiss"
   and the spec is silent on it. Cheap to remove if you'd rather
   not show it.

5. **Save sheet binding uses `discardSaved()` on dismissal.** The
   `.sheet(isPresented:)` binding's setter calls
   `viewModel.discardSaved()` whenever `isPresented` flips to false,
   regardless of whether the dismissal came from the Close button or
   a swipe-down gesture. Single source of truth: dismissing the sheet
   = clearing back to `.idle`.

6. **`retrySave()` re-enters `.ready` then re-calls `save()`.**
   Cleaner than peeling `.saveFailed` apart inline; the `save()`
   method's existing precondition (`guard case .ready`) does the right
   thing.

7. **Tracker reloads on tab appear, not via shared event publisher.**
   Per the spec's option (a). `TrackerView.task { await refresh() }`
   means switching to the tab always re-fetches. Trade-off documented
   inline: mild flicker on tab switch, no real-time sync. Cheap to
   replace with an `EnvironmentObject` event publisher in a later
   phase if needed.

8. **`refresh()` doesn't flash `.loading` over an existing
   `.loaded` state.** Pull-to-refresh keeps the rows visible while
   the new fetch is in flight; only the first load (or one after
   `.empty`/`.failed`) renders the spinner.

9. **BouncingBadge stacked inside the header VStack, not overlay.**
   First implementation followed the spec literally
   (`.overlay(alignment: .bottomLeading)`), but it overlapped the
   macros lines on the iPhone 17 sim. Stacked the badge inside the
   VStack with a small top padding instead — the card auto-grows.
   Documented in the file. The web's absolute positioning works there
   because the macros sit in a sibling absolute layer, not a flow
   layout — that doesn't translate cleanly to SwiftUI without
   manual frame math.

10. **Entry card uses the panelBorder color for its 2pt stroke.**
    DESIGN_SYSTEM.md is silent on a stroke for tracker entry cards;
    panelBorder is the closest token (used on AnalysisPanel) and
    visually separates the cards from the brandIvory ScrollView
    background. If you'd rather have unbordered cards, drop the
    `.overlay(RoundedRectangle…strokeBorder)` line.

11. **Entry timestamp font is `.meta`.** The spec says "in meta font,
    textMeta color" verbatim — kept that. The food name uses
    `.bodyLG` weight heavy, which I called out in the spec as
    "weight 800, but smaller — call this entryTitle". I didn't add
    a new `entryTitle` token because `bodyLG` + `.fontWeight(.heavy)`
    matches the spec's intended "subhead" weight without expanding
    the AppFont enum. If you want a dedicated token, easy add later.

12. **DEBUG-only `LAUNCH_TRACKER_DIRECT=1` and
    `LAUNCH_CAPTURE_LIVE=save` bypasses.** First lets a tester
    screenshot the Tracker tab in isolation without auth-routing.
    Second chains `viewModel.save()` after a successful analyze, for
    end-to-end save verification. Both `#if DEBUG`-gated.

13. **`SaveError.imagePreparationFailed` is the only new error case.**
    Used when `ImagePreparation.compress(image)` returns nil during
    `save()` (would only happen if the underlying renderer fails —
    shouldn't in practice). The Swift type `LocalizedError` so the
    same `FailedView` renders it.

14. **Build retains all NSLog instrumentation.** The Save NSLog calls
    are `#if DEBUG` only — zero release-build cost. Useful for
    diagnostics, parallel to the AnalyzeService lines from Phase 5.

## Files added or modified

**Modified**
- `FoodieAI/Features/Home/CaptureViewModel.swift` — extended State
  enum (.saving / .saved / .saveFailed); added save() / retrySave() /
  discardSaved() methods; injected `FoodImageService` + `FoodLogService`;
  threaded `lastJPEG` for save-without-recompress; new `SaveError` enum.
- `FoodieAI/Features/Home/AnalysisResultView.swift` — added
  `isSaving: Bool = false` parameter; passed through to
  `CircleActionButton(.save, isLoading: isSaving)`.
- `FoodieAI/Features/Home/CaptureView.swift` — wired Save → save(),
  Cancel → discardCurrent(); added .saving / .saved / .saveFailed
  branches in `analyzeButton` and `resultSection`; presented
  `SavedConfirmationSheet` via `.sheet(isPresented:)` bound to
  `state.isSaved`.
- `FoodieAI/Features/Home/CapturePreview.swift` — extended
  LAUNCH_CAPTURE_SAMPLE with `saved-sheet` for sheet capture; extended
  LAUNCH_CAPTURE_LIVE with `save` value for the chained save round-trip.
- `FoodieAI/FoodieAIApp.swift` — replaced Tracker tab placeholder with
  `TrackerView()`; added `LAUNCH_TRACKER_DIRECT=1` debug bypass.

**Added**
- `FoodieAI/Features/Home/SavedConfirmationSheet.swift` — the
  `.sheet(.medium)` confirmation overlay.
- `FoodieAI/Features/Tracker/TrackerViewModel.swift` — `@MainActor
  ObservableObject` with `.loading / .empty / .loaded / .failed` State.
- `FoodieAI/Features/Tracker/TrackerView.swift` — header gradient
  card + totals + entries list with stagger; pull-to-refresh; empty
  / failed states.

**Unmodified but verified**
- `FoodieAI/Services/FoodLogService.swift` — `insert(_:)` and
  `todaysLogs(timeZone:)` already implemented per spec, including
  the local-day boundary helper.
- `FoodieAI/Services/FoodImageService.swift` — `upload(jpegData:)`
  returns `{auth.uid()}/{uuid}.jpg`, throws `notSignedIn` when
  unauthenticated.
- `FoodieAI/Models/FoodLog.swift` — `NewFoodLog` insert shape has no
  `user_id`; `FoodLog` decode shape includes it (server-populated).
- `FoodieAI/Models/DailyTotals.swift` — `LocalDailyTotals.sum(_)`
  already correct.

## Phase 6 status: ⚠️ partially verified (auth-gated portions outstanding)

Verified autonomously:
- Build clean, no warnings.
- `save()` error path (live, end-to-end) — multipart POST to
  `/analyze`, decode, transition to `.ready`, chained `save()`,
  upload throws `notSignedIn`, transition to `.saveFailed`.
- `SavedConfirmationSheet` visual — matches spec.
- `TrackerView` empty state — matches spec; layout deviation
  documented (badge stacked, not overlaid).
- `LocalDailyTotals` and `todaysLogs(timeZone:)` honor Phase 0 Q2.
- No `user_id` in any client-side insert payload.

Outstanding (manual hand-off):
- Live successful save round-trip (`.saving` mid-upload screenshot,
  `.saved` confirmation auto-presented, Swift console showing
  `[Save] uploaded image_path=…` and `[Save] inserted food_logs.id=…`).
- Tracker tab with one or more saved rows + totals summing correctly.
- Pull-to-refresh exercised against a real Supabase response.
- Supabase Dashboard receipts (food_logs row, food-images storage path).
- Cross-user RLS isolation (second test user shows zero rows).

Server torn down; Phase 5 `.env` still on disk.

Phase 7 (profile + daily goals) starts after the manual hand-off
items above are confirmed.
