import SwiftUI
import UIKit

// Extracted from CaptureView.swift (2026-07) to shrink the file.
// The breathing camera halo, the Today goal + daily check-in cards, and the change/remove-photo buttons. Types are module-scoped so CaptureView still references them.

// MARK: - Breathing camera halo

/// Phase 14 delight: the empty-state camera icon with a gentle breathing
/// scale loop on the brand-soft halo and a subtle counter-bob on the
/// camera glyph itself. The motion is slow (2.4s period) and small in
/// amplitude (±4%) so it feels alive without being distracting.
///
/// Animation kicks off on first appear via `.appBreathing` (an autoreversing
/// `.easeInOut` repeating forever, defined in `AppAnimation.swift`).
struct BreathingCameraHalo: View {
    @State private var breathing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.brandSoft,
                             Color(red: 232/255, green: 239/255, blue: 194/255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 88, height: 88)
                .scaleEffect(breathing ? 1.04 : 1.0)

            Image(systemName: "camera.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Color.brand)
                // Counter-direction bob so the camera glyph "floats"
                // rather than scaling with the halo.
                .scaleEffect(breathing ? 0.98 : 1.0)
        }
        .onAppear {
            // Reduce Motion: don't start the breathing loop. Halo stays
            // at rest; the camera icon still reads as the affordance.
            guard !reduceMotion else { return }
            withAnimation(.appBreathing) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Daily Check-in card

/// Retention-polish replacement for the prior `TodayPulseCard`. Combines:
///
///   1. **Primary check-in copy** — deterministic, count-aware, never
///      shaming. Mirrors the design contract:
///          0 meals → "Start today with one photo."
///          1 meal  → "Nice start — 1 meal logged today."
///          2 meals → "You're building today's picture."
///         3+ meals → "Today is well tracked."
///      The 0-meal branch is personalized when the local rhythm store
///      knows the user logged recently:
///          yesterdayLogged → "Back from yesterday — start today with one photo."
///          last log ≤ 30d  → "Your last log was {Friday|date}. Ready for today's first meal?"
///
///   2. **Secondary sub-line (optional)** — combined with the count when
///      a valid daily calorie goal exists. Examples:
///          "2 meals logged · about 420 calories left"
///          "3 meals logged · goal reached"
///      Or, on the empty path, a rhythm cue:
///          "First check-in logged." / "You're on a 4-day logging rhythm."
///
///   3. **End-of-day return hook** — inline footer, only visible after
///      20:00 local *and* at least one meal logged today. Quiet, no
///      modal, no notification, no infinite animation:
///          "Your day is almost complete. Come back tomorrow for a fresh pulse."
///
/// All inputs are pure data caches owned by the parent — there is no
/// polling, no timer, no retained `Task`. Repeated renders produce
/// identical copy for the same inputs (deterministic).
/// The always-on "Today" scoreboard on Home — a glanceable mini calorie
/// ring + the running headline ("1,240 left today" / "180 over today")
/// against the daily goal. The first beat of the goal loop made persistent:
/// you see where you stand without having to scan. Taps through to Tracker.
struct TodayGoalCard: View {
    let status: DailyCalorieGoalStatus
    /// Goal direction + body weight power the "earn it back" line — same
    /// rule as the result screen: only for lose/maintain, never gain, and
    /// the minutes are personalized to the user's weight.
    var goalDirection: CalorieGoalCalculator.GoalDirection? = nil
    var bodyWeightKg: Double? = nil
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOver: Bool {
        status.exceededBy > 0 || status.warningState == .reached
    }
    /// Show the walk/jog burn-off only when genuinely over budget and the
    /// goal isn't to gain (where a surplus is the point).
    private var showBurnOff: Bool {
        status.exceededBy > 0 && goalDirection != .gain
    }
    private var clamped: Double { min(max(status.progress, 0), 1) }
    private var ringColor: Color { isOver ? Color.error : Color.brand }

    /// Headline figure, rounded to the nearest 10 for a calm read and
    /// grouped (1,240) by locale.
    private var headline: String {
        let value = isOver ? status.exceededBy : status.remaining
        let n = Int((value / 10).rounded() * 10)
        return isOver ? "\(n.formatted()) over today"
                      : "\(n.formatted()) left today"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .stroke(Color.borderHairline, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: clamped)
                        .stroke(ringColor,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil
                                   : .spring(response: 0.6, dampingFraction: 0.85),
                                   value: clamped)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .appFont(.title2)
                        .foregroundStyle(isOver ? Color.error : Color.ink)
                    Text("of \(Int(status.goal).formatted()) kcal goal")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)

                    if showBurnOff {
                        let walk = ActivityBurnEstimator.walkMinutes(
                            toBurn: status.exceededBy, weightKg: bodyWeightKg)
                        let jog = ActivityBurnEstimator.jogMinutes(
                            toBurn: status.exceededBy, weightKg: bodyWeightKg)
                        HStack(spacing: 5) {
                            Image(systemName: "figure.walk")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.brandDeep)
                            Text("\(walk)-min walk or \(jog)-min jog to burn it off")
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    } else if let eatLine = MealSuggestionEngine.compactLine(
                                remaining: status.remaining) {
                        // Under goal → one calm line on what fits. The
                        // headline already carries the number.
                        HStack(spacing: 5) {
                            Image(systemName: "fork.knife")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.brandDeep)
                            Text(eatLine)
                                .appFont(.caption)
                                .foregroundStyle(Color.inkMute)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.inkLight)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
            )
            .appShadow(.shadowCard)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline)
        .accessibilityHint("Opens today's tracker")
    }
}

struct DailyCheckInCard: View {
    let mealCount: Int
    let rhythm: LoggingRhythmStore.Rhythm
    let status: DailyCalorieGoalStatus?
    let now: Date

    /// Local hour above which the end-of-day return hook is permitted.
    /// Lives here (not in a service) because the hook is purely a UI
    /// concern — there is no notification or scheduler involved.
    private static let endOfDayHourLocal: Int = 20

    private var hasGoal: Bool {
        status?.hasValidGoal == true
    }

    private var isEndOfDay: Bool {
        Calendar.current.component(.hour, from: now) >= Self.endOfDayHourLocal
    }

    private var primaryText: String {
        switch mealCount {
        case 0:
            // Personalize the empty state when the rhythm store knows
            // the user has logged recently. Falls through to the
            // generic copy if there's no usable history.
            if rhythm.yesterdayLogged {
                return "Back from yesterday, start today with one photo."
            }
            if let last = rhythm.lastLoggedDate {
                return "Your last log was \(Self.relativeDayPhrase(for: last, now: now)). Ready for today's first meal?"
            }
            return "Start today with one photo."
        case 1:
            return "Nice start, 1 meal logged today."
        case 2:
            return "You're building today's picture."
        default:
            return "Today is well tracked."
        }
    }

    /// Optional sub-line. Order of precedence:
    ///   1. End-of-day hook (already-logged users in the 20:00+ window).
    ///   2. Calorie hint, combined with the count, when there's a goal
    ///      and at least one meal.
    ///   3. Calorie hint alone (empty state, valid goal).
    ///   4. Rhythm copy (first-ever check-in / multi-day rhythm).
    ///   5. Nothing.
    private var secondaryText: String? {
        if isEndOfDay, mealCount >= 1 {
            return "Your day is almost complete. Come back tomorrow for a fresh pulse."
        }
        // Calorie standing now lives in the always-on TodayGoalCard above,
        // so this card stays focused on rhythm/encouragement and doesn't
        // echo the same "X calories left" number twice on one screen.
        if let status, status.hasValidGoal, mealCount == 0 {
            // Empty state with a goal set — keep the calorie sub-line
            // quiet (we don't want to greet the user with their target
            // before they've logged anything). Surface rhythm instead
            // if it exists.
            if rhythm.consecutiveDays >= 2 {
                return "You're on a \(rhythm.consecutiveDays)-day logging rhythm."
            }
            return nil
        }
        if rhythm.todayLogged, rhythm.totalLoggedDays == 1 {
            return "First check-in logged."
        }
        if rhythm.consecutiveDays >= 2 {
            return "You're on a \(rhythm.consecutiveDays)-day logging rhythm."
        }
        return nil
    }

    /// Combined first line: meal-count copy with the calorie cue
    /// inlined when both are present. Example: "2 meals logged · about
    /// 420 calories left". Kept as a derived view of `primaryText` +
    /// `secondaryText` for the count-with-calorie variant only; all
    /// other states render the two lines stacked.
    private var combinedPrimary: String? {
        guard let status, status.hasValidGoal, mealCount >= 1 else { return nil }
        let countPhrase: String = {
            switch mealCount {
            case 1: return "1 meal logged"
            default: return "\(mealCount) meals logged"
            }
        }()
        let caloriePhrase: String
        if status.warningState == .reached || status.exceededBy > 0 {
            caloriePhrase = "goal reached"
        } else {
            caloriePhrase = "about \(Int(status.remaining.rounded())) calories left"
        }
        return "\(countPhrase) · \(caloriePhrase)"
    }

    private var iconName: String {
        if isEndOfDay, mealCount >= 1 { return "moon.stars.fill" }
        switch mealCount {
        case 0:  return "sun.max.fill"
        case 1:  return "leaf.fill"
        case 2:  return "leaf.fill"
        default: return "checkmark.seal.fill"
        }
    }

    private var iconAccent: Color {
        if mealCount >= 3 { return .brandDeep }
        return .brand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.brandSoft)
                        .frame(width: 28, height: 28)
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(iconAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(combinedPrimary ?? primaryText)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if combinedPrimary == nil, let secondary = secondaryText {
                        Text(secondary)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let combined = combinedPrimary { return combined }
        if let secondary = secondaryText {
            return "\(primaryText) \(secondary)"
        }
        return primaryText
    }

    /// Compact phrasing of a recent past date relative to `now`. Mirrors
    /// the rhythm store's 30-day cap; older dates would never land here.
    private static func relativeDayPhrase(for date: Date,
                                          now: Date,
                                          calendar: Calendar = .current) -> String {
        let dayDelta = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if dayDelta <= 1 { return "yesterday" }
        if dayDelta < 7 {
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Change-photo floating button

/// Small floating "swap photo" button overlaid on the captured image
/// so the user can re-pick from camera or library without the whole
/// "tap-the-card" affordance being invisible. Visual:
///   - 32pt circle, ultra-thin material fill — stays legible over any
///     food photo, light or dark
///   - white hairline stroke for edge contrast
///   - SF Symbol `arrow.triangle.2.circlepath` (the conventional swap
///     glyph) in ink color
///   - soft drop shadow, press-scale to 0.88× tied to `.appPress`
struct ChangePhotoButton: View {
    let action: () -> Void
    @State private var pressed: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.ink)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.ink.opacity(0.22), radius: 6, x: 0, y: 2)
            .scaleEffect(pressed ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.appPress) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.appPress) { pressed = false }
                }
        )
        .accessibilityLabel("Change photo")
        .accessibilityHint("Pick a different photo from camera or library")
    }
}

struct RemovePhotoButton: View {
    let action: () -> Void
    @State private var pressed: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.ink)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.ink.opacity(0.22), radius: 6, x: 0, y: 2)
            .scaleEffect(pressed ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.appPress) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.appPress) { pressed = false }
                }
        )
        .accessibilityLabel("Remove photo")
        .accessibilityHint("Return to the empty scan card")
    }
}
