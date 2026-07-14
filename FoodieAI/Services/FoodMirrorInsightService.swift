import Foundation

/// Pure, on-device summarizer for the Food Mirror tab. Reads a slice of
/// `FoodLog` history (the caller decides the window — typically last 7
/// and last 30 days) and produces a `FoodMirrorSummary` of patterns
/// worth surfacing.
///
/// Strictly read-only enrichment. Never calls Gemini, never mutates
/// `AnalyzeResponse`, never overrides saved calories or macros. The
/// "source of truth" for nutrition numbers remains the Gemini analysis
/// stored on each log; this service only counts, buckets, and compares.
///
/// All thresholds are tuned to keep the surface honest:
///   - < 3 logs in the 30-day window → empty.
///   - mood insight requires ≥ 2 mood-labeled logs AND ≥ 60% dominance.
///   - timing insight requires breakfast/lunch/dinner buckets each
///     populated to a minimum sample size.
///   - top foods require ≥ 2 occurrences.
struct FoodMirrorInsightService {

    /// Bucketed eating windows. The boundaries are intentionally wide
    /// — KST/JST users (a known cohort) often dine after 8pm and a
    /// strict "dinner ≤ 7pm" cutoff would silently drop signal.
    static let breakfastHours: Range<Int> = 4..<11
    static let lunchHours:     Range<Int> = 11..<16
    static let dinnerHours:    Range<Int> = 16..<22

    // MARK: - Entry points

    /// Compute the Food Mirror summary from the 30-day window. The
    /// 7-day window is used only to scope the "weekly reflection"
    /// line; everything else looks at the longer window.
    ///
    /// `previousSevenDayLogs` powers the "This Week Changed" card —
    /// it should cover the 7-day window immediately *before* the
    /// current week (typically days -7 through -13 from today). The
    /// caller slices it from the same 30-day fetch to avoid an extra
    /// PostgREST round-trip. Empty/nil is fine and just suppresses
    /// the comparison.
    ///
    /// `now` and `timeZone` are injected so tests are deterministic
    /// regardless of when/where they run.
    static func compute(thirtyDayLogs: [FoodLog],
                        sevenDayLogs: [FoodLog],
                        previousSevenDayLogs: [FoodLog] = [],
                        now: Date = Date(),
                        timeZone: TimeZone = .current) -> FoodMirrorSummary {
        let progress = LearningProgress.from(thirtyDayLogCount: thirtyDayLogs.count)

        let topFoods = mostCommonFoods(in: thirtyDayLogs, limit: 3)
        let weekly   = weeklyReflection(sevenDayLogs)
        let mood     = moodInsight(in: thirtyDayLogs)
        let timing   = timingInsight(in: thirtyDayLogs, timeZone: timeZone)
        let identity = eatingIdentity(
            thirtyDayLogs: thirtyDayLogs,
            topFoods:      topFoods,
            timing:        timing
        )
        let experiment = suggestedExperiment(
            thirtyDayLogs: thirtyDayLogs,
            timing:        timing,
            mood:          mood,
            topFoods:      topFoods
        )
        let changed = thisWeekChangedInsight(
            currentWeek:  sevenDayLogs,
            previousWeek: previousSevenDayLogs,
            timeZone:     timeZone
        )
        let nudge = todaysGentleNudge(
            thirtyDayLogs: thirtyDayLogs,
            sevenDayLogs:  sevenDayLogs,
            timing:        timing,
            timeZone:      timeZone
        )

        let moodLogCount = thirtyDayLogs.reduce(into: 0) { count, log in
            if log.mood != nil { count += 1 }
        }

        return FoodMirrorSummary(
            hasEnoughData:       progress.state == .ready,
            learningProgress:    progress,
            thirtyDayLogCount:   thirtyDayLogs.count,
            sevenDayLogCount:    sevenDayLogs.count,
            moodLogCount:        moodLogCount,
            eatingIdentity:      identity,
            weeklySummary:       weekly,
            mostCommonFoods:     topFoods,
            moodInsight:         mood,
            timingInsight:       timing?.copy,
            thisWeekChanged:     changed,
            todaysGentleNudge:   nudge,
            suggestedExperiment: experiment
        )
    }

    // MARK: - Most common foods

    /// Normalizes each log's food name (case + whitespace insensitive)
    /// and returns the top `limit` foods that occur at least twice.
    /// The display name returned to callers is the most recent
    /// raw name the user typed/saved for that normalized key — so
    /// "Chicken Rice" beats "chicken  rice" in casing.
    static func mostCommonFoods(in logs: [FoodLog],
                                limit: Int = 3) -> [FoodMirrorSummary.FoodCount] {
        struct Bucket {
            var displayName: String
            var count: Int
            var mostRecent: Date
        }
        var buckets: [String: Bucket] = [:]
        for log in logs {
            let key = LocalNutritionBeliefStore.normalize(log.foodName)
            guard !key.isEmpty else { continue }
            if var existing = buckets[key] {
                existing.count += 1
                if log.eatenAt > existing.mostRecent {
                    existing.mostRecent = log.eatenAt
                    existing.displayName = log.foodName
                }
                buckets[key] = existing
            } else {
                buckets[key] = Bucket(
                    displayName: log.foodName,
                    count:       1,
                    mostRecent:  log.eatenAt
                )
            }
        }
        return buckets.values
            .filter { $0.count >= 2 }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.mostRecent > rhs.mostRecent
            }
            .prefix(limit)
            .map { FoodMirrorSummary.FoodCount(name: $0.displayName, count: $0.count) }
    }

    // MARK: - Weekly reflection

    /// "You logged 12 meals this past week, averaging 540 kcal."
    /// Nil when the 7-day window holds fewer than 3 logs — anything
    /// thinner would overclaim from a near-empty sample.
    private static func weeklyReflection(_ logs: [FoodLog]) -> String? {
        guard logs.count >= 3 else { return nil }
        let calorieValues = logs.map(\.calories).filter { $0.isFinite && $0 > 0 }
        guard !calorieValues.isEmpty else {
            return "You logged \(logs.count) meals this past week."
        }
        let avg = calorieValues.reduce(0, +) / Double(calorieValues.count)
        let rounded = Int(avg.rounded())
        return "You logged \(logs.count) meals this past week, averaging about \(rounded) kcal."
    }

    // MARK: - Mood insight

    /// Returns a sentence only when the 30-day mood histogram has ≥ 2
    /// reports AND one mood holds ≥ 60% of the sample. Anything
    /// thinner stays silent — we'd be inventing a pattern otherwise.
    private static func moodInsight(in logs: [FoodLog]) -> String? {
        var loved = 0, fine = 0, tough = 0
        for log in logs {
            switch log.mood {
            case .loved: loved += 1
            case .fine:  fine  += 1
            case .tough: tough += 1
            case .none:  break
            }
        }
        let total = loved + fine + tough
        guard total >= 2 else { return nil }
        let pairs: [(FoodLog.Mood, Int)] = [
            (.loved, loved), (.fine, fine), (.tough, tough)
        ]
        guard let top = pairs.max(by: { $0.1 < $1.1 }) else { return nil }
        let share = Double(top.1) / Double(total)
        guard share >= 0.6 else { return nil }

        switch top.0 {
        case .loved:
            return "You've felt good after most of your meals lately."
        case .fine:
            return "Most of your recent meals have left you feeling fine, steady ground."
        case .tough:
            return "More of your recent meals than usual have felt tough afterwards."
        }
    }

    // MARK: - Timing insight

    /// Internal struct: the breakfast/lunch/dinner stats we derive
    /// from a 30-day window. Carries both the human copy and the raw
    /// averages so `suggestedExperiment` can decide whether to nudge
    /// toward a lighter dinner without re-computing the buckets.
    struct TimingStats {
        let breakfastCount: Int
        let lunchCount: Int
        let dinnerCount: Int
        let breakfastAvgKcal: Double
        let lunchAvgKcal: Double
        let dinnerAvgKcal: Double
        let copy: String
    }

    /// Buckets logs into breakfast/lunch/dinner by *local* hour and
    /// returns a sentence comparing dinner vs lunch only when each
    /// bucket has at least 3 entries. We deliberately avoid claiming
    /// anything from a single sample.
    static func timingInsight(in logs: [FoodLog],
                              timeZone: TimeZone = .current) -> TimingStats? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        var bCount = 0, lCount = 0, dCount = 0
        var bSum = 0.0,  lSum = 0.0,  dSum = 0.0

        for log in logs {
            let hour = cal.component(.hour, from: log.eatenAt)
            let cals = log.calories.isFinite ? log.calories : 0
            if breakfastHours.contains(hour) {
                bCount += 1; bSum += cals
            } else if lunchHours.contains(hour) {
                lCount += 1; lSum += cals
            } else if dinnerHours.contains(hour) {
                dCount += 1; dSum += cals
            }
        }

        let bAvg = bCount > 0 ? bSum / Double(bCount) : 0
        let lAvg = lCount > 0 ? lSum / Double(lCount) : 0
        let dAvg = dCount > 0 ? dSum / Double(dCount) : 0

        // Need lunch + dinner both well-populated to make the
        // headline comparison. Breakfast is informational only.
        guard lCount >= 3, dCount >= 3, lAvg > 0 else { return nil }

        let ratio = dAvg / lAvg
        let copy: String
        if ratio >= 1.25 {
            copy = "Your dinners tend to be heavier than your lunches (about \(Int(dAvg.rounded())) vs \(Int(lAvg.rounded())) kcal on average)."
        } else if ratio <= 0.8 {
            copy = "Your lunches tend to be heavier than your dinners (about \(Int(lAvg.rounded())) vs \(Int(dAvg.rounded())) kcal on average)."
        } else {
            copy = "Your lunches and dinners look pretty balanced (around \(Int(lAvg.rounded())) and \(Int(dAvg.rounded())) kcal on average)."
        }

        return TimingStats(
            breakfastCount:    bCount,
            lunchCount:        lCount,
            dinnerCount:       dCount,
            breakfastAvgKcal:  bAvg,
            lunchAvgKcal:      lAvg,
            dinnerAvgKcal:     dAvg,
            copy:              copy
        )
    }

    // MARK: - Eating identity

    /// One soft, descriptive line — never prescriptive, never clinical.
    /// Returns nil when the data doesn't support any honest framing.
    ///
    /// Delegates to `FoodOSStoryBuilder.heroIdentityLine` so the hero
    /// copy obeys the project rule "never claim 'rarely repeat' when
    /// a food has crossed the anchor floor" — the headline trust
    /// problem the storytelling pass was written to fix. The
    /// dinner-leans-heavier branch stays here because it's purely a
    /// timing observation, not a repeat-vs-explore claim.
    private static func eatingIdentity(thirtyDayLogs: [FoodLog],
                                       topFoods: [FoodMirrorSummary.FoodCount],
                                       timing: TimingStats?) -> String? {
        guard thirtyDayLogs.count >= 5 else { return nil }

        let uniqueFoods = Set(thirtyDayLogs.map {
            LocalNutritionBeliefStore.normalize($0.foodName)
        })

        if let line = FoodOSStoryBuilder.heroIdentityLine(
            thirtyDayLogCount: thirtyDayLogs.count,
            topFoods:          topFoods,
            uniqueFoodCount:   uniqueFoods.count
        ) {
            return line
        }

        // Timing-leaning fallback — only when no repeat-or-explore
        // line surfaced. Keeps "bigger evening meals" out of the way
        // of the anchor / explorer story when those apply.
        if let timing, timing.dinnerCount >= 3, timing.lunchCount >= 3,
           timing.dinnerAvgKcal >= timing.lunchAvgKcal * 1.25 {
            return "Your eating leans toward bigger evening meals."
        }

        return nil
    }

    // MARK: - Suggested experiment

    /// Small, safe, time-boxed nudge. Picked from a short list of
    /// gentle prompts based on what the data actually shows; falls
    /// back to a benign default when nothing stands out. Deliberately
    /// avoids language that could read as medical advice.
    private static func suggestedExperiment(thirtyDayLogs: [FoodLog],
                                            timing: TimingStats?,
                                            mood: String?,
                                            topFoods: [FoodMirrorSummary.FoodCount]) -> String? {
        guard thirtyDayLogs.count >= 5 else { return nil }

        if let timing,
           timing.dinnerAvgKcal >= timing.lunchAvgKcal * 1.25,
           timing.dinnerCount >= 3,
           timing.lunchCount >= 3 {
            return "Try a lighter dinner for 3 days and see how it feels."
        }

        let sugarValues = thirtyDayLogs.map(\.sugarG).filter { $0.isFinite }
        if !sugarValues.isEmpty {
            let avgSugar = sugarValues.reduce(0, +) / Double(sugarValues.count)
            if avgSugar >= 25 {
                return "Try swapping one sugary item for fruit for the next 3 days."
            }
        }

        if let mood, mood.lowercased().contains("tough") {
            return "This week, try repeating one meal you've genuinely enjoyed."
        }

        if topFoods.isEmpty {
            return "Try logging two meals from the same kitchen this week, patterns get easier to spot."
        }

        return "Try adding a vegetable to one meal a day for the next 3 days."
    }

    // MARK: - This Week Changed

    /// Minimum logs per period before any comparison runs. Both
    /// windows must clear this floor — comparing a 7-meal week to a
    /// 1-meal week would generate noise, not signal.
    static let weekChangeMinLogs = 3

    /// Relative-change band: anything inside ±15% reads as "about the
    /// same week" and stays silent. Set per the spec's 15–20%
    /// conservative range.
    static let weekChangeRelativeBand: Double = 0.15

    /// Compares the current and previous 7-day windows and returns at
    /// most one short, gentle sentence describing the largest
    /// meaningful change. Returns nil if either period is too thin or
    /// nothing crosses the conservative thresholds.
    ///
    /// Priority order when multiple signals trigger: dinner-shift,
    /// calorie-shift, protein-up, sugar-shift, logging-count-shift.
    /// We pick one so the card stays a single line — choosing the
    /// most behaviorally-anchored signal first.
    static func thisWeekChangedInsight(currentWeek: [FoodLog],
                                       previousWeek: [FoodLog],
                                       timeZone: TimeZone = .current) -> String? {
        guard currentWeek.count   >= weekChangeMinLogs,
              previousWeek.count  >= weekChangeMinLogs else {
            return nil
        }

        // 1. Dinner shift — most behaviorally anchored.
        if let line = dinnerChangeLine(current: currentWeek,
                                       previous: previousWeek,
                                       timeZone: timeZone) {
            return line
        }

        // 2. Overall calorie shift (per-meal average, not weekly total —
        // weekly total swings on log count alone).
        if let line = avgKcalChangeLine(current: currentWeek,
                                        previous: previousWeek) {
            return line
        }

        // 3. Protein up — positive framing, no shame on decrease.
        if let line = proteinIncreaseLine(current: currentWeek,
                                          previous: previousWeek) {
            return line
        }

        // 4. Sugar shift — neutral both directions.
        if let line = sugarChangeLine(current: currentWeek,
                                      previous: previousWeek) {
            return line
        }

        // 5. Logging cadence shift — last because it doesn't speak
        // to what the user ate, only how often they logged.
        if let line = logCountChangeLine(current: currentWeek,
                                         previous: previousWeek) {
            return line
        }

        return nil
    }

    private static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    private static func dinnerLogs(_ logs: [FoodLog],
                                   timeZone: TimeZone) -> [FoodLog] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return logs.filter {
            dinnerHours.contains(cal.component(.hour, from: $0.eatenAt))
        }
    }

    /// Dinner average kcal needs ≥3 dinners in each week, ≥20%
    /// relative change, and an absolute swing ≥100 kcal so a tiny
    /// shift on small portions doesn't trigger.
    private static func dinnerChangeLine(current: [FoodLog],
                                         previous: [FoodLog],
                                         timeZone: TimeZone) -> String? {
        let curDinners  = dinnerLogs(current,  timeZone: timeZone)
        let prevDinners = dinnerLogs(previous, timeZone: timeZone)
        guard curDinners.count  >= 3,
              prevDinners.count >= 3,
              let curAvg  = mean(curDinners.map(\.calories)),
              let prevAvg = mean(prevDinners.map(\.calories)),
              prevAvg > 0 else { return nil }

        let delta    = curAvg - prevAvg
        let relative = delta / prevAvg
        guard abs(relative) >= 0.20, abs(delta) >= 100 else { return nil }

        let direction = delta < 0 ? "lighter" : "heavier"
        let rounded   = Int(abs(delta).rounded())
        return "Your dinners ran about \(rounded) kcal \(direction) this week than last."
    }

    /// Per-meal calorie average: ≥20% relative change and ≥75 kcal
    /// absolute. Per-meal (not weekly total) so log-count changes
    /// don't dress up as calorie changes.
    private static func avgKcalChangeLine(current: [FoodLog],
                                          previous: [FoodLog]) -> String? {
        guard let curAvg  = mean(current.map(\.calories)),
              let prevAvg = mean(previous.map(\.calories)),
              prevAvg > 0 else { return nil }
        let delta    = curAvg - prevAvg
        let relative = delta / prevAvg
        guard abs(relative) >= 0.20, abs(delta) >= 75 else { return nil }

        let direction = delta < 0 ? "lighter" : "a bit heavier"
        let rounded   = Int(abs(delta).rounded())
        return "Your typical meal was about \(rounded) kcal \(direction) than last week."
    }

    /// Protein-up only (positive framing, no shame on decrease).
    /// Needs ≥3 protein-bearing logs in each week, ≥20% relative
    /// rise, and ≥5g absolute lift so single rounding doesn't trigger.
    private static func proteinIncreaseLine(current: [FoodLog],
                                            previous: [FoodLog]) -> String? {
        let curProtein  = current.compactMap(\.proteinG).filter { $0 >= 0 }
        let prevProtein = previous.compactMap(\.proteinG).filter { $0 >= 0 }
        guard curProtein.count  >= 3,
              prevProtein.count >= 3,
              let curAvg  = mean(curProtein),
              let prevAvg = mean(prevProtein),
              prevAvg > 0 else { return nil }
        let delta    = curAvg - prevAvg
        let relative = delta / prevAvg
        guard relative >= 0.20, delta >= 5 else { return nil }

        let curRounded  = Int(curAvg.rounded())
        let prevRounded = Int(prevAvg.rounded())
        return "You leaned into more protein this week, about \(curRounded)g per meal vs \(prevRounded)g last week."
    }

    /// Sugar shift, ≥20% relative and ≥5g absolute. Both directions
    /// get neutral wording — "settled lower" / "averaged a bit
    /// higher" — to keep the surface non-judgemental.
    private static func sugarChangeLine(current: [FoodLog],
                                        previous: [FoodLog]) -> String? {
        let curSugar  = current.map(\.sugarG).filter { $0.isFinite }
        let prevSugar = previous.map(\.sugarG).filter { $0.isFinite }
        guard curSugar.count  >= 3,
              prevSugar.count >= 3,
              let curAvg  = mean(curSugar),
              let prevAvg = mean(prevSugar),
              prevAvg > 0 else { return nil }
        let delta    = curAvg - prevAvg
        let relative = delta / prevAvg
        guard abs(relative) >= 0.20, abs(delta) >= 5 else { return nil }

        if delta < 0 {
            let rounded = Int(abs(delta).rounded())
            return "Your sugar settled about \(rounded)g lower per meal than last week."
        } else {
            let rounded = Int(abs(delta).rounded())
            return "Your sugar averaged about \(rounded)g higher per meal than last week."
        }
    }

    /// Logging cadence change. Needs an absolute delta ≥3 logs AND
    /// ≥35% relative change so a tiny "4 vs 5" week doesn't read
    /// as a meaningful shift.
    private static func logCountChangeLine(current: [FoodLog],
                                           previous: [FoodLog]) -> String? {
        let cur = current.count
        let prev = previous.count
        guard prev > 0 else { return nil }
        let delta    = cur - prev
        let relative = Double(delta) / Double(prev)
        guard abs(delta) >= 3, abs(relative) >= 0.35 else { return nil }

        if delta > 0 {
            return "You logged \(delta) more meals this week than last."
        } else {
            return "You logged \(abs(delta)) fewer meals this week than last."
        }
    }

    // MARK: - Today's gentle nudge

    /// Minimum total logs in the 30-day window before any nudge runs.
    /// Higher than the empty-state floor (3) on purpose — a nudge is
    /// a small action, so we want at least a couple of weeks of data
    /// supporting it.
    static let nudgeMinThirtyDayLogs = 8

    /// One small, optional suggestion for *today*, drawn from the
    /// user's recent pattern. Phrased as a soft invitation ("Try…",
    /// "Maybe…", "If you're in the mood…"), never a directive, and
    /// never with medical or shame language.
    ///
    /// Priority order, picking the first that triggers:
    ///   1. Lighter-dinner nudge (when dinners run consistently
    ///      heavier than lunches over 30 days AND that pattern shows
    ///      up in the current week too).
    ///   2. More-protein nudge (when 30-day protein average is low
    ///      relative to a soft 20g/meal reference and the current
    ///      week is still on the low side).
    ///   3. Lower-sugar nudge (when 30-day sugar average has been
    ///      consistently high AND the current week is also high —
    ///      avoids nudging the user who already cleaned up this week).
    ///   4. Positive-mood food nudge (when a single food has ≥2
    ///      "loved" reports AND no "tough" reports). Cites the food
    ///      so it reads warmly, not robotically.
    ///
    /// Returns nil when nothing surfaces — silence beats a generic
    /// nudge that doesn't fit the data.
    static func todaysGentleNudge(thirtyDayLogs: [FoodLog],
                                  sevenDayLogs: [FoodLog],
                                  timing: TimingStats?,
                                  timeZone: TimeZone = .current) -> String? {
        guard thirtyDayLogs.count >= nudgeMinThirtyDayLogs else { return nil }

        // 1. Lighter dinner — long-term pattern + current week echoes it.
        if let timing,
           timing.dinnerCount >= 3,
           timing.lunchCount  >= 3,
           timing.dinnerAvgKcal >= timing.lunchAvgKcal * 1.25 {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let recentDinners = sevenDayLogs.filter {
                dinnerHours.contains(cal.component(.hour, from: $0.eatenAt))
            }
            if recentDinners.count >= 2,
               let recentAvg = mean(recentDinners.map(\.calories)),
               recentAvg >= timing.lunchAvgKcal * 1.15 {
                return "Try keeping dinner a little lighter today, your evenings have been running heavy."
            }
        }

        // 2. More protein — 30d average low AND current week still low.
        let proteinValues30 = thirtyDayLogs.compactMap(\.proteinG).filter { $0 >= 0 }
        let proteinValues7  = sevenDayLogs.compactMap(\.proteinG).filter  { $0 >= 0 }
        if proteinValues30.count >= 5,
           let avg30 = mean(proteinValues30),
           avg30 < 15 {
            let avg7 = mean(proteinValues7) ?? avg30
            if avg7 < 18 {
                return "Maybe make space for a protein-rich meal today, something like eggs, fish, or beans."
            }
        }

        // 3. Lower sugar — 30d high AND current week still high.
        let sugarValues30 = thirtyDayLogs.map(\.sugarG).filter { $0.isFinite }
        let sugarValues7  = sevenDayLogs.map(\.sugarG).filter  { $0.isFinite }
        if sugarValues30.count >= 5,
           let avg30 = mean(sugarValues30),
           avg30 >= 20 {
            let avg7 = mean(sugarValues7) ?? avg30
            if avg7 >= 15 {
                return "If today's an option, a lower-sugar choice might feel good."
            }
        }

        // 4. Positive mood-linked food — at least 2 "loved" reports
        // for a single food and no "tough" reports for it.
        struct MoodBucket {
            var displayName: String
            var loved: Int
            var tough: Int
        }
        var moodBuckets: [String: MoodBucket] = [:]
        for log in thirtyDayLogs {
            guard let mood = log.mood else { continue }
            let key = LocalNutritionBeliefStore.normalize(log.foodName)
            guard !key.isEmpty else { continue }
            var bucket = moodBuckets[key] ?? MoodBucket(
                displayName: log.foodName, loved: 0, tough: 0
            )
            switch mood {
            case .loved: bucket.loved += 1
            case .tough: bucket.tough += 1
            case .fine:  break
            }
            moodBuckets[key] = bucket
        }
        let favorite = moodBuckets.values
            .filter { $0.loved >= 2 && $0.tough == 0 }
            .max { $0.loved < $1.loved }
        if let favorite {
            return FoodOSStoryBuilder.positiveMoodFoodNudge(
                food:        favorite.displayName,
                lovedCount:  favorite.loved
            )
        }

        return nil
    }
}

// MARK: - Presentation helpers

/// Purely presentational helpers for the Mirror surfaces. Render
/// "evidence" and "freshness" captions in a consistent, warm voice
/// without scattering the copy across views.
///
/// These never gate behavior — callers pass in whatever they have
/// and the helpers decide whether to surface a string. Returning nil
/// is normal and means "stay silent rather than overclaim."
enum FoodMirrorPresentation {

    /// One-line evidence caption derived from the summary's log
    /// counts. Cites meals and (optionally) mood notes so the user
    /// can see the substrate the Mirror is reflecting back. Returns
    /// nil when the 30-day window is too thin to claim anything
    /// stronger than the learning state already says.
    ///
    ///   30+ meals  → "Based on 30 days of meals and N mood notes."
    ///                (mood clause dropped if N == 0)
    ///   ≥ 8 meals  → "Based on X meals and Y mood notes logged."
    ///   ≥ 3 meals  → "Based on your recent meals."
    ///   else       → nil
    static func evidenceLine(for summary: FoodMirrorSummary) -> String? {
        let meals = summary.thirtyDayLogCount
        let moods = summary.moodLogCount
        if meals >= 20 {
            if moods >= 1 {
                let noun = moods == 1 ? "mood note" : "mood notes"
                return "Based on 30 days of meals and \(moods) \(noun)."
            }
            return "Based on 30 days of meals."
        }
        if meals >= summary.learningProgress.target {
            let mealNoun = meals == 1 ? "meal" : "meals"
            if moods >= 1 {
                let moodNoun = moods == 1 ? "mood note" : "mood notes"
                return "Based on \(meals) \(mealNoun) and \(moods) \(moodNoun)."
            }
            return "Based on \(meals) \(mealNoun) logged."
        }
        if meals >= 3 {
            return "Based on your recent meals."
        }
        return nil
    }

    /// "Updated …" caption derived from the time elapsed since the
    /// last successful refresh. Returns nil when `updatedAt` is nil
    /// (we've never completed a refresh yet) so the caller can hide
    /// the line entirely rather than render placeholder text.
    ///
    ///   < 60s            → "Updated just now"
    ///   < 60min          → "Updated N min ago"
    ///   same local day   → "Updated today"
    ///   prior local day  → "Updated yesterday"
    ///   older            → "Updated on <Mon D>"
    static func freshnessLine(updatedAt: Date?,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> String? {
        guard let updatedAt else { return nil }
        let delta = now.timeIntervalSince(updatedAt)
        if delta < 60 { return "Updated just now" }
        if delta < 60 * 60 {
            let minutes = max(1, Int(delta / 60))
            return "Updated \(minutes) min ago"
        }
        // Use the supplied calendar's timezone — tests can pin this.
        let cal = calendar
        let startOfNow      = cal.startOfDay(for: now)
        let startOfUpdated  = cal.startOfDay(for: updatedAt)
        let dayDelta = cal.dateComponents([.day],
                                          from: startOfUpdated,
                                          to: startOfNow).day ?? 0
        if dayDelta <= 0 { return "Updated today" }
        if dayDelta == 1 { return "Updated yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = cal.locale ?? .current
        formatter.timeZone = cal.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return "Updated on \(formatter.string(from: updatedAt))"
    }
}

// MARK: - Summary model

/// Read-only summary produced by `FoodMirrorInsightService`. Carries
/// only derived strings + small counts — no Gemini fields, no
/// adjusted calories, no override surface. The view layer decides
/// which cards to render based on which fields are non-nil/non-empty.
struct FoodMirrorSummary: Equatable {
    /// True when the 30-day window held enough logs to surface the
    /// "normal" insight experience (≥ 8). Below that, the view falls
    /// back to the progressive "Mirror is learning" card and ignores
    /// any insights that happened to compute on the thin window.
    ///
    /// Equivalent to `learningProgress.state == .ready`. Kept as its
    /// own field so call sites stay readable.
    let hasEnoughData: Bool

    /// Where the user sits on the "learning curve" — drives the
    /// progressive empty state in `FoodMirrorView`. Always populated;
    /// `.ready` simply means the curve is complete.
    let learningProgress: LearningProgress

    /// Unclamped 30-day log count. `learningProgress.mealsLoggedInWindow`
    /// caps at `target` (8); this raw count lets surfaces describe the
    /// evidence base honestly once the user is past the readiness floor
    /// ("Based on 22 meals logged" vs the clamped "8 of 8 meals").
    let thirtyDayLogCount: Int

    /// Raw 7-day log count — used by the Mirror's evidence/freshness
    /// caption alongside the 30-day count. Purely descriptive; never
    /// gates insight computation.
    let sevenDayLogCount: Int

    /// Number of logs in the 30-day window that carry a non-nil mood.
    /// Surfaced in the Mirror's evidence line ("based on 12 meals and
    /// 5 mood notes") so users can see the substrate the surface is
    /// reflecting back to them.
    let moodLogCount: Int

    let eatingIdentity: String?
    let weeklySummary: String?
    let mostCommonFoods: [FoodCount]
    let moodInsight: String?
    let timingInsight: String?
    /// Single sentence comparing the current 7-day window against the
    /// previous 7-day window. Nil unless both periods carry enough
    /// data AND the change passes the conservative threshold — the
    /// surface stays silent rather than overclaim a flat week.
    let thisWeekChanged: String?
    /// One small, optional suggestion for today drawn from the user's
    /// recent pattern. Phrased as a soft invitation, never a
    /// directive. Nil when the data doesn't support a confident,
    /// non-shaming nudge.
    let todaysGentleNudge: String?
    let suggestedExperiment: String?

    /// Convenience: true when at least one content-bearing field has
    /// something to show. The view uses this alongside `hasEnoughData`
    /// to decide between empty state and content state.
    var hasAnyContent: Bool {
        eatingIdentity      != nil ||
        weeklySummary       != nil ||
        !mostCommonFoods.isEmpty ||
        moodInsight         != nil ||
        timingInsight       != nil ||
        thisWeekChanged     != nil ||
        todaysGentleNudge   != nil ||
        suggestedExperiment != nil
    }

    static let empty = FoodMirrorSummary(
        hasEnoughData:       false,
        learningProgress:    LearningProgress.from(thirtyDayLogCount: 0),
        thirtyDayLogCount:   0,
        sevenDayLogCount:    0,
        moodLogCount:        0,
        eatingIdentity:      nil,
        weeklySummary:       nil,
        mostCommonFoods:     [],
        moodInsight:         nil,
        timingInsight:       nil,
        thisWeekChanged:     nil,
        todaysGentleNudge:   nil,
        suggestedExperiment: nil
    )

    /// One entry in `mostCommonFoods`. Display-name + count, nothing
    /// else — we deliberately don't surface average calories here to
    /// keep the card honest about being a count, not a calorie claim.
    struct FoodCount: Equatable {
        let name: String
        let count: Int
    }
}

// MARK: - Learning progress

/// Where the user sits on the "Mirror is learning" curve. Buckets
/// taken from the spec:
///   - 0 logs        → .empty           "waiting for first meal"
///   - 1–2 logs      → .starting        "starting to learn"
///   - 3–7 logs      → .formingPatterns "patterns are forming"
///   - 8+ logs       → .ready           normal insight experience
enum LearningState: String, Equatable {
    case empty
    case starting
    case formingPatterns
    case ready

    /// Card headline shown at the top of the learning state.
    var headline: String {
        switch self {
        case .empty:           return "Your mirror is waiting for your first meal."
        case .starting:        return "Your mirror is starting to learn."
        case .formingPatterns: return "Patterns are forming."
        case .ready:           return "Your mirror is ready."
        }
    }

    /// Short explanatory sentence that follows the headline. Stays
    /// warm and avoids implying anything is missing or wrong with
    /// the user — only the data set is "growing."
    var explanation: String {
        switch self {
        case .empty:
            return "As you log meals, patterns in your week start to show."
        case .starting:
            return "Each meal teaches your Mirror a little more about how you eat."
        case .formingPatterns:
            return "Early signals are showing up. A few more meals and the picture gets clearer."
        case .ready:
            return "There's enough here to see real patterns now."
        }
    }
}

/// Compact carrier passed into the view so the empty state can
/// render the headline, explanation, and a "X of N meals logged"
/// progress line without re-deriving anything.
struct LearningProgress: Equatable {
    let state: LearningState
    /// 30-day log count, clamped at `target` so the progress line
    /// never reads "9 of 8 meals logged."
    let mealsLoggedInWindow: Int
    /// Number of 30-day logs needed to reach `.ready`. Hard-coded to
    /// 8 per the spec; exposed so the view can render the denominator
    /// without re-typing the constant.
    let target: Int

    /// CTA copy fixed per the spec. Rendered as styled text (not a
    /// button) — the Mirror tab has no safe in-tree route to Home,
    /// so we keep the framing as an invitation rather than a tap target.
    var ctaText: String {
        "Log a few more meals to unlock your Food Mirror."
    }

    /// Convenience: `"X of 8 meals logged"`. Singular/plural handled.
    var progressText: String {
        let meals = mealsLoggedInWindow == 1 ? "meal" : "meals"
        return "\(mealsLoggedInWindow) of \(target) \(meals) logged"
    }

    /// Pure factory. Clamps the displayed count at `target` so the
    /// "X of 8" line stops growing once the user crosses the
    /// readiness threshold — and so the empty state itself stops
    /// rendering (callers gate on `state != .ready`).
    static func from(thirtyDayLogCount count: Int,
                     target: Int = 8) -> LearningProgress {
        let clamped = max(0, min(count, target))
        let state: LearningState
        switch count {
        case ..<1:   state = .empty
        case 1...2:  state = .starting
        case 3...7:  state = .formingPatterns
        default:     state = .ready
        }
        return LearningProgress(
            state:              state,
            mealsLoggedInWindow: clamped,
            target:             target
        )
    }
}
