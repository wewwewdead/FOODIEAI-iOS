import Foundation

/// Phase 21 — daily-streak mechanics with a Gentler-Streak-style grace
/// day. Called after every successful meal save (manual + analyzed).
///
/// The streak math is intentionally on the client: PG triggers would
/// have to reconstruct the user's local-calendar day from the eaten_at
/// timestamp, which we already do for the Tracker's local-day bucketing
/// in Phase 0. Keeping it client-side means one source of truth.
///
/// Grace-day rule:
///   - Starts at 1; capped at 2 by the DB check constraint.
///   - Consumed when a 1-day gap is forgiven, preserving the streak.
///   - Refilled by +1 every full week (current_streak % 7 == 0) where
///     the current grace is below the soft cap of 1.
///   - A genuine reset (gap ≥ 3 local days, or gap == 2 with no grace
///     available) zeros the streak back to 1 and refills grace to 1.
///
/// `recordLog` is best-effort: callers should `try?` the call and
/// continue if it throws. The meal is already saved; a streak update
/// failure must not back out the user's row.
@MainActor
final class StreakService {
    static let shared = StreakService()

    private let profileService: ProfileService

    init(profileService: ProfileService = ProfileService()) {
        self.profileService = profileService
    }

    /// Record a successful save against the streak state. Returns a
    /// summary the UI can use to drive a small celebration the next
    /// time the user visits Today. Throws only on network / DB errors;
    /// the "no change" path returns `.alreadyToday` rather than
    /// throwing.
    @discardableResult
    func recordLog(at eatenAt: Date = Date(),
                   timeZone: TimeZone = .current) async throws -> StreakUpdate {
        let profile = try await profileService.currentProfile()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let todayLocal = cal.startOfDay(for: eatenAt)
        let previousLocal = profile.lastLoggedLocalDate

        var newStreak = profile.currentStreakDays
        var newGrace  = profile.graceDaysRemaining
        let outcome: StreakOutcome

        if previousLocal == nil {
            // First log ever — start the streak at 1, keep grace at the
            // schema default. Going through the same DB path as every
            // other case keeps the math in one place.
            newStreak = 1
            newGrace  = max(newGrace, 1)
            outcome = .started
        } else {
            // Normalize the stored date to the user's current local day
            // before subtracting — the column is `date` so its absolute
            // Date midnight may sit in a different zone than today's.
            let previousStart = cal.startOfDay(for: previousLocal!)
            let daysBetween = cal.dateComponents(
                [.day], from: previousStart, to: todayLocal
            ).day ?? 0

            switch daysBetween {
            case ..<0:
                // Backdated eatenAt — unusual, but treat as "already
                // counted." Don't roll backward.
                outcome = .alreadyToday

            case 0:
                outcome = .alreadyToday

            case 1:
                newStreak += 1
                outcome = .extended
                // Every full week without missing a day tops grace back
                // up by 1, capped at 1. Without this, a long streak
                // burns its single grace once and then runs raw.
                if newStreak % 7 == 0 && newGrace < 1 {
                    newGrace = 1
                }

            case 2 where newGrace > 0:
                newStreak += 1
                newGrace  -= 1
                outcome = .savedByGrace

            default:
                // Gap of 2 with no grace, or any gap >= 3 → reset.
                newStreak = 1
                newGrace  = 1
                outcome = .reset
            }
        }

        let newLongest = max(profile.longestStreakDays, newStreak)

        // No-op path: nothing to write if it's a same-day re-log.
        // Returning early avoids a redundant UPDATE round-trip for the
        // common case of multiple meals on the same day.
        if outcome == .alreadyToday,
           profile.currentStreakDays == newStreak,
           profile.longestStreakDays == newLongest,
           profile.graceDaysRemaining == newGrace,
           previousLocal != nil {
            return StreakUpdate(
                newStreak: newStreak,
                outcome: outcome,
                graceRemaining: newGrace
            )
        }

        _ = try await profileService.updateStreak(
            currentStreakDays:   newStreak,
            longestStreakDays:   newLongest,
            lastLoggedLocalDate: todayLocal,
            graceDaysRemaining:  newGrace
        )

        #if DEBUG
        NSLog("[Streak] outcome=%@ streak=%d grace=%d longest=%d",
              String(describing: outcome), newStreak, newGrace, newLongest)
        #endif

        return StreakUpdate(
            newStreak: newStreak,
            outcome: outcome,
            graceRemaining: newGrace
        )
    }
}

/// Outcome the UI uses to decide whether to celebrate. `.alreadyToday`
/// and `.started` are quiet (no toast); `.extended` and `.savedByGrace`
/// pulse the streak chip; `.reset` shows the chip without celebration.
enum StreakOutcome: Equatable {
    case started
    case alreadyToday
    case extended
    case savedByGrace
    case reset
}

struct StreakUpdate: Equatable {
    let newStreak: Int
    let outcome: StreakOutcome
    let graceRemaining: Int
}
