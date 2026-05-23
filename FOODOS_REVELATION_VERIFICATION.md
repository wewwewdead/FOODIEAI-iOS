# foodOS Revelation Moments Verification

Date: 2026-05-24

## Files Modified / Created

- Created `FoodieAI/Services/FoodOSPairedBeliefs.swift`
- Modified `FoodieAI/Services/FoodOSMomentEngine.swift`
- Modified `FoodieAI/Services/FoodOSMomentFeedback.swift`
- Modified `FoodieAI/Features/Mirror/FoodMirrorViewModel.swift`
- Modified `FoodieAI/Features/Mirror/FoodMirrorView.swift`
- Modified `FoodieAITests/FoodieAITests.swift`

## Paired Beliefs Implemented

- A. Time-of-day x mood: implemented.
- B. Macro-leaning x mood: implemented.
- C. Day-type x pattern/mood: implemented, including weekday/weekend calorie or variety divergence.
- D. Logging-time consistency x mood: not implemented. This item was optional and lower priority in the objective.

## Surprise Threshold

- `FoodOSPairedBeliefs.surpriseThreshold = 0.18`
- `FoodOSPairedBeliefs.minimumObservationCount = 3`
- `FoodOSPairedBeliefs.peerGapThreshold = 0.12`

The paired beliefs reuse the existing Beta(1, 1) posterior:

```swift
(positive + 1) / (positive + negative + 2)
```

## Test Results

Command:

```sh
xcodebuild -project FoodieAI.xcodeproj -scheme FoodieAI -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Result:

- `TEST SUCCEEDED`
- `183 tests, 0 failures`

Known unrelated warnings remain:

- Traditional headermap deprecation warnings.
- Existing Swift 6 isolation warnings in `FoodPatternInsightService.swift` and async test locking.

## Requirement Checks

- Revelation kind added: yes.
- Revelation priority is after learning and before existing moment kinds: yes.
- No revelation when the learning gate fails: verified by existing learning tests.
- Time-of-day, macro-lean, and day-type paired beliefs: verified by focused tests.
- Surprise gate blocks low-surprise patterns: verified.
- Count gate blocks buckets with fewer than 3 observations: verified.
- Posterior stays inside `(0, 1)`: verified.
- Missing data is skipped rather than zeroed: implemented by filtering mood/macro observations before computing bucket posteriors.
- Revelation copy passes `FoodOSMomentCopySafety`: verified in tests.
- Revelation subtype tags participate in the feedback/bandit path: verified by tag derivation tests.
- Same revelation subject does not repeat back-to-back in app refresh flow: verified by `FoodMirrorViewModelTests`.
- Existing recognition output is unchanged when no revelation qualifies: verified byte-for-byte by regression test.
- Empty-preferences invariant remains: covered by existing feedback tests and full test suite.

## Real Data Verification

On-device verification was performed after inserting a synthetic Supabase test pattern into the user's account data.

Observed FoodOS moment:

> Your midday meals have been your tougher mood window. That sits about 34 points below your meal mood pattern.

The user confirmed the story card included the matching evidence line for the midday mood-note bucket. This verifies that a real FoodMirror refresh can surface a `.revelation` moment, that the copy names the paired pattern, and that the evidence line is present.
