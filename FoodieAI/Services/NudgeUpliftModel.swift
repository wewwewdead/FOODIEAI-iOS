import Foundation

// NOVEL_DIRECTIONS Idea 3 — "Causal Nudges" (JITAI / uplift).
//
// Notifications today are a static schedule: send the same reminder at the
// same time regardless of whether it actually changes behaviour. This turns
// them into a learned policy that measures — per context — whether a nudge
// *causes* the user to log (uplift), not merely correlates with it, and then
// only sends the nudges that help.
//
// The trick is the same one FoodOS already uses for willTry→mood: to learn a
// causal effect you need a counterfactual, so the policy MICRO-RANDOMIZES —
// occasionally it withholds a nudge it could have sent, to observe the
// "control" log-rate in that context. Uplift = treated log-rate − control
// log-rate.
//
// Pure + testable: `NudgeUpliftModel` is a pure function of accumulated stats
// and injected random draws (so tests are deterministic). `NudgeUpliftStore`
// is the actor-isolated, zero-egress persistence around it. Nothing here sends
// a notification — the scheduler consults `decide(...)` and later reports the
// outcome via `record(...)`.

/// The nudges the policy can gate. Mirrors the scheduler's notification kinds.
enum NudgeKind: String, Codable, CaseIterable, Hashable {
    case mealReminder
    case calorieBalance
    case streakSaver
    case comeback
}

/// A small, bucketed description of "when" a nudge would fire — coarse enough
/// that stats accumulate quickly, fine enough to separate meaningfully
/// different moments. Keep it low-cardinality on purpose.
struct NudgeContext: Codable, Hashable {
    /// 0=night(0–5) 1=morning(6–11) 2=afternoon(12–17) 3=evening(18–23).
    let dayPart: Int
    let isWeekend: Bool
    /// True when a live streak is at stake (raises the stakes of a miss).
    let streakAtRisk: Bool

    static func dayPart(forHour hour: Int) -> Int {
        switch hour {
        case 0...5:   return 0
        case 6...11:  return 1
        case 12...17: return 2
        default:      return 3
        }
    }
}

/// Per (kind, context) accumulator. "Treated" = a nudge was sent; "control" =
/// the policy withheld one it could have sent. `logged` = the user logged a
/// meal within the outcome window afterwards.
struct NudgeStats: Codable, Equatable {
    var treatedSent: Int = 0
    var treatedLogged: Int = 0
    var controlSeen: Int = 0
    var controlLogged: Int = 0
}

enum NudgeReason: String, Equatable { case exploit, explore, control, cold }

enum NudgeDecision: Equatable {
    case send(NudgeReason)
    case withhold(NudgeReason)

    var shouldSend: Bool { if case .send = self { return true } else { return false } }
}

enum NudgeUpliftModel {

    /// Below this many observations in EITHER arm we don't trust the estimate
    /// yet and keep exploring (randomizing) to fill both arms.
    static let minObservations = 5

    /// Laplace-smoothed causal uplift: P(log | nudged) − P(log | not nudged).
    /// Positive ⇒ the nudge helps in this context; ≤ 0 ⇒ it doesn't (or annoys).
    static func uplift(_ s: NudgeStats) -> Double {
        let treated = Double(s.treatedLogged + 1) / Double(s.treatedSent + 2)
        let control = Double(s.controlLogged + 1) / Double(s.controlSeen + 2)
        return treated - control
    }

    /// The micro-randomized policy. `roll` and `coin` are independent draws in
    /// [0, 1) (real code passes `Double.random(in:)`, tests pass fixed values).
    ///
    /// - Cold / thin data → EXPLORE: flip `coin` to send-or-withhold so both
    ///   arms fill and a causal estimate becomes possible.
    /// - Enough data → mostly EXPLOIT (send iff uplift > 0), but with
    ///   `explorationRate` probability keep randomizing so the estimate stays
    ///   fresh as habits drift.
    static func decide(stats: NudgeStats,
                       explorationRate: Double = 0.2,
                       controlRate: Double = 0.5,
                       roll: Double,
                       coin: Double) -> NudgeDecision {
        let haveData = stats.treatedSent >= minObservations
            && stats.controlSeen >= minObservations
        let explore = !haveData || roll < explorationRate
        if explore {
            // Withhold (gather a control sample) with probability `controlRate`,
            // else send. A gentle rate keeps a user-facing reminder from being
            // dropped too often while the causal estimate fills in.
            return coin < (1 - controlRate)
                ? .send(haveData ? .explore : .cold)
                : .withhold(.control)
        }
        return uplift(stats) > 0 ? .send(.exploit) : .withhold(.exploit)
    }
}

// MARK: - Outcome attribution (pending nudges → recorded uplift)

/// A nudge whose outcome window hasn't been scored yet. `sent` distinguishes a
/// delivered nudge (treated) from a withheld one (control); `firedAt` is when
/// it fired or would have; `windowHours` is how long after that a log counts.
struct NudgePending: Codable, Equatable {
    let kind: NudgeKind
    let context: NudgeContext
    let sent: Bool
    let firedAt: Date
    let windowHours: Double
}

/// A scored outcome ready to fold into `NudgeUpliftStore`.
struct NudgeResolved: Equatable {
    let kind: NudgeKind
    let context: NudgeContext
    let sent: Bool
    let logged: Bool
}

/// Pure scorer: given the pending nudges, the user's meal timestamps, and now,
/// resolve every pending whose window has closed. A pending resolves `logged =
/// true` as soon as a meal falls in its window (even before the window ends);
/// otherwise it resolves `false` only once the window has fully closed. Anything
/// still open is returned in `remaining`.
///
/// This needs no historical fetch: every meal save triggers a recompute while
/// the app is open, so a genuine in-window log is always seen live and scored
/// `true` at that moment. A pending that survives to a later day therefore had
/// no in-window log and is correctly scored `false` on the next open.
enum NudgeOutcomeEvaluator {
    static func resolve(pending: [NudgePending], logDates: [Date], now: Date)
        -> (resolved: [NudgeResolved], remaining: [NudgePending]) {
        var resolved: [NudgeResolved] = []
        var remaining: [NudgePending] = []
        for p in pending {
            let windowEnd = p.firedAt.addingTimeInterval(p.windowHours * 3600)
            let loggedInWindow = logDates.contains { $0 > p.firedAt && $0 <= windowEnd }
            if loggedInWindow {
                resolved.append(NudgeResolved(kind: p.kind, context: p.context, sent: p.sent, logged: true))
            } else if now >= windowEnd {
                resolved.append(NudgeResolved(kind: p.kind, context: p.context, sent: p.sent, logged: false))
            } else {
                remaining.append(p)   // window still open, no log yet
            }
        }
        return (resolved, remaining)
    }
}

/// Actor-isolated, zero-egress tracker of pending nudge outcomes plus the
/// day-stable send/withhold decision (so repeated recomputes on the same day
/// don't re-randomize the reminder). Persists to Application Support.
actor NudgeOutcomeTracker {
    static let shared = NudgeOutcomeTracker()

    private var pending: [NudgePending]
    /// Today's committed decision per kind, keyed "kind|yyyy-mm-dd". Prevents a
    /// second recompute from flipping a coin again and toggling the reminder.
    private var dayDecisions: [String: Bool]
    private let storeURL: URL?

    init(storeURL: URL? = NudgeOutcomeTracker.defaultStoreURL()) {
        self.storeURL = storeURL
        let loaded = NudgeOutcomeTracker.load(from: storeURL)
        self.pending = loaded.pending
        self.dayDecisions = loaded.decisions
    }

    /// Test seam.
    init(pending: [NudgePending], dayDecisions: [String: Bool] = [:]) {
        self.storeURL = nil
        self.pending = pending
        self.dayDecisions = dayDecisions
    }

    /// The decision already committed for this kind today, or nil if none yet.
    func todaysDecision(kind: NudgeKind, dayKey: String) -> Bool? {
        dayDecisions[decisionKey(kind, dayKey)]
    }

    /// Commit today's decision and enqueue its outcome for later scoring.
    func commit(kind: NudgeKind, context: NudgeContext, dayKey: String,
                sent: Bool, firedAt: Date, windowHours: Double) {
        dayDecisions[decisionKey(kind, dayKey)] = sent
        pending.append(NudgePending(kind: kind, context: context, sent: sent,
                                    firedAt: firedAt, windowHours: windowHours))
        prune(now: firedAt)
        persist()
    }

    /// Score any pending whose window has closed against the given meal
    /// timestamps; returns the resolved outcomes for the caller to record.
    func resolve(logDates: [Date], now: Date) -> [NudgeResolved] {
        let (resolved, remaining) = NudgeOutcomeEvaluator.resolve(
            pending: pending, logDates: logDates, now: now)
        pending = remaining
        if !resolved.isEmpty { persist() }
        return resolved
    }

    private func decisionKey(_ kind: NudgeKind, _ dayKey: String) -> String {
        "\(kind.rawValue)|\(dayKey)"
    }

    /// Bound both stores so they can't grow without limit if the app is opened
    /// rarely (stale pendings older than a week are dropped, unscored).
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        pending = pending.filter { $0.firedAt >= cutoff }
        if dayDecisions.count > 60 {
            dayDecisions = Dictionary(dayDecisions.suffix(30), uniquingKeysWith: { a, _ in a })
        }
    }

    private struct Persisted: Codable {
        var pending: [NudgePending]
        var decisions: [String: Bool]
    }

    private func persist() {
        guard let storeURL,
              let data = try? JSONEncoder().encode(Persisted(pending: pending, decisions: dayDecisions))
        else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func defaultStoreURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("nudge_pending.v1.json")
    }

    private static func load(from url: URL?) -> (pending: [NudgePending], decisions: [String: Bool]) {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return ([], [:]) }
        return (decoded.pending, decoded.decisions)
    }
}

/// Actor-isolated, zero-egress persistence of nudge outcomes. The scheduler
/// asks `decision(...)` before sending, then reports back with `record(...)`
/// once the outcome window closes.
actor NudgeUpliftStore {
    static let shared = NudgeUpliftStore()

    private var stats: [String: NudgeStats]
    private let storeURL: URL?

    init(storeURL: URL? = NudgeUpliftStore.defaultStoreURL()) {
        self.storeURL = storeURL
        self.stats = NudgeUpliftStore.load(from: storeURL)
    }

    /// Test seam.
    init(stats: [String: NudgeStats]) {
        self.storeURL = nil
        self.stats = stats
    }

    private func key(_ kind: NudgeKind, _ ctx: NudgeContext) -> String {
        "\(kind.rawValue)|\(ctx.dayPart)|\(ctx.isWeekend ? 1 : 0)|\(ctx.streakAtRisk ? 1 : 0)"
    }

    func stats(for kind: NudgeKind, context: NudgeContext) -> NudgeStats {
        stats[key(kind, context)] ?? NudgeStats()
    }

    func decision(for kind: NudgeKind, context: NudgeContext,
                  explorationRate: Double = 0.2,
                  controlRate: Double = 0.5,
                  roll: Double, coin: Double) -> NudgeDecision {
        NudgeUpliftModel.decide(stats: stats(for: kind, context: context),
                                explorationRate: explorationRate,
                                controlRate: controlRate, roll: roll, coin: coin)
    }

    /// Report an outcome. `sent` = was the nudge delivered (treated) or withheld
    /// (control); `logged` = did the user log within the outcome window.
    func record(kind: NudgeKind, context: NudgeContext, sent: Bool, logged: Bool) {
        let k = key(kind, context)
        var s = stats[k] ?? NudgeStats()
        if sent {
            s.treatedSent += 1
            if logged { s.treatedLogged += 1 }
        } else {
            s.controlSeen += 1
            if logged { s.controlLogged += 1 }
        }
        stats[k] = s
        persist()
    }

    private func persist() {
        guard let storeURL, let data = try? JSONEncoder().encode(stats) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func defaultStoreURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("nudge_uplift.v1.json")
    }

    private static func load(from url: URL?) -> [String: NudgeStats] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: NudgeStats].self, from: data)
        else { return [:] }
        return decoded
    }
}
