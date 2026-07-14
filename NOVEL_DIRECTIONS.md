# FoodieAI — Novel Directions

_A synthesis from a full-codebase re-read (2026-07-03). Not a backlog of features — a
single architectural thesis and the four combinations that follow from it._

---

## The thesis: "Attention Is All You Need" — applied to FoodieAI

Google's 2017 paper did not *invent* attention. Attention already existed, bolted onto
recurrent networks as a helper. The radical move was **subtraction**: throw away the RNN
scaffolding and let *one* attention mechanism be the entire architecture. The claim in the
title was that the helper was secretly the whole thing.

FoodieAI is one subtraction away from the same move. The app has already built — and left
scattered — every primitive of a real coaching intelligence:

- a **belief engine** — Beta-Binomial posteriors over post-meal mood (`FoodOSBeliefEngine`);
- a **reward signal almost no tracker has** — *post-meal mood* (`loved`/`fine`/`tough`);
- a **closed causal loop** — `willTry → next mood note → "this worked before"`
  (`FoodOSActiveExperiment` + `FoodOSMomentFeedbackStore`);
- a literal **6-head attention scorer** — recency / same-slot / same-food / macro-similarity /
  mood-relevance / surprise (`FoodOSAttentionEngine`, currently **dead**, 0 call sites);
- a **forward model** — Mifflin–St Jeor TDEE + weight projection (`CalorieGoalCalculator`);
- **personalized timing** — `EatingTimeInference`;
- **local, zero-egress discipline** — so all of the above can run on-device.

But they are deployed as ~30 hand-tuned `if`-statements that contend for the same screen
slots, sometimes contradict each other (the ring says "on goal" while the widget says
"200 over"), and go silent the moment the app closes.

**The novelty is not a new feature. It is collapsing the N reactive rules into one learned,
predictive, mood-driven policy.** Everything below is a facet of that one move. Each is written
as `(a primitive we already have) + (a research idea) → something no calorie app does`.

---

## Idea 1 — "One Brain": the app as a single ranked feed, not 30 if-statements

**Combine:** the dead `FoodOSAttentionEngine` + **contextual bandits / Thompson sampling**
(we already have the Beta posteriors and the per-tag preference store).

**What it is:** one policy scores *every* candidate surface — daily quest, eat-to-goal card,
streak nudge, trend coach, FoodOS moment, records banner, **and notifications** — against a
single state vector (time, budget remaining, streak risk, movement, days-since-X, recent mood)
and the user's learned per-tag preferences. The highest-value surface wins the slot; ties break
by Thompson sampling for exploration.

**Why it's the subtraction move:** delete the priority chains and the ad-hoc gates. This
*structurally* eliminates the goal-divergence contradiction (one source of truth for "how's the
day going"), makes every card adaptive, and finally deploys the attention engine that already
exists. The reward is already there: taps + "helpful"/"not useful" + downstream save/mood.

**Constraints honored:** fully local, zero egress. Deterministic fallback when no feedback
exists (the engine is already a pure function of logs in the empty-preference case).

**Bonus that falls out for free:** a coach who *earns* airtime — the historical-figure coach
whose advice you rated "worked" surfaces more often. A coach leaderboard driven by *your*
outcomes, not a random pick.

**✅ Status (2026-07) — engine shipped, build + 7 tests green:** `Core/SurfacePolicy.swift` is the
unified policy. A `SurfaceCandidate` (basePriority + eligibility + learned `preference` +
`contextRelevance`) is scored by `score()` = priority chain + bounded preference adjustment +
`relevance(kind:in:)` — a small attention scorer over one `SurfaceContext` state vector — and
`rank`/`top`/`fill` let every surface compete in one ranking. Verified: a neutral vector reproduces
the base priority order exactly (nothing regresses), and context can promote a lower-base surface
above a higher-base one (streak-at-risk beats a bigger card). **Next (UI):** have each live surface
publish a `SurfaceCandidate` instead of gating itself, fed by real FoodOS bandit `preference` + a live
`SurfaceContext` — the actual subtraction of the ~30 if-statements.

---

## Idea 2 — "The Meal Twin": stop reacting, start simulating; optimize for **mood, not calories**

**Combine:** `EatingTimeInference` (when you eat) + `LocalNutritionBeliefStore` (what you
actually eat and its macros) + `MovementEnergy` + the **mood posteriors** + the idea of a
**digital twin / forward simulation**.

**What it is:** at 2pm the app forward-runs *the rest of your day* from your own history —
"you usually eat dinner ~7:30, ~650 kcal, usually pasta" — and surfaces the single
highest-leverage move *before* the meal happens, not after.

**The twist that makes it novel:** the objective function is **not calories** — it's
**predicted mood *and* goal adherence, jointly**. _"You're projected to land 180 over; your
usual 7:30 pasta trends you 'tough' — swap to X and you land on-goal AND on your best-mood
pattern."_ Every tracker optimizes calories. None optimizes *how the food will make you feel*,
because none has the mood signal. This turns the app from a mirror into a co-pilot.

**Surfaces:** the Home `TodayGoalCard` and the post-scan result already host the eat-to-goal
line — the Twin is the predictive upgrade of that same slot (governed by Idea 1's policy).

**✅ Status (2026-07) — ENGINE + UI SHIPPED, build + tests green (6 engine + 7 builder):**
`Core/MealTwinEngine.swift` (pure forward simulation: `project(MealTwinContext)` computes the "do
nothing" landing, then picks the next-slot dish maximizing a JOINT objective — direction-aware goal fit
+ `moodPositiveRate` — returning a `MealTwinMove`). `Core/TwinMealBuilder.swift` turns ~30 days of raw
history into the `[TwinMeal]` repertoire (group by name → mean calories, modal slot, per-dish mood
posterior via `FoodOSBeliefEngine`, neutral 0.5 under thin evidence). **UI:** the Today `EatToGoalCard`
is upgraded in place — when a move exists it shows a projection headline ("Heading to 180 over"), a
STATIC `DayTrajectoryStrip` (now→projected→goal, no animation), and one mood-aware move row (sparkles
cue on best-mood picks), with a featured `brand.opacity(0.3)` stroke; new users with no history keep
the generic-suggestion fallback so it never blanks. `TodayView` builds the context from data already
loaded + one cached 30-day fetch (refetched on activate / save). ⚠️ **Visual needs device eyeball**
(CLI can't screenshot the sim). Next: govern this slot via Idea 1's `SurfacePolicy`.

---

## Idea 3 — "Causal Nudges": JITAI — learn which nudge *actually* changes behavior

**Combine:** the `willTry → mood` causal machinery + **Just-In-Time Adaptive Interventions /
micro-randomized trials / uplift modeling** (a real mobile-health research field).

**What it is:** extend the same causal loop from `nudge → mood` to `nudge → behavior`. Lightly
micro-randomize send-time and copy, learn per-user **uplift** (does *this* nudge at *this*
moment actually change logging — vs. mere correlation), and send *only* high-uplift nudges.

**Why it matters here:** the loop currently closes *inside* the app and goes silent outside it;
notifications are a static schedule. This is the real fix for that **and** for the
notification-spam edges — notifications stop being a schedule and become a learned policy.
Half the framework already exists in FoodOS; this points it outward.

**✅ Status (2026-07) — engine shipped, build + 9 tests green:** `Services/NudgeUpliftModel.swift` —
Laplace-smoothed `uplift()` = P(log | nudged) − P(log | withheld), and a micro-randomized `decide()`
policy (explore to fill both arms when data is thin; else exploit — send iff uplift > 0), plus an
actor-isolated, zero-egress `NudgeUpliftStore` keyed by (`NudgeKind`, bucketed `NudgeContext`). Random
draws are injected, so it's deterministic in tests. **Next (device):** have `NotificationScheduler`
consult `store.decision(...)` before sending and `record(...)` the outcome (did the user log within the
window) — turning the static schedule into a learned causal policy that also fixes the spam edges.

---

## Idea 4 — "Visual Food Memory": on-device embeddings (the wild one, the most on-brand)

**Combine:** the meal photo we currently analyze once and throw away + **on-device Vision
feature-prints** (`VNGenerateImageFeaturePrintRequest`) + nearest-neighbor clustering.

**What it is:** embed each meal photo **locally, zero network**, and make the *visual cluster* —
not the brittle English name — the unit of belief. _"You've eaten this exact bowl 6 times — it
quietly trends your afternoon energy down."_

**Why it's the highest-leverage foundation:** it attacks the pain the app already feels — a
**mandatory `NameConfirmSheet` on every scan** because the model's names are unreliable — *and*
the brittle FoodOS learning that today keys off substring-matching rendered English copy. Both
problems get a reliable identity key from the *same* primitive. Recognizing your food from your
own photos, entirely on-device, is a different axis than any text-based tracker — and it fits
the low-egress discipline perfectly.

**✅ Status (2026-07) — build + tests green (15 unit tests), read path wired behind a flag:**
- `Core/VisualFoodMemory.swift` — `VisualDescriptor` (compact `[Float]`, base64-persisted;
  numerically-stable `Double`-accumulated distance; `isValid` guard rejecting NaN/Inf prints),
  pure `VisualFoodMatcher` (nearest / occurrences / timesSeen / suggestedName), and an
  actor-isolated local store (Application Support JSON, capped 300, zero egress).
- `Services/VisionMealEmbedder.swift` — the on-device boundary: `VNGenerateImageFeaturePrintRequest`
  → `[Float]`, **pinned to Revision1** so prints stay comparable across runs, fully guarded (nil on
  any failure / corrupt print). The *only* piece needing device verification.
- **Embed once, reuse:** `CaptureViewModel` embeds the photo at analyze time, stashes it, and reuses
  it at save (no second Vision pass). Recording is detached/best-effort — never blocks or fails a save.
- **Tuning instrument (DEBUG, always on):** every scan logs its nearest prior match + distance
  (`[VisualMemory] nearest prior: "X" dist=… threshold=…`). Log the same dish a few times and read
  the distances to calibrate the threshold.
- **Read path wired, OFF by default:** flip UserDefaults `visualMemoryReadEnabled` → a confident
  visual match surfaces as a one-tap "You've photographed this before — {name}" chip in
  `NameConfirmSheet` (non-destructive: the user taps to accept; the mandatory confirm sheet stays the
  safety net; never auto-overrides).
- **⛔ Blocking tune (device):** `VisualFoodMemory.sameMealThreshold` (18.0) is a placeholder —
  feature-print distances aren't normalized. Calibrate it from the DEBUG logs on real meals before
  enabling the flag for anyone (a wrong "you've had this" is worse than a miss — start conservative).
- **Next:** "you've had this N times" via `timesSeen(...)`, and feeding the visual cluster into
  FoodOS as the belief unit (instead of substring tags) — which also fixes the FoodOS brittleness
  from Idea 1, the bridge into One Brain.

---

## How they compound (suggested sequencing)

1. **Idea 4** gives every other system a reliable identity key (fixes name-confidence + FoodOS
   tag brittleness).
2. **Idea 1** unifies the surfaces on top of that key (one policy, one source of truth).
3. **Idea 2** and **Idea 3** are the predictive (in-app) and outward-facing (push) halves of the
   same One Brain.

Four ideas, one architecture. The move is subtraction, then unification.

---

## Guardrails (do not violate — validated by prior research + brand decisions)

- **No guilt/shame, no punitive streaks, no arcade points economy** (ED research; brand is
  warm/Duolingo-bouncy). Burn-off framing stays soft, goal-aware, and routed through the coach.
- **No new third-party UI/ML/networking libraries** (CLAUDE.md). On-device Vision and local
  bandits satisfy this.
- **Low egress** — prefer local computation and reuse of already-loaded data.
- **The silent abuse cap stays soft** — a Pro over-scanner sees "you're scanning a lot today,
  try again tomorrow," never a number.
