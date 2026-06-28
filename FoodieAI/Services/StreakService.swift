import Foundation

/// Phase 21 — daily-streak mechanics with a Gentler-Streak-style grace
/// day. Called after every successful meal save (manual + analyzed).
///
/// The streak math is intentionally on the client: PG triggers would
/// have to reconstruct the user's local-calendar day from the eaten_at
/// timestamp, which we already do for the Tracker's local-day bucketing
/// in Phase 0. Keeping it client-side means one source of truth.
///
/// Grace-day ("streak freeze") rule:
///   - Starts at 1; banked up to a soft cap of 2 (the DB check-constraint
///     ceiling), +1 every full week without a miss (current_streak % 7 == 0).
///   - A 1-day gap costs 1 freeze; a 2-day gap costs 2 (only if banked) — so
///     a saved-up user can absorb a short lapse (e.g. a weekend off) without
///     losing a long run. Research: streak-freeze mechanics materially cut
///     churn vs. a punitive reset-to-zero.
///   - A genuine reset (a gap beyond what's banked) zeros the streak back to
///     1 and refills grace to 1.
///
/// `recordLog` is best-effort: callers should `try?` the call and
/// continue if it throws. The meal is already saved; a streak update
/// failure must not back out the user's row.
@MainActor
final class StreakService: ObservableObject {
    static let shared = StreakService()

    private let profileService: ProfileService

    /// Set when a save consumed a freeze to keep a live streak alive, so the
    /// UI can surface a one-time, non-shaming "a freeze saved your streak"
    /// moment. Cleared by the consumer (Today banner). In-memory only — a
    /// freeze notice is ephemeral and shouldn't survive a relaunch.
    @Published var pendingFreezeNotice: FreezeNotice?

    init(profileService: ProfileService = ProfileService.shared) {
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

        // Local-day gap from the last logged day to today. Normalize the
        // stored date to the user's current local day before subtracting —
        // the column is `date` so its absolute midnight may sit in a
        // different zone than today's. `nil` previous = first log ever.
        let daysBetween: Int = {
            guard let prev = previousLocal else { return 0 }
            let previousStart = cal.startOfDay(for: prev)
            return cal.dateComponents([.day], from: previousStart, to: todayLocal).day ?? 0
        }()

        let transition = StreakMath.transition(
            previousLogged: previousLocal != nil,
            daysBetween: daysBetween,
            currentStreak: profile.currentStreakDays,
            grace: profile.graceDaysRemaining
        )
        let newStreak = transition.streak
        let newGrace  = transition.grace
        let outcome   = transition.outcome

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

        // A freeze just saved a live streak — surface it once so the user
        // knows the buffer did its job (otherwise freezes work silently).
        if outcome == .savedByGrace {
            pendingFreezeNotice = FreezeNotice(streakDays: newStreak)
        }
        // A meaningful streak just reset (gap beyond freeze coverage) — offer a
        // one-tap repair for a short window so the break isn't punitive.
        // `profile.currentStreakDays` is the pre-reset value we'd restore to.
        if outcome == .reset {
            StreakRepairStore.shared.arm(brokenStreak: profile.currentStreakDays,
                                         timeZone: timeZone)
        }

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

    /// Restore a just-broken streak the user opted to repair. Returns the
    /// restored length, or nil when there's no live offer. The reset write
    /// already advanced `lastLoggedLocalDate` to today, so we keep it and the
    /// streak simply continues from the restored value on the next log.
    /// Best-effort like `recordLog`; throws only on network/DB errors.
    @discardableResult
    func repair(profileStore: ProfileStore) async throws -> Int? {
        guard let restored = StreakRepairStore.shared.offer else { return nil }
        let profile = try await profileService.currentProfile()
        let newLongest = max(profile.longestStreakDays, restored)
        let updated = try await profileService.updateStreak(
            currentStreakDays:   restored,
            longestStreakDays:   newLongest,
            lastLoggedLocalDate: profile.lastLoggedLocalDate ?? Date(),
            graceDaysRemaining:  profile.graceDaysRemaining
        )
        profileStore.apply(updated)
        StreakRepairStore.shared.consume()
        AnalyticsService.shared.track(AnalyticsService.Event.streakRepaired,
                                      ["restored": String(restored)])
        #if DEBUG
        NSLog("[Streak] repaired → restored=%d", restored)
        #endif
        return restored
    }
}

/// Pure streak-transition math, extracted from `StreakService.recordLog`
/// so the freeze/forgiveness rules are unit-testable without a network
/// round-trip. No dates here — the caller reduces the calendar gap to a
/// `daysBetween` integer first.
enum StreakMath {
    /// Banked "freeze" ceiling. The DB check constraint allows 2; we bank up
    /// to that so a saved-up user can absorb a 1- or 2-day lapse.
    static let graceSoftCap = 2

    struct Transition: Equatable {
        let streak: Int
        let grace: Int
        let outcome: StreakOutcome
    }

    /// Reduce (previous state, gap) → (new streak, new grace, outcome).
    /// `daysBetween` is the local-day gap from the last logged day to today;
    /// `previousLogged == false` means this is the user's first log ever.
    static func transition(previousLogged: Bool,
                           daysBetween: Int,
                           currentStreak: Int,
                           grace: Int) -> Transition {
        guard previousLogged else {
            return Transition(streak: 1, grace: max(grace, 1), outcome: .started)
        }
        switch daysBetween {
        case ..<0, 0:
            // Backdated or same-day re-log — already counted, don't move.
            return Transition(streak: currentStreak, grace: grace, outcome: .alreadyToday)

        case 1:
            let s = currentStreak + 1
            // Bank a freeze each full clean week, up to the soft cap.
            let g = (s % 7 == 0 && grace < graceSoftCap) ? grace + 1 : grace
            return Transition(streak: s, grace: g, outcome: .extended)

        case 2 where grace >= 1:
            // One missed day, covered by a single banked freeze.
            return Transition(streak: currentStreak + 1, grace: grace - 1, outcome: .savedByGrace)

        case 3 where grace >= graceSoftCap:
            // Two missed days, covered by two banked freezes — a long run
            // survives a short break when the user has saved up.
            return Transition(streak: currentStreak + 1, grace: grace - graceSoftCap, outcome: .savedByGrace)

        default:
            // Gap beyond what's banked → genuine reset (today is day 1).
            return Transition(streak: 1, grace: 1, outcome: .reset)
        }
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

/// A one-time, ephemeral notice that a banked freeze kept a streak alive.
/// `id` lets SwiftUI treat each occurrence as distinct so the banner
/// re-animates even if two freezes fire in one session.
struct FreezeNotice: Equatable, Identifiable {
    let id = UUID()
    let streakDays: Int
}
