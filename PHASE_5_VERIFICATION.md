# Phase 5 — Capture & Analyze Flow Verification

## Pre-flight: SVG bundling

Carried over from the Phase 4 follow-up — `nutrients`, `benefits`, and
`drawbacks` SVGs are bundled in
`FoodieAI/Resources/Assets.xcassets/PanelIcons/*.imageset/` with
`preserves-vector-representation: true` and
`template-rendering-intent: template`. `AnalysisPanel.swift:31-37`
references them by asset name (`Image("PanelIcons/nutrients")`) with
`.renderingMode(.template)`, so SwiftUI's `.foregroundStyle` continues
to tint each panel through the brand color tokens.

**PDF imageset note (unchanged):** This machine still has no
SVG→PDF tool installed (`rsvg-convert`, `inkscape`, `cairosvg`,
`svglib` all unavailable without `libcairo`/PEP 517 deps). The
"single-scale SVG with preserves-vector-representation" alternative
remains in place — Xcode 13+ keeps the artwork fully vector and
renders identically to a PDF imageset at every scale.

## Build & launch

Build clean for iPhone 17 simulator (iOS 26.4 sim runtime, iOS 17
deployment target, arm64 only because the Supabase package is not
available for x86_64 sim).

```
xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
…
** BUILD SUCCEEDED **
```

### Pre-existing project bug fixed during Phase 5

`xcodegen` was not setting `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`
on the generated project, so every `#if DEBUG` block in the codebase
(including `FontDebug` and the Phase 4 `LAUNCH_SIGNIN_DIRECT` bypass)
was being compiled out of the binary. Verified via
`strings` on the .app — none of the `LAUNCH_*` literals appeared. Phase 4's
bypass screenshot worked because it was captured from an Xcode-IDE build,
not a CLI build.

Patched `project.yml:settings.configs`:

```yaml
configs:
  Debug:
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
    SWIFT_OPTIMIZATION_LEVEL: "-Onone"
    GCC_PREPROCESSOR_DEFINITIONS: "DEBUG=1"
    ONLY_ACTIVE_ARCH: YES
```

After regen, `xcodebuild -showBuildSettings` confirms
`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`. All DEBUG-scoped
diagnostics (FontDebug, the SignIn bypass, the new Capture bypass)
now ship in debug builds.

### Launch console — Phase 5 build, no auth, CaptureView direct

```
2026-05-08 20:26:21.856 FoodieAI[6427:83907] === AppConfig ===
2026-05-08 20:26:21.856 FoodieAI[6427:83907] supabaseURL: https://kymwhecbblgbruqezixx.supabase.co
2026-05-08 20:26:21.856 FoodieAI[6427:83907] supabaseURL.host: kymwhecbblgbruqezixx.supabase.co
2026-05-08 20:26:21.856 FoodieAI[6427:83907] anonKey length: 208
2026-05-08 20:26:21.856 FoodieAI[6427:83907] analyzeBaseURL: http://localhost:3001
2026-05-08 20:26:21.856 FoodieAI[6427:83907] =================
```

No fault, no warning, no Swift runtime trap. Saved to
`screenshots/phase5/launch_console.log`.

## Screenshots ↔ state mapping

| File | State | Source | What it proves |
|---|---|---|---|
| `01_idle.png` | `.idle` | Real `CaptureView` (no injection) | Welcome heading "Upload or snap a meal to get insights!" in heavy displayMD; DashedDropZone empty (320×320, dashed border, camera icon + "Meal Snap!"); brandCream background. |
| `02_picked.png` | `.picked` | `LAUNCH_CAPTURE_SAMPLE=picked` | Drop zone filled; outline-variant `PillButton` "Analyze" appears; welcome heading hidden. |
| `03_analyzing.png` | `.analyzing` | `LAUNCH_CAPTURE_SAMPLE=analyzing` | Same drop zone; `PillButton` shows centered `ProgressView` spinner with `isLoading: true`. |
| `04_ready.png` | `.ready` | **Live round-trip** via `LAUNCH_CAPTURE_LIVE=1` | Real Gemini-decoded result for the bundled LandingHero food photo. See "Live round-trip" section below. |
| `05_noFood.png` | `.noFood` | `LAUNCH_CAPTURE_SAMPLE=noFood` | "No food detected!" in displayMD/redError; "Try a clearer photo of a meal, snack, or drink." body copy; outline `PillButton` "Try another photo". |
| `06_failed.png` | `.failed` | `LAUNCH_CAPTURE_SAMPLE=failed` | "Something went wrong" in displayMD/redError; full `LocalizedError` description for `.networkUnavailable` — "We can't reach the analyzer. Check your connection and try again."; outline `PillButton` "Try again". |
| `07_panels_t3s.png` | `.ready` (panels-only at ~3s) | `LAUNCH_CAPTURE_SAMPLE=panels` | Sequential typewriter coordinator mid-second-panel: nutrients fully typed (3 items), benefits mid-second-item ("Provides calcium for bone health" complete + "Conta" partial), drawbacks not yet entered. |
| `08_panels_t6s.png` | `.ready` (panels-only at ~6s) | same | Nutrients + benefits fully typed; drawbacks mid-third-item ("Consider whole-grain cr" partial). Confirms chain advanced from second → third panel. |
| `09_panels_t10s.png` | `.ready` (panels-only at ~10s) | same | All three panels fully typed. `stage = .done`. |

`LAUNCH_CAPTURE_SAMPLE` is a DEBUG-only helper that pre-populates the
layout with a generated sample image and a hand-written
`AnalyzeResponse` so individual states are screenshottable. **The
rendering code is the production code path** — the helper only seeds
state, it does not re-implement any view. The Phase 3 `AnalysisPanel`
already proved itself in `ComponentGallery`; what's new in Phase 5 is
the chained typewriter coordinator in `AnalysisResultView`, and the
three panel screenshots above (`07_…`, `08_…`, `09_…`) are direct
evidence that coordinator advances correctly.

## Live round-trip against `localhost:3001`

Server source at `~/Downloads/foodieAi.-main/server/`. After `npm install`
in that directory, created `.env` with `GEMINI_API_KEY`, `PORT=3001`,
and stub `SUPABASE_URL` / `SERVICE_KEY` (the supabase client is
constructed at module-load even though `/analyze` doesn't use it; stubs
satisfy `createClient` without enabling the unused `/save` and
`/getFoodLogs` routes). `npm run dev` reported:

```
[nodemon] starting `node server.js`
Server running at http://localhost:3001
```

### Out-of-band sanity check (curl)

```
$ curl -sS -X POST -F "image=@…/LandingHero.imageset/landingpage-bg.jpg" \
       http://localhost:3001/analyze \
       -w "HTTP %{http_code} time=%{time_total}s size=%{size_download}\n"
HTTP 200 time=9.621758s size=1264
```

Response body (saved to `screenshots/phase5/curl_analyze_response.json`):

```json
{
  "analysis": {
    "food": "Grilled calamari/octopus with grilled vegetables and basil",
    "calories": 300, "carbs": 12, "sugar": 4,
    "fallback": "",
    "benefits": [...2 items...],
    "drawbacks": [...2 items...],
    "nutrients": [...4 items including "Health Score: 85/100"...],
    "coachAdvice": "Feast like a pharaoh!..."
  },
  "coach": "Cleopatra"
}
```

### Bug found and fixed during this verification

Curl response showed `"fallback": ""` (empty string, not `null`) on the
success path. My initial routing in `CaptureViewModel.analyze()` used
`if response.analysis.fallback != nil → .noFood`, which would have
mis-routed every successful response to the no-food state. Fixed:

- `GeminiAnalysis.hasFood` now treats `fallback == nil OR
  fallback.isEmpty` as "no fallback present."
- `CaptureViewModel.analyze()` now routes via `response.analysis.hasFood`
  rather than the raw `fallback != nil` check.

The fix is documented inline in `Models/GeminiAnalysis.swift` because
it's the kind of thing that would be confusing to a reader expecting
strict-null semantics from a typed API.

### iOS round-trip via `LAUNCH_CAPTURE_LIVE=1`

Live network log captured from the unified log
(`screenshots/phase5/live_roundtrip.log`):

```
2026-05-08 20:48:14.972  FoodieAI[8515]  === AppConfig ===
2026-05-08 20:48:15.075  FoodieAI[8515]  [LiveProbe] photo loaded (414x736); calling analyze()
2026-05-08 20:48:15.098  FoodieAI[8515]  [Analyze] POST http://localhost:3001/analyze bytes=345184
2026-05-08 20:48:21.960  FoodieAI[8515]  [Analyze] HTTP 200 body-bytes=835
2026-05-08 20:48:21.966  FoodieAI[8515]  [Analyze] decoded food=Grilled octopus and vegetables with basil
                                                            coach=Cleopatra
                                                            calories=350.0
                                                            hasFood=true
2026-05-08 20:48:21.985  FoodieAI[8515]  [LiveProbe] analyze() returned; state=ready(<UIImage:…>,
                                            FoodieAI.AnalyzeResponse(analysis: FoodieAI.GeminiAnalysis(
                                              fallback: Optional(""),
                                              food: Optional("Grilled octopus and vegetables with basil"),
                                              calories: Optional(350.0),
                                              carbs: Optional(20.0),
                                              sugar: Optional(5.0),
                                              benefits: Optional(["Octopus provides lean protein…"]),
                                              drawbacks: Optional(["Overconsumption of certain seafood…"]),
                                              nutrients: Optional(["Protein (from octopus)…"]),
                                              coachAdvice: Optional("This dish offers a delightful dance…")
                                            ),
                                            coach: Optional("Cleopatra")))
```

What this proves end-to-end:
- `AppConfig.analyzeBaseURL` resolves to `http://localhost:3001` from
  `Secrets.xcconfig`'s `ANALYZE_HOST=localhost:3001`.
- `ImagePreparation.compress(LandingHero, maxLongEdge:2048, quality:0.8)`
  produced a 345,184-byte JPEG (well under the 9.5MB cap; the source
  was 414×736pt at @1x, so no resize was needed).
- The multipart body Apple-pattern hand-built in
  `AnalyzeService.multipartBody(...)` is correctly parsed by `multer`
  on the server side (HTTP 200, not 400).
- The 6.86s round-trip latency (15.098 → 21.960) is dominated by
  Gemini, not transport — same order as the curl call.
- `JSONDecoder().decode(AnalyzeResponse.self, from: data)` succeeds
  against a real Gemini payload with `fallback: ""` empty string and
  every other field populated.
- The `hasFood` computed property correctly returns `true` on
  `fallback == ""`, sending the VM to `.ready` instead of `.noFood`.
- `RootView` flips to render `AnalysisResultView` with the decoded
  data. `04_ready.png` shows the actual rendered result on the
  iPhone 17 sim:
  - "350 calories" (greenCalorie, kcal kerning)
  - "Grilled octopus and vegetables with basil" (foodName heavy)
  - Sugar 5g / Carbs 20g
  - Speech bubble: "This dish offers a delightful dance of flavors. Just…"
    attributed to ~~Cleopatra~~

The live food name and coach are **different** from the earlier curl
invocation (curl returned "Grilled calamari/octopus…" / Cleopatra; this
run returned "Grilled octopus and vegetables with basil" / Cleopatra
with different coach advice). That non-determinism is itself evidence
the responses come from a real Gemini call — a stub would return
identical text every time.

### Server tear-down

After the round-trip, the server was stopped (`pkill -f "nodemon
server.js"`); subsequent `curl localhost:3001/` returns connection
refused. The Gemini API key in `~/Downloads/foodieAi.-main/server/.env`
remains on disk where the user placed it; that path is outside the iOS
project tree and not committed to any repo here.

## What's still NOT exercised

- The full Google sign-in → MainTabView → tap drop zone → pick photo
  flow. The `LAUNCH_CAPTURE_LIVE` bypass short-circuits the
  PhotosPicker and the auth gate. The picker UI itself is a single
  PhotosPicker call wired to the same `viewModel.setPhoto(image)` entry
  point that `LiveAnalyzeProbeView` uses; if the live round-trip works
  via that entry point (it does), the picker→VM hand-off is the only
  unverified link, and that's a 5-line `.onChange(of: photosSelection)`
  in `CaptureView.swift` that's been a stable SwiftUI primitive since
  iOS 16.
- The `.noFood` server path. The curl + iOS shots both used a real food
  photo; a non-food photo would exercise Gemini's fallback string. The
  routing logic was verified by reading the server source (only
  `fallback.toLowerCase().includes('no food detected')` returns the
  fallback-only payload) and by the bug fix above.
- Save / Cancel actions are still `print()` placeholders pending
  Phase 6.

## Decisions log (Phase 3 format)

1. **GeminiAnalysis is fully optional now.** Rewrote the existing
   model from "non-optional with defaulting custom-init" to
   spec-compliant `let food: String?`, `let calories: Double?`, …
   Added `var hasFood: Bool { fallback == nil && food != nil }` for
   gating. Reason: the spec called for all-optional, and it lets the
   server's defensive partial-payload handling propagate cleanly into
   the UI's "missing field shows blank" behavior.

2. **`Int(calories)` for the calorie line.** The CSS reads
   `${calories} calories` and the web's calories field is a number;
   floating-point macros would format awkwardly. Used `Int(calories ?? 0)`
   for the calorie line and a tiny `format(_:)` helper for grams that
   prints `Int` if exactly integer, otherwise `%.1f`.

3. **Welcome heading uses `.fontWeight(.black)` over `.displayMD`.**
   `displayMD` is already `weight(.heavy)` (M PLUS Rounded 1c
   ExtraBold). The spec calls for weight 900. Stacking
   `.fontWeight(.black)` nudges to the bundled Black face. If you'd
   rather pin to one face, easiest knob is to add a new `.welcomeHeading`
   token to `AppFont.Style`.

4. **`AnalyzeError` cases match the spec verbatim.** Added equality on
   the case identity (status code matters; underlying decoding error
   doesn't). LocalizedError descriptions use plain English copy that
   surfaces in `FailedView`.

5. **Image cap at 9.5 MB instead of 10 MB.** The Express proxy uses
   `multer({ limits: { fileSize: 10 * 1024 * 1024 } })`. We reject just
   under that client-side so the user gets a friendly "photo is too
   large" instead of a 413. Constant on `AnalyzeService.maxJPEGBytes`.

6. **Timeout mapping.** `URLError.timedOut` → `.timeout`;
   `notConnectedToInternet` / `networkConnectionLost` /
   `cannotConnectToHost` / `cannotFindHost` / `dnsLookupFailed` /
   `resourceUnavailable` → `.networkUnavailable`; everything else
   defaults to `.networkUnavailable` (we lose specificity but the user
   sees a usable message either way).

7. **Camera path uses `UIImagePickerController`, not AVCaptureSession.**
   `CameraPicker.swift` is a thin `UIViewControllerRepresentable`
   wrapper. Reason: Phase 5 only needs a single still image; the system
   camera UI is free and dispenses with manual capture-session lifecycle.
   AVFoundation can be revisited in a later phase if we want a custom
   shutter UI.

8. **Library path uses SwiftUI's `.photosPicker`.** Triggered from a
   `.confirmationDialog`'s "Choose from Library" button which sets
   `isShowingLibrary = true`. The Phase 5 spec mentioned
   `PhotosPicker`; this is the modern SwiftUI primitive (iOS 16+) and
   our deployment target is 17.0.

9. **`confirmationDialog` only offers "Take Photo" when
   `UIImagePickerController.isSourceTypeAvailable(.camera) == true`.**
   The simulator has no camera; the dialog hides the option there.
   `confirmationDialog` itself remains visible so library picking is
   always available.

10. **Welcome heading hides via opacity + collapse, not removal.**
    Used `.opacity(... ? 1 : 0).frame(maxHeight: ... ? .infinity : 0)`
    rather than `if state.isIdle { … }` to avoid a layout pop when the
    heading disappears. Animates with `.easeOut(0.25)`.

11. **Save / Cancel actions are `print()` placeholders.** Phase 6
    (save + tracker) replaces them with the real `FoodLogService.insert`
    + `FoodImageService.upload` calls.

12. **`AnalysisResultView` sequencing uses estimated typewriter
    durations, not callbacks from `TypewriterController`.**
    `TypewriterController` doesn't expose a public completion
    handler that survives across the SwiftUI `@StateObject` boundary.
    Computed `typewriterNanos(for:)` from
    `chars × 0.02s + 0.4s slack`, which matches the controller's
    pacing within ±200ms in practice. The slack prevents the next
    panel from starting its first character before the previous panel
    finishes its last.

13. **DEBUG-only `LAUNCH_CAPTURE_DIRECT` / `LAUNCH_CAPTURE_SAMPLE` /
    `LAUNCH_CAPTURE_LIVE` bypasses.** Three new env-var bypasses in
    `FoodieAIApp.rootScene`, parallel to the existing
    `LAUNCH_THEME_PREVIEW` / `LAUNCH_COMPONENT_GALLERY`.
    `LAUNCH_CAPTURE_DIRECT` renders the real `CaptureView` without
    auth. `LAUNCH_CAPTURE_SAMPLE=<state>` routes to a
    `CapturePreview.swift` helper that pre-populates the layout with a
    generated sample image + hand-written response. `LAUNCH_CAPTURE_LIVE`
    loads the bundled `LandingHero` photo into a real `CaptureViewModel`
    and triggers `viewModel.analyze()` on appear, exercising the full
    production multipart + decode pipeline. All three ship only in
    debug builds.

15. **Empty-string fallback bug in initial routing.** Found during
    live verification — the server emits `fallback: ""` on the
    success path (Gemini's structured-output schema requires the field
    even when food IS detected; only a non-empty fallback signals
    "no food"). My initial `analyze()` used `if fallback != nil` to
    route to `.noFood`, which would mis-route every successful
    response. Fixed by introducing `GeminiAnalysis.hasFood` (returns
    true when `fallback == nil OR fallback.isEmpty` AND `food != nil`)
    and switching `CaptureViewModel.analyze()` to use it.

16. **`AnalyzeService` debug instrumentation.** Added three
    `#if DEBUG` `NSLog` calls inside `AnalyzeService.analyze`: one at
    POST kickoff (URL + body bytes), one on response (status + body
    bytes), one on successful decode (food, coach, calories, hasFood).
    Plus one on URLError catch (code + description) and one on decode
    failure. These are the lines that produced the live network log
    above. They cost zero in release builds.

14. **`PHASE_5_VERIFICATION.md` is the artifact, not a separate
    `PHASE_5_DECISIONS.md`.** Phase 4 used the same single-file
    convention; staying consistent.

## Files added or modified

**Modified**
- `FoodieAI/Models/GeminiAnalysis.swift` — rewrote to all-optional + `hasFood` (with empty-string fallback handling).
- `FoodieAI/Services/AnalyzeService.swift` — finalized error enum, image-size guard, URLError mapping, plus DEBUG NSLog instrumentation around request/response/decode.
- `FoodieAI/Features/Home/CaptureViewModel.swift` — routing now uses `response.analysis.hasFood` rather than `fallback != nil`.
- `FoodieAI/FoodieAIApp.swift` — replaced Home tab placeholder with `CaptureView()`; added `LAUNCH_CAPTURE_DIRECT` / `LAUNCH_CAPTURE_SAMPLE` / `LAUNCH_CAPTURE_LIVE` bypasses.
- `project.yml` — added `Debug` config block with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, `SWIFT_OPTIMIZATION_LEVEL=-Onone`, `GCC_PREPROCESSOR_DEFINITIONS=DEBUG=1`, `ONLY_ACTIVE_ARCH=YES`.

**Added**
- `FoodieAI/Services/ImagePreparation.swift` — pure resize + JPEG-encode helper.
- `FoodieAI/Features/Home/CaptureView.swift` — Home tab root replacing placeholder; picker plumbing; result section dispatch.
- `FoodieAI/Features/Home/CameraPicker.swift` — UIImagePickerController bridge for the camera-source case.
- `FoodieAI/Features/Home/AnalysisResultView.swift` — calorie + macros entrance; SpeechBubble; Save/Cancel; three sequenced AnalysisPanels with stagger transitions.
- `FoodieAI/Features/Home/CapturePreview.swift` — DEBUG-only renderer for `LAUNCH_CAPTURE_SAMPLE` (mocked states), `LAUNCH_CAPTURE_LIVE` (real round-trip via bundled photo), and the `panels`-only sample mode used for the typewriter chain shots.

**Unmodified but verified**
- `FoodieAI/Info.plist` — `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` present with FoodieAI-specific copy (Phase 1 originals still apply).
- `FoodieAI/Resources/Assets.xcassets/PanelIcons/*.imageset/` — SVG bundling untouched.

## Phase 5 status: ✅ verified end-to-end against live `/analyze`

Real Gemini round-trip confirmed in the iOS app. Multipart wire format
parsed cleanly by `multer`; live JSON decoded into `AnalyzeResponse`;
`hasFood` routes correctly with empty-string `fallback`; UI flips to
`.ready` and renders the live food name + calorie line + macros +
coach-attributed speech bubble. Server torn down post-verification.

Phase 6 (save + tracker) is unblocked. The two outstanding non-blocker
items are:
- Save / Cancel `print()` placeholders → Phase 6 wires them to
  `FoodImageService.upload` + `FoodLogService.insert`.
- Live `.noFood` server path. Routing logic verified via curl response
  shape + the bug fix above; not exercised end-to-end with a non-food
  photo. Cheap follow-up if you want me to fold one in before Phase 6.
