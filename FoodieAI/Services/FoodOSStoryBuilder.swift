import Foundation

// MARK: - FoodOSStoryBuilder
//
// Pure storytelling helpers for the Food Mirror surfaces. The goal is
// to make every visible claim follow CLAIM → SPECIFIC EVIDENCE → TINY
// ACTION so the Mirror reads as a sharp, honest reflection rather
// than a generic motivator.
//
// All helpers are read-only and side-effect free. No Gemini calls, no
// AnalyzeResponse, no I/O — these consume already-summarized values
// and produce display strings. The engine and insight service compose
// them so the same phrasing rules apply across cards, Home preview,
// and tests.

enum FoodOSStoryBuilder {

    // MARK: Thresholds (single source of truth for "is one food
    // becoming a regular?" so all surfaces agree on the line.)

    /// Minimum repeats before we'll *name* a food in identity copy.
    /// Three is the lowest count `mostCommonFoods` returns; mentioning
    /// the food sooner reads as overclaim.
    static let mentionFloor = 3
    /// Minimum repeats before a food is allowed to be called an
    /// "anchor" or "reliable." Five is the threshold the user can
    /// feel without us calculating dominance.
    static let anchorFloor = 5
    /// 30-day uniqueness ratio above which the user reads as
    /// "exploring widely" — same boundary the legacy explorer line
    /// used so the empty-data behavior stays calm.
    static let exploringRatio: Double = 0.7
    /// 30-day dominance ratio above which a single repeated food
    /// dominates the diet ("creature of habit" territory). Calibrated
    /// to keep the dominance branch quiet on a typical varied diet.
    static let dominanceRatio: Double = 0.3
    /// Below this 30-day total, every identity line stays silent so a
    /// brand-new account never gets a confident headline from 1–2 logs.
    static let identityMinLogs = 5

    // MARK: Hero identity

    /// One soft, descriptive line about how the user eats — never
    /// prescriptive, never clinical. Returns nil when the data
    /// doesn't support any honest framing (the view then falls back
    /// to its default subtitle).
    ///
    /// Priority chain:
    ///   1. dominant food (count ≥ 5 AND ≥ 30% share)   → "X is becoming one of your food anchors."
    ///   2. mostly exploring + one anchor               → "You're mostly exploring — but X is becoming a reliable anchor."
    ///   3. exploring widely, no anchors                → "You're exploring widely — your meals rarely repeat."
    ///   4. several reliable repeats                    → "You have a few reliable meals your week keeps returning to."
    ///   5. one food showing up a few times             → "X keeps showing up in your week."
    ///   6. nothing strong enough to surface            → nil
    ///
    /// The contradiction guard inside this picker enforces the
    /// project rule "never say 'rarely repeat' when one food appears
    /// five or more times" — see also `FoodOSNarrativePolicy`.
    static func heroIdentityLine(thirtyDayLogCount: Int,
                                 topFoods: [FoodMirrorSummary.FoodCount],
                                 uniqueFoodCount: Int) -> String? {
        let total = thirtyDayLogCount
        guard total >= identityMinLogs else { return nil }

        let topCount = topFoods.first?.count ?? 0
        let topName  = topFoods.first?.name
        let uniqueRatio = total > 0
            ? Double(uniqueFoodCount) / Double(total)
            : 0

        // 1. Dominant repeat — one food earns "anchor" framing on its
        // own (count ≥ anchorFloor and ≥ 30% of meals).
        if let name = topName,
           topCount >= anchorFloor,
           Double(topCount) / Double(total) >= dominanceRatio {
            return "\(name) is becoming one of your food anchors."
        }

        // 2. Mostly exploring BUT one anchor exists — the headline
        // case the task brief calls out. Avoids the "rarely repeat"
        // contradiction when one food is clearly repeating.
        if let name = topName,
           topCount >= anchorFloor,
           uniqueRatio >= exploringRatio {
            return "You're mostly exploring — but \(name) is becoming a reliable anchor."
        }

        // 3. Pure explorer — many unique meals, no strong repeats.
        // Safe to say "rarely repeat" because the guard above caught
        // the anchor case first.
        if uniqueRatio >= exploringRatio, topCount < anchorFloor {
            return "You're exploring widely — your meals rarely repeat."
        }

        // 4. Several reliable meals — at least two foods at the
        // mention floor (≥ 3 each).
        let reliable = topFoods.filter { $0.count >= mentionFloor }
        if reliable.count >= 2 {
            return "You have a few reliable meals your week keeps returning to."
        }

        // 5. One food repeats a few times — softer than "anchor".
        if let name = topName, topCount >= mentionFloor {
            return "\(name) keeps showing up in your week."
        }

        return nil
    }

    // MARK: Home preview anchor copy

    /// Sharper title for the Home Mirror preview when a single food
    /// is becoming a regular. Returns nil when no top food clears the
    /// mention floor — the caller then falls back to the existing
    /// identity / week-change / weekly-summary priority chain.
    ///
    /// "Anchor" framing kicks in at `anchorFloor`; below that we use
    /// the softer "keeps returning to" copy so we don't overclaim.
    static func homePreviewAnchorTitle(
        topFoods: [FoodMirrorSummary.FoodCount]
    ) -> String? {
        guard let top = topFoods.first else { return nil }
        if top.count >= anchorFloor {
            return "\(top.name) is becoming a reliable anchor."
        }
        if top.count >= mentionFloor {
            return "You keep returning to \(top.name)."
        }
        return nil
    }

    /// Tight evidence footer for the Home preview's anchor card.
    /// Mentions log count plus optional mood-evidence clause. Returns
    /// nil when nothing more specific than the generic evidenceLine
    /// applies so the caller can leave the existing footer in place.
    static func homePreviewAnchorEvidence(
        topFood: FoodMirrorSummary.FoodCount?,
        moodLogCount: Int
    ) -> String? {
        guard let top = topFood, top.count >= mentionFloor else { return nil }
        let logsNoun = top.count == 1 ? "log" : "logs"
        if moodLogCount >= 3 {
            return "\(top.count) \(logsNoun) · recent mood notes steady"
        }
        return "\(top.count) \(logsNoun) in the last 30 days"
    }

    // MARK: Nudge copy — positive mood-linked food

    /// Sharper nudge copy for the "this food has worked well" branch
    /// of `todaysGentleNudge`. Includes count + mood-evidence so the
    /// reader can see *why* the food is being highlighted.
    ///
    /// Keeps the literal phrase "work well" so the legacy nudge tests
    /// continue to assert against the same anchor word while reading
    /// less like a fortune-cookie line.
    static func positiveMoodFoodNudge(
        food: String,
        lovedCount: Int
    ) -> String {
        let logsNoun = lovedCount == 1 ? "log" : "logs"
        return "\(food) seems to work well for you — \(lovedCount) \(logsNoun) with steady or loved mood notes."
    }

    // MARK: Action label gating

    /// Decide whether the Mirror's FoodOS Moment card should render
    /// `moment.actionLabel` as a separate row beneath the evidence
    /// line. The card already shows title, body, and evidence — an
    /// action that duplicates one of those reads as filler.
    ///
    /// Rules (per the storytelling brief):
    ///   - nil action → never render
    ///   - whitespace-only action → never render (treat as empty)
    ///   - action equals body (trimmed, case-insensitive) → never
    ///     render (would echo the same sentence twice)
    ///   - action passes `FoodOSCopySafety` → render
    ///   - action contains a banned fragment → drop it on the floor;
    ///     the rest of the card still renders, but the card never
    ///     ships an unsafe call-to-action.
    ///
    /// Pure; no I/O.
    static func shouldRenderActionLabel(_ moment: FoodOSMoment) -> Bool {
        guard let raw = moment.actionLabel else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Duplicate of body? Don't echo.
        if let body = moment.body {
            let bodyTrimmed = body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if bodyTrimmed == trimmed.lowercased() {
                return false
            }
        }
        // Last-line safety belt. The engine's own copy passes today,
        // but we don't ship an unsafe call-to-action even if a future
        // contributor authors one.
        return FoodOSCopySafety.isSafe(trimmed)
    }
}

// MARK: - FoodOSEvidenceBuilder
//
// Per-moment evidence-line builders. Each card on the Mirror shows
// the same shape: CLAIM (in the title) → EVIDENCE (this line). The
// evidence must be specific enough to be defensible — count + window,
// or before/after averages — and nothing more.

enum FoodOSEvidenceBuilder {

    /// Celebration moment: how many meals this week vs. last. Falls
    /// back to a single-week phrasing when the previous week's count
    /// is zero (defensive — celebrationMoment already requires
    /// previous > 0, but we keep the helper resilient).
    static func celebrationEvidence(currentCount: Int,
                                    previousCount: Int) -> String {
        let mealsCurrent = currentCount == 1 ? "meal" : "meals"
        guard previousCount > 0 else {
            return "You logged \(currentCount) \(mealsCurrent) this week."
        }
        let delta = currentCount - previousCount
        let direction = delta >= 0 ? "more" : "fewer"
        let absDelta = abs(delta)
        let absNoun  = absDelta == 1 ? "meal" : "meals"
        return "You logged \(currentCount) \(mealsCurrent) this week, "
            + "\(absDelta) \(absNoun) \(direction) than last."
    }

    /// Change moment: "Your dinner average changed from ~820 kcal to
    /// ~610 kcal this week." Caller passes the segment label ("dinner
    /// average", "typical meal") so the same helper handles both.
    static func changeEvidence(label: String,
                               previousAvg: Double,
                               currentAvg: Double) -> String {
        let prev = Int(previousAvg.rounded())
        let cur  = Int(currentAvg.rounded())
        return "Your \(label) changed from ~\(prev) kcal to ~\(cur) kcal this week."
    }

    /// Recognition moment: cite the food + its count + window. The
    /// window default mirrors the engine's 30-day source slice.
    static func recognitionEvidence(food: String,
                                    count: Int,
                                    days: Int = 30) -> String {
        let noun = count == 1 ? "time" : "times"
        return "You logged \(food) \(count) \(noun) in the last \(days) days."
    }

    /// Mood reflection moment: cite positive ratio + total mood note
    /// count. Pre-condition: total ≥ 3 (the engine already enforces
    /// the mood-claim floor — the helper just renders).
    static func moodEvidence(positive: Int, total: Int) -> String {
        let noun = total == 1 ? "mood note" : "mood notes"
        return "\(positive) of \(total) \(noun) were fine or loved."
    }

    /// Worked-before moment: tries + positive mood resolutions.
    /// Phrasing matches the spec exactly.
    static func workedBeforeEvidence(tries: Int, positives: Int) -> String {
        let tryNoun  = tries == 1 ? "try" : "tries"
        let moodNoun = positives == 1 ? "positive mood note" : "positive mood notes"
        return "Based on \(tries) \(tryNoun) with \(positives) \(moodNoun)."
    }

    /// Nudge evidence: mention the dinner/lunch ratio rather than the
    /// generic "based on X meals" line. Rounded to one decimal so the
    /// caption stays calm ("about 1.3× lunch" not "1.32413×").
    static func nudgeDinnerVsLunchEvidence(ratio: Double) -> String {
        let rounded = (ratio * 10).rounded() / 10.0
        let formatted = String(format: "%.1f", rounded)
        return "Dinner has averaged about \(formatted)× lunch across meals with enough data."
    }

    /// Calm fallback when every other evidence builder declines.
    static func fallbackEvidence() -> String {
        "Based on your recent meals."
    }
}

// MARK: - FoodOSNarrativePolicy
//
// Pure rules that prevent contradictory narrative ("explorer" vs. a
// repeated food, mood claim vs. 0 mood notes, etc.). The picker
// helpers above already follow these rules; this enum gives tests a
// tight handle to assert against them directly and lets future
// surfaces query the same gates without duplicating thresholds.

enum FoodOSNarrativePolicy {

    /// "Rarely repeat" is only honest when no food has crossed the
    /// anchor floor. The hero picker uses this to gate the
    /// explorer-pure branch.
    static func canSayMealsRarelyRepeat(topFoodCount: Int) -> Bool {
        topFoodCount < FoodOSStoryBuilder.anchorFloor
    }

    /// Pure "explorer" framing requires both high uniqueness AND no
    /// dominant repeating food. Same gate as
    /// `canSayMealsRarelyRepeat` for now; kept as its own predicate
    /// so the call site reads cleanly.
    static func canCallExplorer(topFoodCount: Int,
                                 uniqueFoodCount: Int,
                                 thirtyDayCount: Int) -> Bool {
        guard thirtyDayCount > 0 else { return false }
        let ratio = Double(uniqueFoodCount) / Double(thirtyDayCount)
        return ratio >= FoodOSStoryBuilder.exploringRatio
            && topFoodCount < FoodOSStoryBuilder.anchorFloor
    }

    /// We refuse to mention a specific food in a personal claim until
    /// it has shown up at least the mention-floor number of times.
    /// Below that the food's appearance reads as coincidence, not
    /// pattern.
    static func canMentionTopFood(count: Int) -> Bool {
        count >= FoodOSStoryBuilder.mentionFloor
    }

    /// Mood claims need at least three mood notes to clear the
    /// "single anecdote masquerading as pattern" floor. Mirrors the
    /// engine's existing posterior threshold.
    static func canMakeMoodClaim(moodLogCount: Int) -> Bool {
        moodLogCount >= 3
    }

    /// Detect the headline contradiction the task brief calls out:
    /// hero says "rarely repeat" while the patterns panel below
    /// shows a 5+ count. Used by tests and as a safety belt around
    /// any future hero text source.
    static func hasRarelyRepeatContradiction(hero: String?,
                                             topFoodCount: Int) -> Bool {
        guard let hero else { return false }
        let lower = hero.lowercased()
        guard lower.contains("rarely repeat") else { return false }
        return topFoodCount >= FoodOSStoryBuilder.anchorFloor
    }

    /// Soften an authored claim when the evidence base is thin. Wraps
    /// the original line with "Looks like X" framing instead of
    /// asserting X — keeps the surface honest about its certainty.
    static func softenWeakEvidence(_ text: String, isWeak: Bool) -> String {
        guard isWeak else { return text }
        // The leading clause carries hedging without sounding evasive
        // — "Looks like" / "may be" / "starting to" are the words the
        // brief calls out. A single prefix is enough; double-hedging
        // reads as defensiveness.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let body: String = {
            // Drop a leading capital so the joined sentence reads
            // naturally ("Looks like your dinners ..." not "Looks
            // like Your dinners ...").
            guard let first = trimmed.first else { return trimmed }
            return first.lowercased() + trimmed.dropFirst()
        }()
        return "Looks like " + body
    }
}

// MARK: - FoodOSCopySafety
//
// Extended copy-safety guard for the storytelling layer. Wraps
// `FoodOSMomentCopySafety.bannedFragments` and adds the calmer,
// storytelling-specific bans the brief calls out — "bad food",
// "shouldn't", explicit "diagnosis", "moralizing" patterns — without
// modifying the lower-level engine guard (which has its own tests).
//
// Use this in new copy-building paths; legacy paths that already pass
// through `FoodOSMomentCopySafety` keep working unchanged.

enum FoodOSCopySafety {

    /// Additional fragments the storytelling layer rejects on top of
    /// `FoodOSMomentCopySafety.bannedFragments`. Lowercase, matched
    /// case-insensitively as substrings.
    static let extraBannedFragments: [String] = [
        "bad food",
        "good food",
        "diagnosis",
        "should eat",
        "shame on",
        "you are bad",
        "guilt-free", // common diet-culture marker
        "cheat day",
        "willpower"
    ]

    /// Full union of the engine-level fragments and the storytelling
    /// additions. Exposed for tests and for ad-hoc guard call sites.
    static var bannedFragments: [String] {
        FoodOSMomentCopySafety.bannedFragments + extraBannedFragments
    }

    /// True when none of the union's fragments appear in `text`.
    static func isSafe(_ text: String) -> Bool {
        let lower = text.lowercased()
        for fragment in bannedFragments {
            if lower.contains(fragment) { return false }
        }
        return true
    }
}
