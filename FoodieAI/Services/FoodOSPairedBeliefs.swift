import Foundation

// MARK: - FoodOSPairedBeliefs
//
// Cross-variable observations for FoodOS revelation moments. These
// use the same Beta(1, 1) posterior as `FoodOSBeliefEngine.moodBelief`
// and keep the same count >= 3 evidence floor. Missing mood, macro,
// or timestamp data is skipped rather than treated as a negative.

enum FoodOSPairedBeliefs {
    static let minimumObservationCount = 3
    static let surpriseThreshold = 0.18
    static let peerGapThreshold = 0.12

    enum Subtype: String, Equatable {
        case timeOfDay
        case macroLean
        case dayType
    }

    enum Direction: Equatable {
        case better
        case tougher
    }

    struct Candidate: Equatable {
        let subtype: Subtype
        let subject: String
        let repeatKey: String
        let title: String
        let body: String?
        let evidenceLine: String
        let posteriorMean: Double
        let baselinePosterior: Double
        let surpriseScore: Double
        let observationCount: Int
        let positiveCount: Int
        let negativeCount: Int
        let direction: Direction

        var confidence: FoodOSMoment.Confidence {
            observationCount >= 6 ? .high : .medium
        }

        var qualifiesAsRevelation: Bool {
            observationCount >= FoodOSPairedBeliefs.minimumObservationCount
                && surpriseScore >= FoodOSPairedBeliefs.surpriseThreshold
                && confidence != .low
        }
    }

    static func surpriseScore(bucketPosterior: Double,
                              baselinePosterior: Double) -> Double {
        abs(bucketPosterior - baselinePosterior)
    }

    static func candidates(in logs: [FoodLog],
                           timeZone: TimeZone) -> [Candidate] {
        let baseline = FoodOSBeliefEngine.moodBelief(in: logs)
        guard baseline.hasEnoughEvidence else { return [] }
        let baselineMean = baseline.posteriorPositiveMean

        var out: [Candidate] = []
        if let time = bestTimeOfDayCandidate(in: logs,
                                             timeZone: timeZone,
                                             baseline: baselineMean) {
            out.append(time)
        }
        if let macro = bestMacroLeanCandidate(in: logs,
                                              baseline: baselineMean) {
            out.append(macro)
        }
        if let dayType = bestDayTypeCandidate(in: logs,
                                              timeZone: timeZone,
                                              baseline: baselineMean) {
            out.append(dayType)
        }

        return out
            .filter(\.qualifiesAsRevelation)
            .sorted { a, b in
                if a.surpriseScore != b.surpriseScore {
                    return a.surpriseScore > b.surpriseScore
                }
                if a.observationCount != b.observationCount {
                    return a.observationCount > b.observationCount
                }
                return a.repeatKey < b.repeatKey
            }
    }

    static func bestCandidate(in logs: [FoodLog],
                              timeZone: TimeZone,
                              excludingRepeatKey repeatKey: String? = nil) -> Candidate? {
        candidates(in: logs, timeZone: timeZone)
            .first { $0.repeatKey != repeatKey }
    }

    private struct Bucket {
        let key: String
        let subject: String
        let evidenceSubject: String
        let logs: [FoodLog]
        let compositionLine: String?
    }

    private static func bestTimeOfDayCandidate(in logs: [FoodLog],
                                               timeZone: TimeZone,
                                               baseline: Double) -> Candidate? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let buckets = [
            Bucket(key: "morning",
                   subject: "your mornings",
                   evidenceSubject: "morning meals",
                   logs: logs.filter { cal.component(.hour, from: $0.eatenAt) < 11 },
                   compositionLine: nil),
            Bucket(key: "midday",
                   subject: "your midday meals",
                   evidenceSubject: "midday meals",
                   logs: logs.filter {
                       let hour = cal.component(.hour, from: $0.eatenAt)
                       return hour >= 11 && hour < 16
                   },
                   compositionLine: nil),
            Bucket(key: "evening",
                   subject: "your evenings",
                   evidenceSubject: "evening meals",
                   logs: logs.filter { cal.component(.hour, from: $0.eatenAt) >= 16 },
                   compositionLine: nil)
        ]

        return bestMoodCandidate(
            subtype: .timeOfDay,
            buckets: buckets,
            baseline: baseline
        )
    }

    private static func bestMacroLeanCandidate(in logs: [FoodLog],
                                               baseline: Double) -> Candidate? {
        var protein: [FoodLog] = []
        var carb: [FoodLog] = []
        var balanced: [FoodLog] = []

        for log in logs {
            switch macroLean(for: log) {
            case .protein: protein.append(log)
            case .carb: carb.append(log)
            case .balanced: balanced.append(log)
            case .none: break
            }
        }

        let buckets = [
            Bucket(key: "protein",
                   subject: "your higher-protein meals",
                   evidenceSubject: "higher-protein meals",
                   logs: protein,
                   compositionLine: nil),
            Bucket(key: "carb",
                   subject: "your carb-leaning meals",
                   evidenceSubject: "carb-leaning meals",
                   logs: carb,
                   compositionLine: nil),
            Bucket(key: "balanced",
                   subject: "your balanced meals",
                   evidenceSubject: "balanced meals",
                   logs: balanced,
                   compositionLine: nil)
        ]

        return bestMoodCandidate(
            subtype: .macroLean,
            buckets: buckets,
            baseline: baseline
        )
    }

    private static func bestDayTypeCandidate(in logs: [FoodLog],
                                             timeZone: TimeZone,
                                             baseline: Double) -> Candidate? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let weekdayLogs = logs.filter { !cal.isDateInWeekend($0.eatenAt) }
        let weekendLogs = logs.filter { cal.isDateInWeekend($0.eatenAt) }
        guard weekdayLogs.count >= minimumObservationCount,
              weekendLogs.count >= minimumObservationCount else {
            return nil
        }
        guard let divergence = strongestDayTypeDivergence(
            weekday: weekdayLogs,
            weekend: weekendLogs
        ), divergence.score >= surpriseThreshold else {
            return nil
        }

        let buckets = [
            Bucket(key: "weekday",
                   subject: "your weekdays",
                   evidenceSubject: "weekday meals",
                   logs: weekdayLogs,
                   compositionLine: divergence.line),
            Bucket(key: "weekend",
                   subject: "your weekends",
                   evidenceSubject: "weekend meals",
                   logs: weekendLogs,
                   compositionLine: divergence.line)
        ]

        return bestMoodCandidate(
            subtype: .dayType,
            buckets: buckets,
            baseline: baseline
        )
    }

    private static func bestMoodCandidate(subtype: Subtype,
                                          buckets: [Bucket],
                                          baseline: Double) -> Candidate? {
        struct Scored {
            let bucket: Bucket
            let belief: FoodOSBeliefEngine.MoodBelief
            let surprise: Double
        }

        let scored = buckets.compactMap { bucket -> Scored? in
            let belief = FoodOSBeliefEngine.moodBelief(in: bucket.logs)
            guard belief.hasEnoughEvidence else { return nil }
            let surprise = surpriseScore(
                bucketPosterior: belief.posteriorPositiveMean,
                baselinePosterior: baseline
            )
            return Scored(bucket: bucket, belief: belief, surprise: surprise)
        }
        guard let best = scored.max(by: {
            if $0.surprise != $1.surprise {
                return $0.surprise < $1.surprise
            }
            return $0.belief.total < $1.belief.total
        }) else {
            return nil
        }

        let sameDirectionPeers = scored.filter {
            ($0.belief.posteriorPositiveMean >= baseline)
                == (best.belief.posteriorPositiveMean >= baseline)
                && $0.bucket.key != best.bucket.key
        }
        if let nearestPeer = sameDirectionPeers.min(by: {
            abs(best.belief.posteriorPositiveMean - $0.belief.posteriorPositiveMean)
                < abs(best.belief.posteriorPositiveMean - $1.belief.posteriorPositiveMean)
        }) {
            let gap = abs(best.belief.posteriorPositiveMean
                          - nearestPeer.belief.posteriorPositiveMean)
            guard gap >= peerGapThreshold else { return nil }
        }

        let direction: Direction = best.belief.posteriorPositiveMean >= baseline
            ? .better
            : .tougher
        let evidence = evidenceLine(
            bucket: best.bucket,
            count: best.belief.total,
            positive: best.belief.positive
        )
        let copy = copyForCandidate(
            subtype: subtype,
            bucket: best.bucket,
            direction: direction,
            surprise: best.surprise
        )

        return Candidate(
            subtype: subtype,
            subject: best.bucket.subject,
            repeatKey: "\(subtype.rawValue):\(best.bucket.key)",
            title: copy.title,
            body: copy.body,
            evidenceLine: evidence,
            posteriorMean: best.belief.posteriorPositiveMean,
            baselinePosterior: baseline,
            surpriseScore: best.surprise,
            observationCount: best.belief.total,
            positiveCount: best.belief.positive,
            negativeCount: best.belief.negative,
            direction: direction
        )
    }

    private static func evidenceLine(bucket: Bucket,
                                     count: Int,
                                     positive: Int) -> String {
        let noun = count == 1 ? "mood note" : "mood notes"
        return "Based on \(count) \(bucket.evidenceSubject) with \(noun); \(positive) were fine or loved."
    }

    private static func copyForCandidate(subtype: Subtype,
                                         bucket: Bucket,
                                         direction: Direction,
                                         surprise: Double) -> (title: String, body: String?) {
        let pointGap = Int((surprise * 100).rounded())
        switch (subtype, direction) {
        case (.timeOfDay, .better):
            return (
                "\(capitalized(bucket.subject)) have been your best-mood meals.",
                "That sits about \(pointGap) points above your usual meal mood pattern."
            )
        case (.timeOfDay, .tougher):
            return (
                "\(capitalized(bucket.subject)) have been your tougher mood window.",
                "That sits about \(pointGap) points below your usual meal mood pattern."
            )
        case (.macroLean, .better):
            return (
                "\(capitalized(bucket.subject)) have been landing better for you.",
                "That mood pattern is about \(pointGap) points above your recent baseline."
            )
        case (.macroLean, .tougher):
            return (
                "\(capitalized(bucket.subject)) have been landing tougher for you.",
                "That mood pattern is about \(pointGap) points below your recent baseline."
            )
        case (.dayType, .better):
            return (
                "\(capitalized(bucket.subject)) look different and land steadier.",
                bucket.compositionLine
            )
        case (.dayType, .tougher):
            return (
                "\(capitalized(bucket.subject)) look different and land tougher.",
                bucket.compositionLine
            )
        }
    }

    private enum MacroLean {
        case protein
        case carb
        case balanced
    }

    private static func macroLean(for log: FoodLog) -> MacroLean? {
        guard log.calories.isFinite, log.calories > 0,
              let protein = log.proteinG, protein.isFinite,
              log.carbsG.isFinite else {
            return nil
        }
        let proteinRatio = (protein * 4) / log.calories
        let carbRatio = (log.carbsG * 4) / log.calories
        if proteinRatio >= 0.25 { return .protein }
        if carbRatio >= 0.55 { return .carb }
        return .balanced
    }

    private static func strongestDayTypeDivergence(
        weekday: [FoodLog],
        weekend: [FoodLog]
    ) -> (score: Double, line: String)? {
        let weekdayCalories = mean(weekday.map(\.calories))
        let weekendCalories = mean(weekend.map(\.calories))
        let calorieScore: Double = {
            guard weekdayCalories > 0, weekendCalories > 0 else { return 0 }
            return abs(weekendCalories - weekdayCalories) / weekdayCalories
        }()

        let weekdayVariety = varietyRatio(weekday)
        let weekendVariety = varietyRatio(weekend)
        let varietyScore = abs(weekendVariety - weekdayVariety)

        if calorieScore >= varietyScore, calorieScore > 0 {
            let direction = weekendCalories > weekdayCalories ? "higher" : "lower"
            return (
                calorieScore,
                "Weekend meals have averaged \(direction) calories than weekdays."
            )
        }
        if varietyScore > 0 {
            let direction = weekendVariety > weekdayVariety ? "more" : "less"
            return (
                varietyScore,
                "Weekend meals have shown \(direction) food variety than weekdays."
            )
        }
        return nil
    }

    private static func varietyRatio(_ logs: [FoodLog]) -> Double {
        guard !logs.isEmpty else { return 0 }
        let unique = Set(logs.map { $0.foodName.lowercased() }).count
        return Double(unique) / Double(logs.count)
    }

    private static func mean(_ values: [Double]) -> Double {
        let finite = values.filter { $0.isFinite && $0 > 0 }
        guard !finite.isEmpty else { return 0 }
        return finite.reduce(0, +) / Double(finite.count)
    }

    private static func capitalized(_ subject: String) -> String {
        guard let first = subject.first else { return subject }
        return first.uppercased() + subject.dropFirst()
    }

    // MARK: - Value revelations
    //
    // Quantity-based revelations that fire on week-over-week shifts.
    // Mood-independent on purpose so flat-mood users (who can't clear
    // the paired-belief surprise gate) still see a revelation when a
    // real macro / calorie / consistency / variety change occurred.
    // Shares the same surpriseThreshold so the two surfaces agree on
    // what "meaningfully different" means.

    enum ValueSubtype: String, Equatable {
        case macroTrend
        case calorieTrend
        case consistency
        case varietyTrend
    }

    struct ValueCandidate: Equatable {
        let subtype: ValueSubtype
        let repeatKey: String
        let title: String
        let body: String?
        let evidenceLine: String
        let surpriseScore: Double
        let thisWeekCount: Int
        let lastWeekCount: Int
        /// Raw last-week value, in `unit`. Rendered as the left "before" bar.
        let beforeValue: Double
        /// Raw this-week value, in `unit`. Rendered as the right "after" bar.
        let afterValue: Double
        /// Display unit for the bar labels ("g", "kcal", "meals", "foods").
        let unit: String
        /// Signed week-over-week delta as a rounded percent.
        /// Negative = dropped, positive = climbed.
        let deltaPercent: Int

        var confidence: FoodOSMoment.Confidence {
            (thisWeekCount + lastWeekCount) >= 12 ? .high : .medium
        }

        var qualifiesAsRevelation: Bool {
            surpriseScore >= FoodOSPairedBeliefs.surpriseThreshold
        }
    }

    /// Rounded signed percent change from `before` to `after`. Returns 0
    /// when `before` is non-positive so a divide-by-zero never escapes.
    private static func signedDeltaPercent(before: Double, after: Double) -> Int {
        guard before > 0 else { return 0 }
        return Int(((after - before) / before * 100).rounded())
    }

    /// Best value-revelation candidate across the four value heads.
    /// Returns the single qualifying candidate with the highest
    /// surprise; nil when no head clears the shared gate.
    static func bestValueCandidate(thisWeek: [FoodLog],
                                   lastWeek: [FoodLog]) -> ValueCandidate? {
        var out: [ValueCandidate] = []
        if let c = macroTrendCandidate(thisWeek: thisWeek, lastWeek: lastWeek) {
            out.append(c)
        }
        if let c = calorieTrendCandidate(thisWeek: thisWeek, lastWeek: lastWeek) {
            out.append(c)
        }
        if let c = consistencyCandidate(thisWeek: thisWeek, lastWeek: lastWeek) {
            out.append(c)
        }
        if let c = varietyTrendCandidate(thisWeek: thisWeek, lastWeek: lastWeek) {
            out.append(c)
        }
        return out
            .filter(\.qualifiesAsRevelation)
            .max { a, b in
                if a.surpriseScore != b.surpriseScore {
                    return a.surpriseScore < b.surpriseScore
                }
                return a.repeatKey > b.repeatKey
            }
    }

    private struct MacroAxis {
        let key: String          // protein|carbs|fat
        let label: String        // "protein"
        let thisAvg: Double
        let lastAvg: Double
        let thisCount: Int
        let lastCount: Int
    }

    private static func macroTrendCandidate(thisWeek: [FoodLog],
                                            lastWeek: [FoodLog]) -> ValueCandidate? {
        let axes: [MacroAxis] = [
            macroAxis(key: "protein", label: "protein",
                      thisWeek: thisWeek, lastWeek: lastWeek) { $0.proteinG },
            macroAxis(key: "carbs", label: "carbs",
                      thisWeek: thisWeek, lastWeek: lastWeek) { $0.carbsG },
            macroAxis(key: "fat", label: "fat",
                      thisWeek: thisWeek, lastWeek: lastWeek) { $0.fatG }
        ].compactMap { $0 }

        let scored = axes.compactMap { axis -> (MacroAxis, Double)? in
            guard axis.thisCount >= 3, axis.lastCount >= 3,
                  axis.lastAvg > 0 else { return nil }
            let surprise = min(abs(axis.thisAvg - axis.lastAvg) / axis.lastAvg,
                               1.0)
            return (axis, surprise)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let (axis, surprise) = best

        let direction = axis.thisAvg < axis.lastAvg ? "dropped" : "climbed"
        let from = Int(axis.lastAvg.rounded())
        let to   = Int(axis.thisAvg.rounded())
        let title = "Your \(axis.label) \(direction) from about \(from)g to \(to)g per meal this week."
        let body  = "A real shift, worth noticing if it wasn't on purpose."
        let evidence = "Based on \(axis.thisCount) meals this week and \(axis.lastCount) last week."

        return ValueCandidate(
            subtype:        .macroTrend,
            repeatKey:      "macroTrend:\(axis.key)",
            title:          title,
            body:           body,
            evidenceLine:   evidence,
            surpriseScore:  surprise,
            thisWeekCount:  axis.thisCount,
            lastWeekCount:  axis.lastCount,
            beforeValue:    axis.lastAvg.rounded(),
            afterValue:     axis.thisAvg.rounded(),
            unit:           "g",
            deltaPercent:   signedDeltaPercent(before: axis.lastAvg,
                                               after:  axis.thisAvg)
        )
    }

    private static func macroAxis(key: String,
                                  label: String,
                                  thisWeek: [FoodLog],
                                  lastWeek: [FoodLog],
                                  extract: (FoodLog) -> Double?) -> MacroAxis? {
        let thisValues = thisWeek.compactMap(extract).filter { $0.isFinite && $0 >= 0 }
        let lastValues = lastWeek.compactMap(extract).filter { $0.isFinite && $0 >= 0 }
        guard !thisValues.isEmpty, !lastValues.isEmpty else { return nil }
        return MacroAxis(
            key:        key,
            label:      label,
            thisAvg:    thisValues.reduce(0, +) / Double(thisValues.count),
            lastAvg:    lastValues.reduce(0, +) / Double(lastValues.count),
            thisCount:  thisValues.count,
            lastCount:  lastValues.count
        )
    }

    private static func calorieTrendCandidate(thisWeek: [FoodLog],
                                              lastWeek: [FoodLog]) -> ValueCandidate? {
        let thisValues = thisWeek.map(\.calories).filter { $0.isFinite && $0 > 0 }
        let lastValues = lastWeek.map(\.calories).filter { $0.isFinite && $0 > 0 }
        guard thisValues.count >= 3, lastValues.count >= 3 else { return nil }
        let thisAvg = thisValues.reduce(0, +) / Double(thisValues.count)
        let lastAvg = lastValues.reduce(0, +) / Double(lastValues.count)
        guard lastAvg > 0 else { return nil }
        let surprise = min(abs(thisAvg - lastAvg) / lastAvg, 1.0)
        let delta = Int(abs(thisAvg - lastAvg).rounded())
        let direction = thisAvg < lastAvg ? "lighter" : "heavier"
        let title = "Your meals ran about \(delta) calories \(direction) this week."
        let evidence = "Based on \(thisValues.count) meals this week and \(lastValues.count) last week."
        return ValueCandidate(
            subtype:        .calorieTrend,
            repeatKey:      "calorieTrend",
            title:          title,
            body:           nil,
            evidenceLine:   evidence,
            surpriseScore:  surprise,
            thisWeekCount:  thisValues.count,
            lastWeekCount:  lastValues.count,
            beforeValue:    lastAvg.rounded(),
            afterValue:     thisAvg.rounded(),
            unit:           "kcal",
            deltaPercent:   signedDeltaPercent(before: lastAvg, after: thisAvg)
        )
    }

    private static func consistencyCandidate(thisWeek: [FoodLog],
                                             lastWeek: [FoodLog]) -> ValueCandidate? {
        let cur  = thisWeek.count
        let prev = lastWeek.count
        // Floor: ignore noise when both weeks are very small.
        guard cur + prev >= 4 else { return nil }
        let surprise = min(Double(abs(cur - prev)) / Double(max(prev, 1)), 1.0)
        let mealNoun = max(cur, prev) == 1 ? "meal" : "meals"
        let title: String
        if cur > prev {
            title = "You logged far more this week than last, \(cur) \(mealNoun) vs \(prev)."
        } else if cur < prev {
            title = "You logged less this week than last, \(cur) \(mealNoun) vs \(prev)."
        } else {
            return nil
        }
        let evidence = "Based on \(cur) meals this week and \(prev) last week."
        return ValueCandidate(
            subtype:        .consistency,
            repeatKey:      "consistency",
            title:          title,
            body:           nil,
            evidenceLine:   evidence,
            surpriseScore:  surprise,
            thisWeekCount:  cur,
            lastWeekCount:  prev,
            beforeValue:    Double(prev),
            afterValue:     Double(cur),
            unit:           "meals",
            deltaPercent:   signedDeltaPercent(before: Double(prev),
                                               after:  Double(cur))
        )
    }

    private static func varietyTrendCandidate(thisWeek: [FoodLog],
                                              lastWeek: [FoodLog]) -> ValueCandidate? {
        guard thisWeek.count >= 3, lastWeek.count >= 3 else { return nil }
        let thisDistinct = Set(thisWeek.map { $0.foodName.lowercased() }).count
        let lastDistinct = Set(lastWeek.map { $0.foodName.lowercased() }).count
        guard lastDistinct > 0 else { return nil }
        let surprise = min(Double(abs(thisDistinct - lastDistinct))
                           / Double(max(lastDistinct, 1)), 1.0)
        let foodNoun = thisDistinct == 1 ? "food" : "foods"
        let title: String
        if thisDistinct > lastDistinct {
            title = "Your meals got more varied, \(thisDistinct) different \(foodNoun) this week."
        } else if thisDistinct < lastDistinct {
            title = "Your meals got more focused, \(thisDistinct) different \(foodNoun) this week."
        } else {
            return nil
        }
        let evidence = "Based on \(thisWeek.count) meals this week and \(lastWeek.count) last week."
        return ValueCandidate(
            subtype:        .varietyTrend,
            repeatKey:      "varietyTrend",
            title:          title,
            body:           nil,
            evidenceLine:   evidence,
            surpriseScore:  surprise,
            thisWeekCount:  thisWeek.count,
            lastWeekCount:  lastWeek.count,
            beforeValue:    Double(lastDistinct),
            afterValue:     Double(thisDistinct),
            unit:           "foods",
            deltaPercent:   signedDeltaPercent(before: Double(lastDistinct),
                                               after:  Double(thisDistinct))
        )
    }
}
