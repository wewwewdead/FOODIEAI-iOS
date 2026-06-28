# Home-screen Widget — status & the one step left

**Done (verified):**
- ✅ Widget target `FoodieAIWidgetExtension` created (you did this in Xcode).
- ✅ Real widget code in `FoodieAIWidget/FoodieAIWidget.swift` (the "Daily Loop"
  widget — small + medium, streak + calorie ring + steps). Boilerplate replaced;
  the unused iOS-18 Control widget was removed.
- ✅ Shared `FoodieAI/Core/WidgetSnapshot.swift` added to BOTH targets.
- ✅ App writes the snapshot from `TodayView` (`WidgetSnapshotUpdater`).
- ✅ **Builds, code-signs, and embeds into the app** — confirmed via xcodebuild
  (the `.appex` lands in `FoodieAI.app/PlugIns/`). 260 app tests still pass.

**The one thing left (only you can do it — it's tied to your Apple account):**

### Add the App Group to both targets
The widget reads the app's data through a shared App Group container. Adding the
capability registers it with your App ID through Xcode, signed in as you — which
is why I can't do it (and why faking the entitlement would break device/TestFlight
signing).

1. Select the **FoodieAI** app target → **Signing & Capabilities** →
   **+ Capability ▸ App Groups** → **+** → add **`group.com.thefoodieai.app`**.
2. Select the **FoodieAIWidgetExtension** target → same steps → add the **same**
   id.
3. If you pick a different id, change `WidgetBridge.appGroupID` in
   `FoodieAI/Core/WidgetSnapshot.swift` to match exactly.

### Enable HealthKit Background Delivery (keeps steps fresh while the app is closed)
The `com.apple.developer.healthkit.background-delivery` entitlement is already in
`FoodieAI/FoodieAI.entitlements`. With automatic signing Xcode should pick it up,
but if signing complains, toggle it in the UI so the provisioning profile includes
it: **FoodieAI** target → **Signing & Capabilities** → **HealthKit** → check
**Background Delivery**. (Requires a paid developer account.)

### Then run it
1. Build & run the app, open the **Today** tab once (writes the first snapshot,
   grants Health access, and arms background delivery).
2. Home screen → long-press → **+** → search **FoodieAI** → add the **Daily Loop**
   widget (Small or Medium).

Until the App Group is added the widget still builds and shows its empty state
("Start your streak", 0 kcal) — it just can't see the app's numbers yet.

## How it stays fresh
- **On app open / foreground:** the app calls `WidgetSnapshotUpdater.write(...)`
  from `TodayView` (on appear, when calories change, and on background) → writes
  the snapshot + `WidgetCenter.reloadAllTimelines()`.
- **While the app is closed:** a HealthKit observer with hourly background delivery
  (`HealthActivityService.enableWidgetBackgroundSync`) resumes the app briefly when
  new step data lands, refreshes just the step count, and reloads the widget. This
  is the ceiling iOS allows — per-step live updates from a closed app aren't
  possible on the platform. Cost is negligible (one query + one write per hour).
- **At local midnight:** the widget zeroes the daily figures on its own —
  `WidgetSnapshot.rolledOver(to:)` plus a timeline entry scheduled at the next
  midnight — so steps/calories reset even if the app isn't opened.
- The widget also refreshes on a 5-hour safety net for new-streak surfacing.
