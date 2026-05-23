import Foundation

// MARK: - FoodOSMoment
//
// One useful personal moment chosen by the FoodOS Moment Engine. The
// engine produces exactly one per refresh; the view layer renders it
// as a top-of-page card on the Food Mirror tab. Pure value type —
// never references Gemini, AnalyzeResponse, or any network surface.

/// The single "what FoodieAI is noticing right now" payload. Carries
/// pre-formatted display strings only — the view does no further
/// composition.
///
/// Always carries an `evidenceLine` when the moment makes a personal
/// claim (everything except the gentle-fallback). This keeps the
/// surface honest about the substrate it's reflecting back to the user.
struct FoodOSMoment: Equatable {
    /// Coarse taxonomy of moment shapes. Each maps to a distinct
    /// branch of the engine's priority chain.
    enum Kind: String, Equatable {
        case learning      // not enough data yet
        case recognition   // a repeated food / habit shows up
        case change        // this week differs meaningfully from last
        case nudge         // small, opt-in suggestion based on pattern
        case celebration   // consistency / logging cadence improved
        case experiment    // small, safe, time-boxed prompt
        case reflection    // gentle fallback — calm, never empty
        case revelation    // uncanny cross-variable connection
    }

    /// Confidence the engine has in this moment. Used by the view to
    /// tune supporting copy weight and (later) to gate haptics or
    /// surface prominence.
    enum Confidence: String, Equatable {
        case low, medium, high
    }

    let kind: Kind
    let title: String
    let body: String?
    let evidenceLine: String?
    let confidence: Confidence
    let actionLabel: String?
    /// Priority bucket used by the engine when it has more than one
    /// candidate. Higher = higher priority. Kept on the value so the
    /// view can later expose A/B telemetry on which branch fired.
    let priorityScore: Double
    let generatedAt: Date
}

// MARK: - FoodOSBeliefEngine
//
// Light Bayesian + slot-bucket statistics on a [FoodLog]. Stays small
// and pure on purpose — the engine layers on top consume these
// summaries to decide which moment to show.

/// Pure local belief layer. Translates `[FoodLog]` into mood
/// posteriors and meal-slot averages so the moment engine can make
/// claims that are honest about their evidence base.
enum FoodOSBeliefEngine {

    // MARK: Mood belief

    /// Beta-Binomial style posterior over "did the user feel good
    /// after this meal?" Treats `loved` + `fine` as positive,
    /// `tough` as negative, and adds a uniform Beta(1, 1) prior to
    /// keep tiny samples from looking certain.
    struct MoodBelief: Equatable {
        let positive: Int
        let negative: Int
        let total: Int
        /// `(positive + 1) / (positive + negative + 2)`. Bounded in
        /// (0, 1); never 0 or 1 even with zero observations.
        let posteriorPositiveMean: Double

        var hasEnoughEvidence: Bool { total >= 3 }
    }

    /// Compute the mood posterior from a batch of logs. Logs without
    /// a mood label are ignored (counted as "no observation," not
    /// "no opinion") so the posterior reflects actual reactions.
    static func moodBelief(in logs: [FoodLog]) -> MoodBelief {
        var loved = 0, fine = 0, tough = 0
        for log in logs {
            switch log.mood {
            case .loved: loved += 1
            case .fine:  fine  += 1
            case .tough: tough += 1
            case .none:  break
            }
        }
        let positive = loved + fine
        let negative = tough
        let total    = positive + negative
        let posterior = Double(positive + 1) / Double(positive + negative + 2)
        return MoodBelief(
            positive: positive,
            negative: negative,
            total:    total,
            posteriorPositiveMean: posterior
        )
    }

    // MARK: Meal slots

    /// Coarse eating windows used by the moment engine. Hours match
    /// `FoodMirrorInsightService` so a single user's "dinner" is the
    /// same window across both surfaces.
    enum Slot: String, Equatable {
        case breakfast
        case lunch
        case dinner
        case snack
    }

    /// Maps a local hour-of-day into a Slot. The breakfast/lunch/
    /// dinner ranges line up with the Mirror insight service; hours
    /// outside those ranges (very late night, very early morning,
    /// mid-afternoon) bucket as `.snack`.
    static func slot(forHour hour: Int) -> Slot {
        if FoodMirrorInsightService.breakfastHours.contains(hour) { return .breakfast }
        if FoodMirrorInsightService.lunchHours.contains(hour)     { return .lunch }
        if FoodMirrorInsightService.dinnerHours.contains(hour)    { return .dinner }
        return .snack
    }

    /// Aggregated stats for one meal slot. `count` is the sample
    /// size; the moment engine refuses to make a slot claim when
    /// `count < 3` so a single dinner doesn't masquerade as a habit.
    struct SlotStats: Equatable {
        let slot: Slot
        let count: Int
        let avgCalories: Double
        let avgProtein: Double
        let avgSugar: Double

        var hasEnoughEvidence: Bool { count >= 3 }
    }

    /// Compute stats for a single slot. Missing optional macros are
    /// skipped (not treated as zero) so a thin sample doesn't drag
    /// the average down to zero.
    static func slotStats(in logs: [FoodLog],
                          slot: Slot,
                          timeZone: TimeZone) -> SlotStats {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        var count = 0
        var calories: [Double] = []
        var protein:  [Double] = []
        var sugar:    [Double] = []

        for log in logs {
            let hour = cal.component(.hour, from: log.eatenAt)
            guard self.slot(forHour: hour) == slot else { continue }
            count += 1
            if log.calories.isFinite { calories.append(log.calories) }
            if let p = log.proteinG, p.isFinite { protein.append(p) }
            if log.sugarG.isFinite { sugar.append(log.sugarG) }
        }

        func mean(_ xs: [Double]) -> Double {
            guard !xs.isEmpty else { return 0 }
            return xs.reduce(0, +) / Double(xs.count)
        }

        return SlotStats(
            slot:        slot,
            count:       count,
            avgCalories: mean(calories),
            avgProtein:  mean(protein),
            avgSugar:    mean(sugar)
        )
    }
}

// MARK: - FoodOSAttentionEngine
//
// Lightweight "attention" over the user's past logs. Given a query
// (food name + slot + macros + current time), it scores each
// candidate log on six small heads and returns the top matches with
// their composite scores. The moment engine and the view layer can
// both consume this to surface evidence ("you've had something like
// this before") without LLMs or embeddings.

/// Pure scoring layer. Six small heads, summed with fixed weights;
/// no learned parameters. Deterministic and easy to reason about.
enum FoodOSAttentionEngine {

    /// What the engine knows about the "thing the user is looking at
    /// right now." All fields are optional so the engine can be
    /// queried from contexts that have only partial information
    /// (e.g., a slot-only query when no specific meal is in scope).
    struct Query: Equatable {
        let foodName: String?
        let slot: FoodOSBeliefEngine.Slot?
        let calories: Double?
        let proteinG: Double?
        let sugarG: Double?
        let mood: FoodLog.Mood?
        let now: Date
    }

    /// Decomposition of the composite score. Surfaced for tests and
    /// future UI ("here's why this meal was picked as evidence").
    struct ScoreParts: Equatable {
        var recency: Double = 0
        var sameSlot: Double = 0
        var sameFood: Double = 0
        var similarMacros: Double = 0
        var moodRelevance: Double = 0
        var surprise: Double = 0
    }

    struct ScoredLog: Equatable {
        let log: FoodLog
        let score: Double
        let parts: ScoreParts
    }

    /// Weights of each head in the composite score. Chosen by hand
    /// to favor recency + repeated food, with macro similarity and
    /// mood as secondary signals.
    static let weights = ScoreParts(
        recency:        1.0,
        sameSlot:       0.7,
        sameFood:       1.5,
        similarMacros:  0.6,
        moodRelevance:  0.5,
        surprise:       0.3
    )

    /// Rank candidates. Returns up to `limit` ScoredLogs sorted by
    /// descending score, then by descending `eatenAt` to break ties.
    static func rank(candidates: [FoodLog],
                     query: Query,
                     timeZone: TimeZone,
                     limit: Int = 5) -> [ScoredLog] {
        var scored: [ScoredLog] = []
        scored.reserveCapacity(candidates.count)

        // Pre-compute the recent-week macro centroid for the
        // "surprise" head — distance from the user's typical meal.
        let recentAvgKcal = averageRecent(
            candidates: candidates,
            now:        query.now,
            daysBack:   7,
            keyPath:    \.calories
        )

        let queryTokens = query.foodName.map(tokenize) ?? []

        for log in candidates {
            var parts = ScoreParts()

            // Recency: 1 / (1 + daysAgo). Linear decay would be too
            // gentle; 1/(1+d) puts strong weight on the last 24h.
            let days = max(0, query.now.timeIntervalSince(log.eatenAt)
                              / (24 * 60 * 60))
            parts.recency = 1.0 / (1.0 + days)

            // Same slot: binary 1/0.
            if let slot = query.slot {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = timeZone
                let hour = cal.component(.hour, from: log.eatenAt)
                let logSlot = FoodOSBeliefEngine.slot(forHour: hour)
                parts.sameSlot = (logSlot == slot) ? 1.0 : 0.0
            }

            // Same food: Jaccard token overlap on normalized names.
            if !queryTokens.isEmpty {
                let logTokens = tokenize(log.foodName)
                parts.sameFood = jaccard(queryTokens, logTokens)
            }

            // Similar macros: 1 - normalized L1 across calories /
            // protein / sugar (when provided). Each axis clipped at
            // a coarse "characteristic scale" so a wild outlier on
            // one macro doesn't dominate.
            parts.similarMacros = macroSimilarity(query: query, log: log)

            // Mood relevance: a log carrying mood is more useful as
            // evidence than one without. Loved/tough alignment with
            // the query's mood (when present) bumps the score.
            if log.mood != nil {
                parts.moodRelevance = 0.5
                if let q = query.mood, q == log.mood {
                    parts.moodRelevance = 1.0
                }
            }

            // Surprise: how far this log's calories sit from the
            // recent average. Bounded so a one-off binge doesn't
            // overwhelm everything else.
            if let recentAvgKcal, recentAvgKcal > 0 {
                let delta = abs(log.calories - recentAvgKcal) / recentAvgKcal
                parts.surprise = min(delta, 1.0)
            }

            let total =
                parts.recency       * weights.recency +
                parts.sameSlot      * weights.sameSlot +
                parts.sameFood      * weights.sameFood +
                parts.similarMacros * weights.similarMacros +
                parts.moodRelevance * weights.moodRelevance +
                parts.surprise      * weights.surprise

            scored.append(ScoredLog(log: log, score: total, parts: parts))
        }

        // Stable sort: highest score wins; ties broken by recency.
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.log.eatenAt > $1.log.eatenAt
        }
        if scored.count > limit { scored.removeLast(scored.count - limit) }
        return scored
    }

    // MARK: helpers

    /// Lowercase, drop punctuation, split on whitespace. A `bag of
    /// tokens` is plenty for short food names like "Kimchi stew" or
    /// "Pad Thai" without dragging in stemmers or stopword lists.
    static func tokenize(_ s: String) -> Set<String> {
        let lower = s.lowercased()
        let allowed = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let cleaned = String(allowed)
        return Set(cleaned.split(separator: " ").map(String.init))
    }

    /// Jaccard similarity: |A ∩ B| / |A ∪ B|. Returns 0 when either
    /// side is empty so empty queries don't masquerade as matches.
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(inter) / Double(union)
    }

    /// 1 - mean normalized L1 distance across calories / protein /
    /// sugar. Only axes provided by both query and log contribute;
    /// if no axis is shared, returns 0 (no opinion).
    private static func macroSimilarity(query: Query, log: FoodLog) -> Double {
        var contributions: [Double] = []
        if let qc = query.calories {
            let scale = max(qc, 300)
            let d = abs(qc - log.calories) / scale
            contributions.append(max(0, 1 - d))
        }
        if let qp = query.proteinG, let lp = log.proteinG {
            let scale = max(qp, 20)
            let d = abs(qp - lp) / scale
            contributions.append(max(0, 1 - d))
        }
        if let qs = query.sugarG {
            let scale = max(qs, 15)
            let d = abs(qs - log.sugarG) / scale
            contributions.append(max(0, 1 - d))
        }
        guard !contributions.isEmpty else { return 0 }
        return contributions.reduce(0, +) / Double(contributions.count)
    }

    /// Average a keypath across logs eaten in the last `daysBack`
    /// days. Returns nil when no logs fall in the window or the
    /// keypath returns no finite values.
    private static func averageRecent(candidates: [FoodLog],
                                      now: Date,
                                      daysBack: Int,
                                      keyPath: KeyPath<FoodLog, Double>) -> Double? {
        let cutoff = now.addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
        let values = candidates
            .filter { $0.eatenAt >= cutoff }
            .map { $0[keyPath: keyPath] }
            .filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - FoodOSMomentCopySafety
//
// Last-line guard between the engine's authored copy and the view.
// The engine itself is written to avoid these patterns; the safety
// helper exists so a future contributor can't accidentally ship a
// shaming/medical/bossy line without a test failing first.

/// Pure copy-safety filter. Operates on the final assembled copy of
/// a moment (title + body + evidence). Returns false when ANY banned
/// fragment is present; the engine then substitutes a gentle
/// reflection fallback so the surface never goes blank.
enum FoodOSMomentCopySafety {

    /// Phrase fragments that disqualify a moment. Lowercase; matched
    /// case-insensitively. Phrasing is deliberate — single words
    /// like "fat" are excluded because they appear in legitimate
    /// macro discussions ("your fat intake"); we ban shaming
    /// *phrases* and clinically-loaded terms instead.
    static let bannedFragments: [String] = [
        // Certainty
        "always", "never",
        // Bossy / directive
        "you must", "must eat", "must stop",
        "you have to", "you need to",
        "should not", "shouldn't", "stop eating",
        // Shame
        "binge", "shame", "ashamed", "guilty",
        "obese", "obesity", "lazy",
        // Medical / scary
        "diagnose", "diabetes", "disease", "cure",
        "doctor", "medical", "prescription",
        "dangerous", "harmful"
    ]

    /// True when none of the banned fragments appear anywhere in
    /// the concatenated copy. Case-insensitive substring match.
    static func isSafe(title: String,
                       body: String?,
                       evidence: String?) -> Bool {
        let joined = [title, body ?? "", evidence ?? ""]
            .joined(separator: " ")
            .lowercased()
        for fragment in bannedFragments {
            if joined.contains(fragment) { return false }
        }
        return true
    }

    /// Convenience over a single string (used by tests and inline
    /// guards).
    static func isSafe(_ text: String) -> Bool {
        let lower = text.lowercased()
        for fragment in bannedFragments {
            if lower.contains(fragment) { return false }
        }
        return true
    }
}

// MARK: - FoodOSMomentEngine
//
// The thin layer that decides which one moment to show. Walks a
// fixed priority chain and returns the first branch that has enough
// evidence to fire honestly. Every branch attaches an evidenceLine
// when it makes a personal claim; the final result is run through
// `FoodOSMomentCopySafety` before being handed to callers.

/// Pure picker that turns a triplet of log windows into a single
/// `FoodOSMoment`. Deterministic for fixed inputs (no random
/// sampling, no time-of-day branching except via the supplied
/// `timeZone`).
enum FoodOSMomentEngine {

    /// Number of 30-day logs required before the engine will
    /// produce anything beyond the learning moment. Mirrors the
    /// `LearningProgress` readiness floor so the two surfaces
    /// agree on what "enough data" means.
    static let readinessFloor = 8

    /// Compute the single best moment for the current refresh.
    ///
    /// Priority chain:
    ///   1. learning (under the readiness floor)
    ///   2. revelation (paired-variable belief + surprise gate)
    ///   3. celebration (consistency improved week over week)
    ///   4. change (this week shifted meaningfully)
    ///   5. mood reflection (strong mood posterior + enough notes)
    ///   6. nudge (clear slot pattern — dinner heavier than lunch)
    ///   7. recognition (top food appears repeatedly)
    ///   8. gentle reflection fallback
    ///
    /// The first branch that fires wins. Safe by construction:
    /// unsafe copy falls back to the gentle reflection so callers
    /// always receive a non-nil moment.
    ///
    /// `preferences`, when non-empty, lets the FoodOS feedback loop
    /// gently boost or suppress moment tags the user has signalled
    /// for. The adjustment is bounded (±10 pts) so it can flip
    /// adjacent priority tiers but never override the learning gate
    /// or leapfrog the safety filter.
    static func compute(thirtyDayLogs: [FoodLog],
                        sevenDayLogs: [FoodLog],
                        previousSevenDayLogs: [FoodLog],
                        now: Date = Date(),
                        timeZone: TimeZone = .current,
                        preferences: [FoodOSMomentPreference] = [],
                        lastRevelationRepeatKey: String? = nil) -> FoodOSMoment {

        // 1. Learning gate. The learner never demotes the learning
        // moment — users below the readiness floor need the "still
        // learning" framing regardless of what the bandit thinks.
        if thirtyDayLogs.count < readinessFloor {
            return Self.learningMoment(thirtyDayLogs: thirtyDayLogs, now: now)
        }

        let moodLogCount = thirtyDayLogs.reduce(into: 0) { c, l in
            if l.mood != nil { c += 1 }
        }
        let evidenceLine = Self.evidenceLine(
            mealCount: thirtyDayLogs.count, moodCount: moodLogCount
        )

        // Walk candidates in priority order. The worked-before
        // candidate is V2 feedback-driven and only fires when the
        // user's own past "I'll try this" → positive mood resolutions
        // have built up enough evidence (≥2 positives, posterior ≥
        // 0.65, confidence medium or higher). It sits above the
        // generic nudge so a "what worked for you before" line takes
        // precedence over a fresh suggestion.
        let candidates: [() -> FoodOSMoment?] = [
            { revelationMoment(thirtyDayLogs: thirtyDayLogs,
                               timeZone: timeZone,
                               now: now,
                               lastRepeatKey: lastRevelationRepeatKey) },
            { celebrationMoment(current: sevenDayLogs,
                                previous: previousSevenDayLogs,
                                evidence: evidenceLine,
                                now: now) },
            { changeMoment(current: sevenDayLogs,
                           previous: previousSevenDayLogs,
                           timeZone: timeZone,
                           now: now) },
            { workedBeforeMoment(preferences: preferences, now: now) },
            { moodMoment(thirtyDayLogs: thirtyDayLogs,
                         moodLogCount: moodLogCount,
                         now: now) },
            { nudgeMoment(thirtyDayLogs: thirtyDayLogs,
                          timeZone: timeZone,
                          evidence: evidenceLine,
                          now: now) },
            { recognitionMoment(thirtyDayLogs: thirtyDayLogs,
                                evidence: evidenceLine,
                                now: now) }
        ]

        // Empty preferences → preserve the original priority-chain
        // behaviour exactly. Test #8 in the feedback suite relies on
        // this: the engine must be a fixed function of the logs
        // alone when no feedback has been recorded.
        if preferences.isEmpty {
            for produce in candidates {
                if let moment = produce(), Self.passesSafety(moment) {
                    return moment
                }
            }
            return fallbackMoment(evidence: evidenceLine, now: now)
        }

        // With feedback: materialize every candidate, apply the
        // bandit's adjustment to its priorityScore, and choose the
        // highest-scoring moment. We sort with an explicit
        // tie-breaker on the candidate's original priority so an
        // empty / all-zero adjustment vector reproduces the
        // priority-chain order byte-for-byte.
        struct Adjusted {
            let moment: FoodOSMoment
            let index: Int
            let adjustedScore: Double
        }
        var adjusted: [Adjusted] = []
        adjusted.reserveCapacity(candidates.count)
        for (i, produce) in candidates.enumerated() {
            guard let moment = produce() else { continue }
            let delta = FoodOSMomentBandit.adjustment(
                for: moment.momentTag, in: preferences
            )
            adjusted.append(Adjusted(
                moment: moment,
                index: i,
                adjustedScore: moment.priorityScore + delta
            ))
        }
        adjusted.sort { a, b in
            if a.adjustedScore != b.adjustedScore {
                return a.adjustedScore > b.adjustedScore
            }
            return a.index < b.index
        }
        for entry in adjusted {
            if Self.passesSafety(entry.moment) { return entry.moment }
        }
        return fallbackMoment(evidence: evidenceLine, now: now)
    }

    // MARK: - Separate mood + value revelations
    //
    // The priority-chain `compute(...)` above is unchanged — other
    // surfaces depend on its exact behavior. This independent pair of
    // entry points feeds the dedicated story cards: each revelation
    // type is gated only by its own signal and exposed as its own
    // FoodOSMoment so the deck can present them as distinct pages.

    /// Both revelation moments for this refresh, computed
    /// independently. Either or both may be nil when their own
    /// signal doesn't clear the surprise gate. `mood` is the same
    /// paired-belief output the priority chain returns; `value` is
    /// the new week-over-week trend output. Repeat keys are surfaced
    /// alongside each moment so the caller can suppress back-to-back
    /// repetition per type.
    struct FoodOSRevelations: Equatable {
        let mood: FoodOSMoment?
        let moodRepeatKey: String?
        let value: FoodOSMoment?
        let valueRepeatKey: String?
    }

    static func revelations(thirtyDayLogs: [FoodLog],
                            thisWeekLogs: [FoodLog],
                            lastWeekLogs: [FoodLog],
                            timeZone: TimeZone = .current,
                            now: Date = Date(),
                            lastMoodRepeatKey: String? = nil,
                            lastValueRepeatKey: String? = nil) -> FoodOSRevelations {
        // Mood revelation: gated by the learning floor so a brand-new
        // account can't surface one before the rest of FoodOS has
        // any data to lean on.
        let mood: FoodOSMoment? = {
            guard thirtyDayLogs.count >= readinessFloor else { return nil }
            guard let m = revelationMoment(
                thirtyDayLogs: thirtyDayLogs,
                timeZone:      timeZone,
                now:           now,
                lastRepeatKey: lastMoodRepeatKey
            ), Self.passesSafety(m) else { return nil }
            return m
        }()

        let valuePair = valueRevelationMoment(
            thisWeek:       thisWeekLogs,
            lastWeek:       lastWeekLogs,
            now:            now,
            lastRepeatKey:  lastValueRepeatKey
        )

        return FoodOSRevelations(
            mood:           mood,
            moodRepeatKey:  mood?.revelationRepeatKey,
            value:          valuePair?.moment,
            valueRepeatKey: valuePair?.repeatKey
        )
    }

    /// Wraps the best `ValueCandidate` (if any) into a FoodOSMoment
    /// with `kind: .revelation`. Reusing the existing kind keeps the
    /// feedback wiring (chips, bandit tags, copy-safety filter) the
    /// same as the mood revelation; the `momentTag` extension routes
    /// it to one of the new value tags via the unique evidence-line
    /// marker. Returns nil when the candidate fails the surprise gate
    /// or the assembled copy doesn't pass safety.
    private static func valueRevelationMoment(
        thisWeek: [FoodLog],
        lastWeek: [FoodLog],
        now: Date,
        lastRepeatKey: String?
    ) -> (moment: FoodOSMoment, repeatKey: String)? {
        guard let candidate = FoodOSPairedBeliefs.bestValueCandidate(
            thisWeek: thisWeek,
            lastWeek: lastWeek
        ) else { return nil }
        if let lastRepeatKey, candidate.repeatKey == lastRepeatKey {
            return nil
        }
        let moment = FoodOSMoment(
            kind:          .revelation,
            title:         candidate.title,
            body:          candidate.body,
            evidenceLine:  candidate.evidenceLine,
            confidence:    candidate.confidence,
            actionLabel:   nil,
            priorityScore: 95 + min(candidate.surpriseScore * 10, 4),
            generatedAt:   now
        )
        guard Self.passesSafety(moment) else { return nil }
        return (moment, candidate.repeatKey)
    }

    // MARK: branches

    private static func learningMoment(thirtyDayLogs: [FoodLog],
                                       now: Date) -> FoodOSMoment {
        let count = thirtyDayLogs.count
        let evidence: String = {
            if count == 0 { return "No meals logged yet." }
            let meals = count == 1 ? "meal" : "meals"
            return "Based on \(count) \(meals) logged."
        }()
        return FoodOSMoment(
            kind:         .learning,
            title:        "Your Food Mirror is still learning.",
            body:         "Log a few more meals and FoodieAI can start seeing stronger patterns.",
            evidenceLine: evidence,
            confidence:   .low,
            actionLabel:  "Log another meal",
            priorityScore: 100,
            generatedAt:   now
        )
    }

    private static func revelationMoment(thirtyDayLogs: [FoodLog],
                                         timeZone: TimeZone,
                                         now: Date,
                                         lastRepeatKey: String?) -> FoodOSMoment? {
        guard let belief = FoodOSPairedBeliefs.bestCandidate(
            in: thirtyDayLogs,
            timeZone: timeZone,
            excludingRepeatKey: lastRepeatKey
        ) else {
            return nil
        }
        return FoodOSMoment(
            kind:         .revelation,
            title:        belief.title,
            body:         belief.body,
            evidenceLine: belief.evidenceLine,
            confidence:   belief.confidence,
            actionLabel:  nil,
            priorityScore: 95 + min(belief.surpriseScore * 10, 4),
            generatedAt:   now
        )
    }

    /// Celebration fires when the user logged meaningfully more
    /// often this week than last (≥3 meals more AND ≥35% lift).
    /// Same thresholds as `logCountChangeLine` so the two surfaces
    /// agree on what "more consistent" means.
    private static func celebrationMoment(current: [FoodLog],
                                          previous: [FoodLog],
                                          evidence: String?,
                                          now: Date) -> FoodOSMoment? {
        let cur  = current.count
        let prev = previous.count
        guard prev > 0 else { return nil }
        let delta    = cur - prev
        let relative = Double(delta) / Double(prev)
        guard delta >= 3, relative >= 0.35 else { return nil }

        return FoodOSMoment(
            kind:         .celebration,
            title:        "You logged more consistently this week.",
            body:         "That gives your Food Mirror a clearer picture of your eating rhythm.",
            evidenceLine: FoodOSEvidenceBuilder.celebrationEvidence(
                currentCount:  cur,
                previousCount: prev
            ),
            confidence:   relative >= 0.6 ? .high : .medium,
            actionLabel:  "Keep logging mood notes to make this sharper.",
            priorityScore: 90,
            generatedAt:   now
        )
    }

    /// Change fires when this week's meals look meaningfully
    /// different from the previous week. Prioritizes dinner-average
    /// shifts (most behaviorally anchored), then per-meal calorie
    /// shifts. Both thresholds match the Mirror insight service so
    /// users see consistent framing across surfaces.
    private static func changeMoment(current: [FoodLog],
                                     previous: [FoodLog],
                                     timeZone: TimeZone,
                                     now: Date) -> FoodOSMoment? {
        guard current.count   >= FoodMirrorInsightService.weekChangeMinLogs,
              previous.count  >= FoodMirrorInsightService.weekChangeMinLogs else {
            return nil
        }

        // Dinner shift first — biggest behavioral signal.
        let curDinners  = filter(current,  to: .dinner, timeZone: timeZone)
        let prevDinners = filter(previous, to: .dinner, timeZone: timeZone)
        if curDinners.count >= 3, prevDinners.count >= 3 {
            let curAvg  = mean(curDinners.map(\.calories))
            let prevAvg = mean(prevDinners.map(\.calories))
            if prevAvg > 0 {
                let delta    = curAvg - prevAvg
                let relative = delta / prevAvg
                if abs(relative) >= 0.20, abs(delta) >= 100 {
                    let direction = delta < 0 ? "lighter" : "heavier"
                    return FoodOSMoment(
                        kind:         .change,
                        title:        "Your dinners look \(direction) this week.",
                        body:         "That shift may be worth noticing.",
                        evidenceLine: FoodOSEvidenceBuilder.changeEvidence(
                            label:       "dinner average",
                            previousAvg: prevAvg,
                            currentAvg:  curAvg
                        ),
                        confidence:   abs(relative) >= 0.35 ? .high : .medium,
                        actionLabel:  nil,
                        priorityScore: 80,
                        generatedAt:   now
                    )
                }
            }
        }

        // Per-meal calorie shift.
        let curAvg  = mean(current.map(\.calories))
        let prevAvg = mean(previous.map(\.calories))
        guard prevAvg > 0 else { return nil }
        let delta    = curAvg - prevAvg
        let relative = delta / prevAvg
        guard abs(relative) >= 0.20, abs(delta) >= 75 else { return nil }
        let direction = delta < 0 ? "lighter" : "a bit heavier"
        return FoodOSMoment(
            kind:         .change,
            title:        "Your meals ran \(direction) this week than last.",
            body:         "Worth noticing without changing anything yet.",
            evidenceLine: FoodOSEvidenceBuilder.changeEvidence(
                label:       "typical meal",
                previousAvg: prevAvg,
                currentAvg:  curAvg
            ),
            confidence:   abs(relative) >= 0.35 ? .high : .medium,
            actionLabel:  nil,
            priorityScore: 80,
            generatedAt:   now
        )
    }

    /// Mood reflection fires when at least 3 mood notes exist and
    /// the posterior leans strongly in one direction (≥0.75 = mostly
    /// good, ≤0.4 = tougher than usual). Threshold-asymmetry is
    /// intentional — we surface "tough" sooner because that's where
    /// a gentle reflection is most useful.
    private static func moodMoment(thirtyDayLogs: [FoodLog],
                                   moodLogCount: Int,
                                   now: Date) -> FoodOSMoment? {
        guard moodLogCount >= 3 else { return nil }
        let belief = FoodOSBeliefEngine.moodBelief(in: thirtyDayLogs)
        guard belief.hasEnoughEvidence else { return nil }

        let mean = belief.posteriorPositiveMean
        // Sharper evidence: "22 of 32 mood notes were fine or loved."
        // — describes the substrate the reflection is reading off so
        // the reader can see the basis without trusting the verdict
        // alone.
        let evidence = FoodOSEvidenceBuilder.moodEvidence(
            positive: belief.positive,
            total:    belief.total
        )
        let confidence: FoodOSMoment.Confidence = belief.total >= 6 ? .high : .medium

        if mean >= 0.75 {
            return FoodOSMoment(
                kind:         .reflection,
                title:        "Most recent meals have felt steady.",
                body:         "Your mood notes have been mostly fine or loved lately.",
                evidenceLine: evidence,
                confidence:   confidence,
                actionLabel:  nil,
                priorityScore: 70,
                generatedAt:   now
            )
        }
        if mean <= 0.4 {
            return FoodOSMoment(
                kind:         .reflection,
                title:        "Some recent meals have felt tougher.",
                body:         "Worth noticing — patterns shift slowly and gently.",
                evidenceLine: evidence,
                confidence:   confidence,
                actionLabel:  nil,
                priorityScore: 70,
                generatedAt:   now
            )
        }
        return nil
    }

    /// Nudge fires when the user has a clear slot pattern — dinners
    /// running ≥25% heavier than lunches over the 30-day window,
    /// with both slots well-populated. The copy stays a soft
    /// invitation ("Try…") rather than a directive.
    private static func nudgeMoment(thirtyDayLogs: [FoodLog],
                                    timeZone: TimeZone,
                                    evidence: String?,
                                    now: Date) -> FoodOSMoment? {
        let lunch  = FoodOSBeliefEngine.slotStats(
            in: thirtyDayLogs, slot: .lunch,  timeZone: timeZone
        )
        let dinner = FoodOSBeliefEngine.slotStats(
            in: thirtyDayLogs, slot: .dinner, timeZone: timeZone
        )
        guard lunch.hasEnoughEvidence, dinner.hasEnoughEvidence else { return nil }
        guard lunch.avgCalories > 0 else { return nil }

        let ratio = dinner.avgCalories / lunch.avgCalories
        guard ratio >= 1.25 else { return nil }

        return FoodOSMoment(
            kind:         .nudge,
            title:        "Try keeping dinner a little lighter today.",
            body:         "Your dinners have been running heavier than your lunches lately.",
            evidenceLine: FoodOSEvidenceBuilder.nudgeDinnerVsLunchEvidence(
                ratio: ratio
            ),
            confidence:   ratio >= 1.5 ? .high : .medium,
            actionLabel:  "Try the same move once more and see how it feels.",
            priorityScore: 60,
            generatedAt:   now
        )
    }

    // MARK: V2 — worked-before candidate
    //
    // Reflection-flavoured moment that surfaces only when the user's
    // own past "I'll try this" promises have closed with positive
    // mood notes. Gated by the learning floor at the top of compute()
    // (the early-return on `thirtyDayLogs.count < readinessFloor`) so
    // a brand-new account never sees it.
    //
    // Gating rules (spec):
    //   - preference.positiveMoodAfterTryCount >= 2
    //   - preference.posteriorMean              >= 0.65
    //   - preference.confidence != .low
    //
    // Tag for the moment is the preference's tag itself so the bandit
    // can keep tracking the same bucket. Copy stays carefully soft —
    // "seemed", "has helped before" — never causal, never medical.

    /// Minimum positive mood-after-try resolutions before this
    /// candidate is even considered. Two keeps the bar honest: one
    /// resolution is a coincidence; two starts to look like a real
    /// pattern.
    static let workedBeforePositiveFloor = 2
    /// Posterior threshold for the worked-before candidate. Matches
    /// the bandit's positive threshold so the two surfaces agree on
    /// what "strong positive" means.
    static let workedBeforePosteriorFloor = 0.65

    private static func workedBeforeMoment(
        preferences: [FoodOSMomentPreference],
        now: Date
    ) -> FoodOSMoment? {
        // Find the most convincing preference row. Highest positive
        // count wins; posterior breaks ties so an evenly-rated tag
        // with more evidence is preferred over a thinner one with
        // marginally higher posterior. Eligibility filter mirrors the
        // spec exactly.
        let eligible = preferences.filter { pref in
            pref.positiveMoodAfterTryCount >= workedBeforePositiveFloor
                && pref.posteriorMean >= workedBeforePosteriorFloor
                && pref.confidence != .low
        }
        guard let best = eligible.max(by: { a, b in
            if a.positiveMoodAfterTryCount != b.positiveMoodAfterTryCount {
                return a.positiveMoodAfterTryCount < b.positiveMoodAfterTryCount
            }
            return a.posteriorMean < b.posteriorMean
        }) else { return nil }

        let tries = best.willTryCount
        let positives = best.positiveMoodAfterTryCount
        let evidence: String = {
            // Prefer the richer "N tries with P positive mood notes."
            // when both counts are well-formed; fall back to the
            // safer generic line when either count would read oddly.
            if tries >= positives, tries > 0 {
                let tryNoun = tries == 1 ? "try" : "tries"
                let moodNoun = positives == 1 ? "positive mood note"
                                              : "positive mood notes"
                return "Based on \(tries) \(tryNoun) with \(positives) \(moodNoun)."
            }
            return "Based on your past experiment feedback."
        }()

        return FoodOSMoment(
            kind:         .experiment,
            title:        "This worked for you before.",
            body:         "When you tried this kind of moment before, "
                          + "your next mood note seemed steady or better.",
            evidenceLine: evidence,
            confidence:   best.confidence == .high ? .high : .medium,
            actionLabel:  nil,
            priorityScore: 75,
            generatedAt:   now
        )
    }

    /// Recognition fires when one food shows up at least 3 times in
    /// the 30-day window. Cites the food so the moment reads warmly
    /// rather than abstractly.
    private static func recognitionMoment(thirtyDayLogs: [FoodLog],
                                          evidence: String?,
                                          now: Date) -> FoodOSMoment? {
        let top = FoodMirrorInsightService.mostCommonFoods(
            in: thirtyDayLogs, limit: 1
        )
        guard let first = top.first, first.count >= 3 else { return nil }
        // Sharper evidence: "You logged Sweet potato 6 times in the
        // last 30 days." beats the generic "based on 30 days of
        // meals" line because the reader can see the substrate
        // immediately.
        let sharperEvidence = FoodOSEvidenceBuilder.recognitionEvidence(
            food:  first.name,
            count: first.count
        )
        // Anchor-grade copy only when the repeat clears the anchor
        // floor (5+). Below that, keep the softer "keeps showing up"
        // line so the moment never overclaims.
        //
        // Body is intentionally nil for anchor cards: title +
        // evidence + action already form the full CLAIM → EVIDENCE
        // → ACTION arc, and an extra supporting sentence reads as
        // filler on a calm card. The softer "showing up" branch
        // keeps its body because the action slot is empty.
        let title: String
        let body:  String?
        let actionLabel: String?
        if first.count >= FoodOSStoryBuilder.anchorFloor {
            title = "\(first.name) seems to be one of your reliable meals."
            body  = nil
            actionLabel = "Use it as today's anchor meal?"
        } else {
            title = "\(first.name) keeps showing up in your week."
            body  = "It may be becoming one of your regular meals."
            actionLabel = nil
        }
        _ = evidence  // older evidence is intentionally unused now
        return FoodOSMoment(
            kind:         .recognition,
            title:        title,
            body:         body,
            evidenceLine: sharperEvidence,
            confidence:   first.count >= 5 ? .high : .medium,
            actionLabel:  actionLabel,
            priorityScore: 50,
            generatedAt:   now
        )
    }

    /// Gentle fallback — never empty, never overclaims. Always safe
    /// by construction (no banned phrases).
    private static func fallbackMoment(evidence: String?, now: Date) -> FoodOSMoment {
        FoodOSMoment(
            kind:         .reflection,
            title:        "Your Food Mirror is getting clearer.",
            body:         "Keep logging meals and mood notes to reveal better patterns.",
            evidenceLine: evidence ?? "Based on your recent meals.",
            confidence:   .low,
            actionLabel:  nil,
            priorityScore: 10,
            generatedAt:   now
        )
    }

    // MARK: helpers

    /// Honest evidence string built from raw counts. Mirrors the
    /// `FoodMirrorPresentation` helper but kept local so the engine
    /// doesn't depend on the view-layer presentation type.
    static func evidenceLine(mealCount: Int, moodCount: Int) -> String? {
        if mealCount >= 20 {
            if moodCount >= 1 {
                let noun = moodCount == 1 ? "mood note" : "mood notes"
                return "Based on 30 days of meals and \(moodCount) \(noun)."
            }
            return "Based on 30 days of meals."
        }
        if mealCount >= readinessFloor {
            let mealNoun = mealCount == 1 ? "meal" : "meals"
            if moodCount >= 1 {
                let moodNoun = moodCount == 1 ? "mood note" : "mood notes"
                return "Based on \(mealCount) \(mealNoun) and \(moodCount) \(moodNoun)."
            }
            return "Based on \(mealCount) \(mealNoun) logged."
        }
        if mealCount >= 3 {
            return "Based on your recent meals."
        }
        return nil
    }

    private static func filter(_ logs: [FoodLog],
                               to slot: FoodOSBeliefEngine.Slot,
                               timeZone: TimeZone) -> [FoodLog] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return logs.filter {
            FoodOSBeliefEngine.slot(forHour: cal.component(.hour, from: $0.eatenAt)) == slot
        }
    }

    private static func mean(_ values: [Double]) -> Double {
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return 0 }
        return finite.reduce(0, +) / Double(finite.count)
    }

    private static func passesSafety(_ moment: FoodOSMoment) -> Bool {
        FoodOSMomentCopySafety.isSafe(
            title:    moment.title,
            body:     moment.body,
            evidence: moment.evidenceLine
        )
    }
}
