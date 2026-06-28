import Foundation

/// Local, ephemeral "streak repair" offer. When a meaningful streak resets
/// (a gap beyond what freezes cover), we remember the lost value for a short
/// window so the user can undo the break with one tap — the gentle,
/// non-punitive alternative to a hard reset-to-zero, and the research-backed
/// way to stop a broken long streak from causing churn.
///
/// UserDefaults only: no schema change, no egress, and the offer never
/// survives past its deadline (re-evaluated on read). Pairs with the freeze
/// mechanic in `StreakService` — freezes absorb 1–2 day lapses automatically;
/// repair recovers the rarer bigger break.
@MainActor
final class StreakRepairStore: ObservableObject {
    static let shared = StreakRepairStore()

    /// Only offer repair for streaks worth saving. Freezes already cover 1–2
    /// day gaps, and a 1–2 day "streak" isn't worth a prompt.
    static let minRepairableStreak = 3

    /// How many days the offer stays live after a break (through the end of
    /// tomorrow, local), so a user who comes back the next day can still undo.
    static let windowDays = 2

    private let defaults: UserDefaults
    private let brokenKey   = "streak.repair.broken.v1"
    private let deadlineKey = "streak.repair.deadline.v1"

    /// The repairable streak length while an offer is live, else nil. Published
    /// so the Today banner appears and clears reactively.
    @Published private(set) var offer: Int?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.offer = Self.liveOffer(defaults: defaults,
                                    brokenKey: brokenKey, deadlineKey: deadlineKey)
    }

    /// Arm a repair offer for a just-broken streak. No-op below the threshold.
    func arm(brokenStreak: Int, now: Date = Date(), timeZone: TimeZone = .current) {
        guard brokenStreak >= Self.minRepairableStreak else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let deadline = cal.date(byAdding: .day, value: Self.windowDays,
                                to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(Double(Self.windowDays) * 86_400)
        defaults.set(brokenStreak, forKey: brokenKey)
        defaults.set(deadline, forKey: deadlineKey)
        offer = brokenStreak
    }

    /// Clear the offer (repaired, declined, or expired).
    func consume() {
        defaults.removeObject(forKey: brokenKey)
        defaults.removeObject(forKey: deadlineKey)
        offer = nil
    }

    /// Re-evaluate against the deadline — call on Today appear / app foreground
    /// so a stale offer drops itself.
    func refresh(now: Date = Date()) {
        offer = Self.liveOffer(defaults: defaults,
                               brokenKey: brokenKey, deadlineKey: deadlineKey, now: now)
    }

    private static func liveOffer(defaults: UserDefaults,
                                  brokenKey: String, deadlineKey: String,
                                  now: Date = Date()) -> Int? {
        let value = defaults.integer(forKey: brokenKey)
        guard value >= minRepairableStreak,
              let deadline = defaults.object(forKey: deadlineKey) as? Date,
              now < deadline else { return nil }
        return value
    }
}
