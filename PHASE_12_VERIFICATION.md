# Phase 12 — Image Normalization & Egress Reduction Verification

## Scope

A two-tier change to the image storage path:

1. **Smaller main images.** The `/analyze` upload and the Storage main
   object both drop from 2048px / 0.80 quality to **1024px / 0.70**
   (~80–150 KB target, down from ~350 KB).
2. **Paired thumbnail.** Each save now uploads a sibling 256px / 0.60
   JPEG (~10–25 KB) under the same per-meal `imageId`, with an
   `_thumb.jpg` suffix. Its path is stored in a new
   `food_logs.image_thumb_path` column.

Pre-Phase-12 rows have NULL `image_thumb_path`; `MealRow` falls back to
the main path for those, so legacy meals continue to render — slightly
wasteful but harmless and tapers off as users save new meals.

## Build

Clean build, iPhone 17 Pro simulator, iOS 26.4 sim runtime:

```
** BUILD SUCCEEDED **
```

No new compiler warnings. The deprecated `FoodImageService.upload(jpegData:)`
is annotated `@available(*, deprecated, …)` but still compiles; nothing
in the project calls it post-Phase-12.

## Migration

Created `migrations/002_food_logs_thumb_path.sql`:

```sql
alter table public.food_logs
    add column if not exists image_thumb_path text;
```

**User must run this in Supabase SQL Editor before testing the live
save flow.** With the column missing, the iOS save path will fail with
a Postgres "column does not exist" error — the new `NewFoodLog` payload
includes `image_thumb_path`.

After running, confirm via Table Editor that `image_thumb_path` appears
under `food_logs`, nullable, default NULL.

## Files modified

### Migration (1)

- `migrations/002_food_logs_thumb_path.sql` (new)

### iOS (5)

| File | Change |
|------|--------|
| `Models/FoodLog.swift` | Added `imageThumbPath: String?` to both `FoodLog` (read shape) and `NewFoodLog` (insert shape), with matching `image_thumb_path` `CodingKey`. |
| `Services/ImagePreparation.swift` | Two new presets: `compressMain` (1024 / 0.70) and `compressThumbnail` (256 / 0.60). The underlying `compress(_:maxLongEdge:quality:)` lost its default values — call sites must pick a preset. |
| `Services/FoodImageService.swift` | New `uploadMealImages(mainData:thumbnailData:) async throws -> UploadedImage` runs the two uploads concurrently via async-let under a shared `imageId`. Old `upload(jpegData:)` retained but `@available(*, deprecated, …)`. New `UploadedImage` value type carries the two paths. |
| `Features/Home/CaptureViewModel.swift` | `analyze()` now calls `compressMain` (was the legacy 2048/0.8 default). `save()` is the new dual-write path: regenerate main + thumb from the in-memory `UIImage`, paired-upload, insert with both paths. Dropped the `lastJPEG` cache — bytes aren't reused across analyze→save anymore. New `[Save] mainBytes=… thumbBytes=…` and `[Save] uploaded main_path=… thumb_path=…` log lines. |
| `Core/Components/MealRow.swift` | `loadThumbnail()` uses `log.imageThumbPath ?? log.imagePath` so Phase 12 rows load the small object and pre-Phase-12 rows fall back to the main object. The `#Preview` `FoodLog(...)` constructor was updated to pass `imageThumbPath: nil`. |

### Untouched

- `AnalyzeService.swift` — receives bytes, doesn't care about size.
- `FoodLogService.swift` — schema-agnostic, just SELECT/INSERT.
- `AnalysisResultView.swift` — already renders from in-memory `UIImage`,
  not Storage.
- All Tracker views (Today / Week / Month / DayDetailSheet) — they
  consume `MealRow`, which transparently picks up the thumb path.

## Decisions log

### 1. Save-path recompresses from `UIImage`, not from cached analyze bytes

The previous flow cached the analyze-time JPEG in `lastJPEG` and reused
it on save. After Phase 12 we regenerate both `compressMain` *and*
`compressThumbnail` fresh from the in-memory `UIImage`.

**Why:** the thumbnail must be derived from the same source pixels as
the main image to look right. Regenerating only the thumb from a
re-decoded JPEG would compound JPEG artifacts. Regenerating both from
the original UIImage costs one extra `compressMain` pass on save (a few
hundred milliseconds on-device) but gives a clean thumb. Memory cost is
trivial because the `UIImage` is already retained in the `.ready`
state.

The trade-off is that the analyze-upload bytes and the storage-upload
bytes can differ slightly (different render passes can yield different
JPEG output even at identical settings). This doesn't matter — neither
side compares them.

### 2. Concurrent paired upload, no rollback on partial failure

`uploadMealImages` runs both uploads concurrently via async-let. If one
fails, `try await (mainUpload, thumbUpload)` re-throws. We don't try to
delete the surviving object before propagating the error, because:

- The `food_logs` row hasn't been inserted yet at this point, so the
  orphaned object isn't referenced anywhere.
- Storage cost is negligible compared to egress; orphan accumulation in
  failure cases isn't a real problem.
- A "compensating delete" path adds complexity and risks compounding a
  transient failure with a second one.

If orphan accumulation becomes measurable, a periodic Storage sweep
(`select image_path, image_thumb_path from food_logs` minus the
bucket's listing) is a cleaner solution than client-side rollback.

### 3. Quality settings: kept the spec defaults; no bumps

Per Step 8 we should run a Gemini-accuracy spot-check before bumping
`compressMain` to 0.75 / 1280px and a thumbnail visual check before
bumping `compressThumbnail` to 0.70. I did not run those checks from
this CLI session — they require the live save flow, a captured photo,
and visual judgment. **The settings are still at the spec defaults
(1024 / 0.70 main, 256 / 0.60 thumb).** Manual checklist below covers
the bump path if the user finds either is too aggressive.

### 4. Path layout: `{userId}/{imageId}.jpg` and `{userId}/{imageId}_thumb.jpg`

Both objects live in the same per-user folder, with a shared `imageId`
that lets you eyeball pairs in the bucket browser. The `_thumb.jpg`
suffix means a sorted listing keeps each pair adjacent (the suffixed
file sorts after the unsuffixed one).

The storage RLS policy from Phase 0 (`(storage.foldername(name))[1] =
auth.uid()::text`) cares only about the leading folder segment, which
is the user UUID for both paths — no policy change needed.

### 5. Pre-Phase-12 fallback in `MealRow`

```swift
let path: String? = log.imageThumbPath ?? log.imagePath
```

Three paragraphs of comment in the source explain the trade-off; the
short version is "load the bigger object for legacy rows, accept the
egress, don't engineer a backfill path that requires the original
image."

## Egress reduction estimate

| Operation | Before | After | Δ |
|-----------|-------:|------:|---:|
| Upload to /analyze | ~350 KB | ~115 KB | −67% |
| Upload to Storage  | ~350 KB | ~115 KB main + ~17 KB thumb = ~132 KB | −62% |
| Read in list (per row) | ~350 KB main | ~17 KB thumb | −95% |

(Bytes are typical-meal estimates: 1024×768 source, JPEG of food.)

Real egress reduction depends on read patterns. The Tracker tab loads
N thumbnails on tab-appear; assuming 5 meals/day average and a user
who opens the app a few times daily, the read path goes from
~5 × 350 KB = 1.75 MB/open to ~5 × 17 KB = 85 KB/open. Across hundreds
of users that's the dominant savings.

## Manual verification checklist

Per saved memory ("Simulator UI automation blocked"), I install +
launch + capture launch state. Starting state captured at
`screenshots/phase12/00_launch.png` (Home tab, signed in).

**Prerequisite — run `migrations/002_food_logs_thumb_path.sql` in the
Supabase SQL Editor first.** The save path will fail otherwise.

1. **Save a fresh meal.** Snap or pick → analyze → save. In the Xcode
   console, watch for two new `[Save]` log lines. Capture
   `screenshots/phase12/01_save_log.png` (or a copy of the console
   text). Expected ranges:
   - `[Save] mainBytes=…` between 80,000 and 150,000.
   - `[Save] thumbBytes=…` between 10,000 and 25,000.

2. **Storage browser.** Supabase Dashboard → Storage → `food-images` →
   your user UUID folder. Confirm the new save produced two siblings:
   - `<imageId>.jpg` (~80–150 KB).
   - `<imageId>_thumb.jpg` (~10–25 KB).
   Capture `screenshots/phase12/02_storage_browser.png`.

3. **Table Editor.** food_logs → newest row. Confirm both columns:
   - `image_path` ends in `.jpg`.
   - `image_thumb_path` ends in `_thumb.jpg` and shares the prefix.
   Capture `03_table_editor_paths.png`.

4. **Today thumbnail.** Tracker → Today. The new meal's collapsed row
   shows the thumbnail. Tap to expand to confirm everything else still
   renders. Capture `04_today_thumbnail.png`.

5. **Legacy fallback.** A pre-Phase-12 meal (saved before this phase
   shipped) loads through the fallback. Confirm the thumbnail still
   appears (it'll be the larger main image — slower first paint, but
   no broken image). Capture `05_legacy_meal_fallback.png`.

6. **Week + Month sheets.** Open a day-detail sheet from each. Meal
   rows inside the sheet show thumbnails via the same `MealRow` code
   path — they should "just work."

7. **Visual quality spot-check.** Look closely at the 80×80 thumbnail
   on a phone — food should still be recognizable. If the image is
   visibly noisy or blocky, bump `compressThumbnail` to `0.70` (still
   <30 KB on most images, slightly cleaner).

8. **Gemini accuracy spot-check.** Save a few meals with different
   food types (a banana, a salad with multiple ingredients, something
   with packaged labels). Confirm the food name + macros still look
   right. If accuracy degrades from the previous 2048/0.80 baseline,
   bump `compressMain` to `1280 / 0.75` — see `ImagePreparation.swift`,
   the bump is a one-line change in `compressMain`.

## Confirmations

- ✅ Build succeeds, no new compiler warnings.
- ✅ Migration 002 written; user must apply via Supabase SQL Editor.
- ✅ `FoodLog` and `NewFoodLog` carry `imageThumbPath` end-to-end.
- ✅ `ImagePreparation` exposes `compressMain` (1024/0.70) and
  `compressThumbnail` (256/0.60); previous `compress(_:)` default is
  removed so call sites must pick a preset (only one call site existed,
  in `CaptureViewModel`, both updated).
- ✅ `FoodImageService.uploadMealImages` runs both uploads concurrently
  with a shared `imageId`. Single-object `upload` is retained but
  deprecated.
- ✅ `CaptureViewModel.save()` regenerates main + thumb from the
  `.ready` `UIImage` and paired-uploads via `uploadMealImages`.
- ✅ `MealRow` thumbnail loader uses `imageThumbPath ?? imagePath`,
  giving Phase 12 rows the small object and pre-Phase-12 rows the main
  object as fallback.
- ✅ No backfill — pre-Phase-12 rows continue to work via the fallback.
- ✅ The post-analyze result screen still shows the in-memory `UIImage`,
  unaffected.

## Status

**Code complete.** Phase 12 is feature-complete pending:
- `migrations/002_food_logs_thumb_path.sql` applied in Supabase.
- One fresh meal saved end-to-end to verify the byte ranges and the
  paired storage objects.
- Manual visual / Gemini-accuracy spot-check; no quality bumps applied
  out of the box.

---

# Phase 12 addendum — Full-image viewer on thumbnail tap

## Scope

Tap a meal thumbnail anywhere in the app → a full-screen viewer opens,
loading the **main** (1024 px) image with native pinch-to-zoom and pan.

## Files added / modified

### Added (1)

- `FoodieAI/Core/Components/FullImageViewer.swift`
  - SwiftUI `View` presented via `.fullScreenCover` (not `.sheet` — a
    sheet's card edge fights the immersive feel and its drag-to-dismiss
    gesture interferes with pinch).
  - Loads the image via `FoodImageService.cachedSignedURL(for:)` (Phase
    9 cache, second open is faster) → `URLSession.shared.data(from:)` →
    `UIImage`.
  - Pinch / pan / double-tap-to-zoom delegated to a `UIScrollView` via
    a `UIViewRepresentable` (`ZoomableImageView`).
  - Black background, edge-to-edge; tap-outside-image dismisses.
  - Top-leading `xmark.circle.fill` close button inside `safeAreaInset`
    so it never overlaps the Dynamic Island.
  - Loading: centered `ProgressView` with white tint. Failure: centered
    `photo.badge.exclamationmark` icon + "Couldn't load image" — close
    button stays visible so the user can always exit.

### Modified (1)

- `FoodieAI/Core/Components/MealRow.swift`
  - Added `@State showFullImage` and `.fullScreenCover(isPresented:) {
    FullImageViewer(imagePath: log.imagePath ?? "") }`.
  - Refactored `collapsedRow` to split the gesture surface: the
    thumbnail is now wrapped in a `Button` whose label is the existing
    thumbnail frame; everything else (food name + meta + chevron) is a
    sibling `HStack` with `contentShape + onTapGesture` for the
    expand/collapse toggle. The two areas are non-overlapping so
    SwiftUI gesture routing is unambiguous.
  - The thumbnail Button is omitted (replaced by the bare frame) when
    `log.imagePath` is nil/empty — defensive, since saved meals
    always have a path.

## Decisions log

### A1. UIKit `UIScrollView` for pinch/pan, not pure SwiftUI

The spec offered a pure-SwiftUI gesture-composition path with a
documented limitation. I went UIKit:

- `UIScrollView`'s `viewForZooming(in:)` delegate gives free
  simultaneous pinch + pan with proper bounds clamping.
- Added double-tap-to-toggle (1× ↔ 2× centered on the tap location)
  cheaply via a `UITapGestureRecognizer` — would be substantially more
  fiddly in pure SwiftUI.
- Native deceleration / bounces / inertia, no animation tweaking.

The `UIViewRepresentable` is ~40 lines including constraints and
delegate; the SwiftUI-only equivalent for comparable feel would be
longer and brittler.

### A2. `URLSession` data fetch instead of `AsyncImage`

`AsyncImage` works fine for SwiftUI views, but the UIKit scroll view
needs a real `UIImage`. Using `URLSession.shared.data(from:)` once →
`UIImage` once is cheaper than letting `AsyncImage` decode the bytes
and then re-decoding them for the scroll view. It also gives us
explicit control over loading vs. failed state, which matters because
we still want the close button visible on failure.

### A3. Two distinct tap regions on the row, no shared gesture

The spec recommends "tap thumbnail to view full image, tap row body to
expand." The way SwiftUI gesture routing works, the cleanest way to
guarantee both work without flaky routing is to make them *spatially*
disjoint: a `Button` on the thumbnail frame, a separate `onTapGesture`
on the text+chevron HStack to its right. Removed the previous
"contentShape + onTapGesture on the whole collapsedRow" wrapper since
its hit area now overlaps the Button.

### A4. `fullScreenCover` lives on the row, not on the parent list

Each `MealRow` owns its own `showFullImage` state and presents its own
`fullScreenCover`. SwiftUI handles concurrent `fullScreenCover`s on
sibling views fine; no shared coordinator needed. The presenter chain
also works correctly inside another modal — so a row inside a
`DayDetailSheet` (itself a `.sheet`) can still present the full-screen
viewer above it. (Verified by the sheet→fullScreenCover composition
being a documented SwiftUI pattern; manual confirmation is in the
checklist.)

### A5. Pre-Phase-12 meals: same Button, larger payload

Pre-Phase-12 rows have `imagePath` populated (the legacy single-image
upload from earlier phases) so the Button is enabled and tapping it
opens that same image at full screen. The file is ~350 KB instead of
the new ~120 KB main image; first-paint is correspondingly slower but
the experience is otherwise identical.

## Manual verification (additions)

After applying the original Phase 12 checklist:

| Filename | Setup |
|----------|-------|
| `06_full_image_viewer.png` | In Today, tap a meal's thumbnail. Viewer opens full-screen with the X button visible at top-leading. The main image fills the viewport with `.scaledToFit`. |

Additional behaviors to confirm without screenshots:

- **Pinch to zoom** anywhere on the image. It scales smoothly up to 4×.
- **Drag to pan** while zoomed. Stays within image bounds.
- **Double-tap** the image. Toggles between fit (1×) and 2×, centered
  on the tap location.
- **Tap the X button.** Dismisses cleanly.
- **Tap on the black background outside the image.** Also dismisses.
- **Cache hit on second open.** First open of a meal logs
  `cachedSignedURL MISS`; closing and re-tapping the same row's
  thumbnail logs `HIT`.
- **DayDetailSheet → tap thumbnail.** The sheet stays presented in the
  background; the full-screen viewer comes up over the top. Closing
  the viewer returns to the sheet, not all the way out.
- **Pre-Phase-12 meal → tap thumbnail.** Loads the legacy main image
  (slower first paint due to larger payload) and behaves the same.
- **Row body still toggles expand.** Tapping anywhere on the food
  name / meta / chevron region expands or collapses the row; the
  thumbnail tap is independent.

## Confirmations (addendum)

- ✅ Build succeeds after regenerating the Xcode project (xcodegen
  must pick up the new file in `Core/Components/`).
- ✅ `FullImageViewer` is presented via `.fullScreenCover`, runs in
  `.preferredColorScheme(.dark)`, and uses a `safeAreaInset`-anchored
  close button.
- ✅ The thumbnail Button and the row-expand `onTapGesture` are
  spatially disjoint inside `MealRow.collapsedRow` — no overlapping
  tap surfaces.
- ✅ The viewer's signed URL goes through the existing
  `FoodImageService.cachedSignedURL(for:)`, so the Phase 9 in-memory
  cache covers repeated opens within a session.
- ✅ Loading and error states render with the close button always
  visible, so the user can never get stuck.
- ✅ `imagePath` is the input (the main 1024 px object). `imageThumbPath`
  is intentionally not used here — the viewer is the one place we
  *do* want the full-resolution object.
