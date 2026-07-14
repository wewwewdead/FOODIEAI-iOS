import SwiftUI
import UIKit
import HealthKit
import CoreMotion

// Extracted from TodayView.swift (2026-07) to shrink the file.
// The shareable streak card, its image renderer, and the Daily Loop paired-ring hero subview. Types are module-scoped so the parent view still references them.

// MARK: - Shareable record card

/// Branded, screenshot-ready card for sharing a streak / record to the iOS
/// share sheet — Strava's "flex" without a social backend. Rendered to a
/// flat image by `ShareCardRenderer`; no network, just pixels. Square so it
/// drops cleanly into stories, posts, and messages.
struct StreakShareCard: View {
    let days: Int
    let label: String   // "day streak" / "best streak"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.brandBright, Color.brand],
                startPoint: .top, endPoint: .bottom
            )

            // Soft ring flourish echoing the Month/Week header motif.
            Circle()
                .strokeBorder(Color.brandDeep.opacity(0.10), lineWidth: 2)
                .frame(width: 420, height: 420)
                .offset(x: 150, y: -170)

            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.system(size: 76, weight: .bold))
                    .foregroundStyle(Color.accentWarm)
                Text("\(days)")
                    .font(.custom(AppFont.PS.mplusBlack, size: 150))
                    .kerning(-3)
                    .foregroundStyle(Color.brandDeep)
                Text(label.uppercased())
                    .font(.custom(AppFont.PS.nunitoExtraBold, size: 25))
                    .tracking(3)
                    .foregroundStyle(Color.brandDeep.opacity(0.85))
                Spacer()
                Text("FoodieAI")
                    .font(.custom(AppFont.PS.mplusBlack, size: 22))
                    .foregroundStyle(Color.brandDeep.opacity(0.70))
                    .padding(.bottom, 28)
            }
            .padding(30)
        }
        .frame(width: 360, height: 360)
    }
}

/// Rasterizes a SwiftUI view into a shareable `Image` using the native
/// `ImageRenderer` (iOS 16+). Main-actor isolated because ImageRenderer is.
@MainActor
enum ShareCardRenderer {
    static func render<V: View>(_ view: V, scale: CGFloat = 3) -> Image? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let ui = renderer.uiImage else { return nil }
        return Image(uiImage: ui)
    }

    static func streakImage(days: Int, label: String) -> Image? {
        render(StreakShareCard(days: days, label: label))
    }
}


/// Reads today's movement from HealthKit (steps + active energy) so the goal
/// loop can reflect "I moved" — the activity half of the energy loop. Fully
/// guarded: every path no-ops when Health data is unavailable or read access
/// hasn't been granted, so the app behaves identically when HealthKit isn't
/// set up. Read-only — we never write to Health.
///
/// NOTE (device pass): functional only once the **HealthKit capability** is
/// added in Xcode → Signing & Capabilities (which registers the App ID
/// capability under automatic signing) and the user grants read access on a
/// real device. Adding the entitlement by hand without that registration is
/// what risks breaking signing, so it's intentionally left to the Xcode UI.
@MainActor
final class HealthActivityService: ObservableObject {
    static let shared = HealthActivityService()

    struct TodayActivity: Equatable {
        let steps: Int
        let activeEnergyKcal: Double
    }

    @Published private(set) var today: TodayActivity?
    /// True once the user has run the auth request without it erroring — i.e.
    /// the capability/provisioning is in place and they opted in. Read access
    /// itself is opaque (Apple hides it), so this only means "connected," not
    /// "granted." Persisted so the movement ring keeps showing across launches
    /// even before today's first steps land — e.g. just after local midnight.
    @Published private(set) var connected: Bool

    private let store = HKHealthStore()
    private let defaults: UserDefaults
    private let connectedKey = "foodie.health.connected.v1"
    /// Live-update plumbing — observer queries + a polling timer that run only
    /// while a movement surface is on screen (see `startLiveUpdates`).
    private var liveObservers: [HKObserverQuery] = []
    private var liveTimer: Timer?
    /// True while the sensor streams are running. Guards against the 2–3
    /// `startLiveUpdates` calls that fire in a burst on a foreground+active-tab
    /// transition tearing down and rebuilding the sensors needlessly.
    private var isLive = false

    /// Core Motion pedometer for *real-time* step updates. HealthKit only
    /// commits steps in delayed batches, so the ring would lag behind an
    /// active walk; `CMPedometer` streams the live cumulative count straight
    /// from the motion chip (~1s cadence). Foreground + real-device only.
    private let pedometer = CMPedometer()
    /// Last values from each source. We publish the *max* of the two step
    /// counts so the ring never visibly drops (HealthKit may include Watch
    /// steps; the pedometer is iPhone-only but instant).
    private var hkSteps: Int?
    private var hkEnergy: Double?
    private var liveSteps: Int?
    /// Live active-energy estimate derived from `liveSteps` × bodyweight (see
    /// `MovementEnergy.activeKcalFromSteps`). HealthKit has no live-calorie
    /// stream, so this walking-only estimate is what makes the active-kcal
    /// figure climb in real time; the measured HK value overtakes it (we
    /// publish the max) once HealthKit commits. Needs `liveWeightKg`.
    private var liveActiveKcal: Double?
    private var liveWeightKg: Double?
    /// The local day the live streams were armed for. The pedometer's cumulative
    /// count is anchored to the midnight it started from, so if the app stays
    /// open across midnight we must re-arm to reset to the new day (see `tick`).
    private var liveStartDay: Date?
    /// Persistent HealthKit observer that keeps the home-screen widget fresh
    /// while the app is closed (see `enableWidgetBackgroundSync`). Distinct from
    /// `liveObservers` — this one is NOT torn down by `stopLiveUpdates`; it must
    /// outlive the foreground session so HealthKit can resume the app for it.
    private var widgetObserver: HKObserverQuery?
    /// True once `enableBackgroundDelivery` has succeeded, so we don't keep
    /// re-requesting it every foreground (it fails until step-read is granted).
    private var widgetBackgroundDeliveryOn = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.connected = defaults.bool(forKey: connectedKey)
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        return types
    }

    /// Request read access. HealthKit shows the system sheet at most once;
    /// returns false when Health is unavailable or the request errors (e.g.
    /// the capability isn't enabled yet).
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            if !connected {
                connected = true
                defaults.set(true, forKey: connectedKey)
            }
            // Now that read access is (likely) granted, arm the background
            // widget sync so it works this very session — not just after the
            // next foreground.
            enableWidgetBackgroundSync()
            return true
        } catch {
            return false
        }
    }

    /// Keep the home-screen widget's step count fresh while the app is closed,
    /// at low battery cost. iOS wakes the app in the background — at most
    /// **hourly** for steps, never per-footstep — when new step data lands; we
    /// query today's steps and update just the widget snapshot's `steps` field.
    /// This is the ceiling iOS allows: truly live (per-step) widget updates from
    /// a closed app aren't possible on the platform. Idempotent — safe to call
    /// on every foreground; re-requests background delivery until it succeeds
    /// (it fails until the user grants step-read access). Requires the HealthKit
    /// Background Delivery entitlement.
    func enableWidgetBackgroundSync(timeZone: TimeZone = .current) {
        guard isAvailable,
              let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }

        // Execute the long-lived observer once per process. Its handler is what
        // HealthKit invokes (by resuming the app) when new step data arrives.
        if widgetObserver == nil {
            let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    await self?.syncWidgetSteps(timeZone: timeZone)
                    completion()   // MUST signal completion or HealthKit stops delivering
                }
            }
            store.execute(query)
            widgetObserver = query
        }

        guard !widgetBackgroundDeliveryOn else { return }
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { [weak self] success, _ in
            guard success else { return }
            Task { @MainActor in self?.widgetBackgroundDeliveryOn = true }
        }
    }

    /// Background path: refresh only the widget's step count from HealthKit.
    /// The other daily figures are owned by the foreground app (a step doesn't
    /// change calories/streak), so we leave them as last written.
    func syncWidgetSteps(timeZone: TimeZone = .current) async {
        guard let steps = await sum(.stepCount, unit: .count(), timeZone: timeZone) else { return }
        WidgetSnapshotUpdater.updateSteps(Int(steps))
    }

    /// Load today's totals for the user's local day. Surfaces a card only
    /// when Health actually returned a value; otherwise clears it. Live
    /// pedometer steps (if any) are merged in via `publishActivity`.
    func refreshToday(timeZone: TimeZone = .current) async {
        guard isAvailable else { return }
        async let steps = sum(.stepCount, unit: .count(), timeZone: timeZone)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), timeZone: timeZone)
        let s = await steps
        let e = await energy
        hkSteps = s.map { Int($0) }
        hkEnergy = e
        publishActivity()
    }

    /// Combine the live + batched sources into the published `today`. Both
    /// steps and active energy publish the *larger* of (live, measured) so the
    /// ring never jumps backward; clears `today` only when nothing has data.
    private func publishActivity() {
        let steps = maxOptional(liveSteps, hkSteps)
        let energy = maxOptional(liveActiveKcal, hkEnergy)
        if steps == nil && energy == nil {
            today = nil
        } else {
            today = TodayActivity(steps: steps ?? 0, activeEnergyKcal: energy ?? 0)
        }
    }

    private func maxOptional<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (x?, y?): return Swift.max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    /// Apply a fresh live step count from the pedometer stream, and refresh the
    /// step-derived live active-energy estimate alongside it.
    private func applyLiveSteps(_ steps: Int) {
        liveSteps = steps
        if let kg = liveWeightKg {
            let est = MovementEnergy.activeKcalFromSteps(steps, weightKg: kg)
            liveActiveKcal = est >= 1 ? est : nil
        }
        publishActivity()
    }

    /// Supply the bodyweight used for the live active-energy estimate. Safe to
    /// call as the profile loads/changes; recomputes against the current live
    /// step count without restarting the sensor streams.
    func setMovementWeight(_ kg: Double?) {
        guard liveWeightKg != kg else { return }
        liveWeightKg = kg
        if let steps = liveSteps { applyLiveSteps(steps) }
    }

    /// Begin live-ish step/energy updates while a movement surface is visible.
    /// Two mechanisms, because HealthKit writes pedometer data in batches:
    ///   - an `HKObserverQuery` that re-fetches the instant new data lands, and
    ///   - a light 30s polling timer that catches the in-between so the ring
    ///     keeps climbing as you walk.
    /// Call from `.onAppear`; ALWAYS pair with `stopLiveUpdates()` on disappear
    /// so observers/timers don't leak. Foreground-only (no background delivery).
    func startLiveUpdates(timeZone: TimeZone = .current, weightKg: Double? = nil) {
        if let weightKg { liveWeightKg = weightKg }
        // Already streaming → don't churn the sensors. Callers fire this 2–3×
        // in a burst on a foreground+active-tab transition; just keep the
        // estimate weight current and bail.
        guard !isLive else {
            if let steps = liveSteps { applyLiveSteps(steps) }
            return
        }
        stopLiveUpdates()  // clean slate (also resets isLive)
        isLive = true

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: Date())
        liveStartDay = startOfDay

        // Real-time path: stream live cumulative steps since local midnight.
        // This is what actually makes the ring climb as you walk; the
        // HealthKit observers below only catch up energy + a Watch-inclusive
        // total in the background.
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startOfDay) { [weak self] data, error in
                guard let data, error == nil else { return }
                let steps = data.numberOfSteps.intValue
                Task { @MainActor in self?.applyLiveSteps(steps) }
            }
        }

        guard isAvailable else { return }
        for id in [HKQuantityTypeIdentifier.stepCount, .activeEnergyBurned] {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    await self?.refreshToday(timeZone: timeZone)
                    completion()
                }
            }
            store.execute(query)
            liveObservers.append(query)
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick(timeZone: timeZone) }
        }
    }

    /// Periodic live refresh. If the local day rolled over while the app stayed
    /// open, re-arm the streams so the pedometer restarts from the new midnight
    /// — its cumulative count is anchored to the day it started, so without this
    /// an app left open past midnight would keep showing yesterday's steps.
    private func tick(timeZone: TimeZone) async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if let day = liveStartDay, !cal.isDate(day, inSameDayAs: Date()) {
            let kg = liveWeightKg
            stopLiveUpdates()                                    // clears the stale live count
            startLiveUpdates(timeZone: timeZone, weightKg: kg)   // re-anchors to today's midnight
        }
        await refreshToday(timeZone: timeZone)
    }

    /// Tear down the live observers, polling timer, and pedometer stream.
    /// Idempotent. Clears the cached live count so a later restart (e.g. after
    /// a day rollover) can't briefly publish yesterday's total.
    func stopLiveUpdates() {
        for query in liveObservers { store.stop(query) }
        liveObservers.removeAll()
        liveTimer?.invalidate()
        liveTimer = nil
        if CMPedometer.isStepCountingAvailable() {
            pedometer.stopUpdates()
        }
        liveSteps = nil
        liveActiveKcal = nil
        liveStartDay = nil
        isLive = false
    }

    private func sum(_ id: HKQuantityTypeIdentifier,
                     unit: HKUnit,
                     timeZone: TimeZone) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}

// MARK: - Daily Loop hero (extracted observing subview)

/// The paired calories + movement rings, pulled out of `TodayView` into its own
/// view. `HealthActivityService` is `@ObservedObject` HERE (not on TodayView),
/// so a live step/active-energy tick invalidates ONLY this subview — not the
/// ~2,400-line TodayView body, which used to re-run `MealSuggestionEngine` +
/// `DayCalorieStanding` on every footstep. Calorie/profile inputs are passed in,
/// so a meal log re-renders the parent (and this), while a step re-renders only
/// this. The parent keeps its own non-observed reads of `health` for the widget
/// snapshot + eat-to-goal card, which don't need to update per step.
struct DailyLoopHeroView: View {
    let calories: Double
    let calorieGoal: Double
    let profile: Profile?
    @ObservedObject var health = HealthActivityService.shared

    private var movementGuidance: MovementGuidance.Result {
        MovementGuidance.compute(
            direction: profile?.weightGoalDirection,
            ageYears: profile?.ageYears,
            currentSteps: health.today?.steps ?? 0,
            consumed: calories,
            calorieGoal: calorieGoal,
            weightKg: profile?.weightKg
        )
    }
    private var dailyStepGoal: Int { movementGuidance.stepGoal }
    private var movementGoalSuggestion: String { movementGuidance.line }
    private var movementCreditKcal: Double {
        guard let profile, let activity = health.today else { return 0 }
        return MovementEnergy.budgetCredit(
            profile: profile,
            activeEnergyKcal: activity.activeEnergyKcal,
            steps: activity.steps
        )
    }

    private enum CalorieRingStanding: Equatable { case under, approaching, onGoal, over }
    private static let calorieToleranceKcal = DayCalorieStanding.onGoalToleranceKcal
    private static func calorieRingStanding(consumed: Double, goal: Double) -> CalorieRingStanding {
        guard goal > 0, consumed.isFinite else { return .under }
        let tol = calorieToleranceKcal
        if consumed >= goal + tol { return .over }
        if consumed >= goal - tol { return .onGoal }
        if consumed >= 0.80 * goal { return .approaching }
        return .under
    }

    var body: some View {
        let baseGoal = calorieGoal
        let credit = movementCreditKcal
        let effectiveGoal = baseGoal + credit
        let standing = Self.calorieRingStanding(consumed: calories, goal: effectiveGoal)
        VStack(spacing: AppSpacing.md) {
            if health.today != nil || health.connected {
                let activity = health.today
                HStack(alignment: .top, spacing: AppSpacing.xl) {
                    ringColumn(
                        value: calories, goal: effectiveGoal,
                        number: Self.heroNumber(calories), unit: "kcal",
                        tint: standing == .over ? .error : .brand,
                        caption: "energy in",
                        sub: credit >= 1
                            ? "of \(Self.heroNumber(baseGoal)) +\(Self.heroNumber(credit)) moved"
                            : "of \(Self.heroNumber(baseGoal))",
                        diameter: 128
                    )
                    ringColumn(
                        value: Double(activity?.steps ?? 0),
                        goal: Double(dailyStepGoal),
                        number: Self.heroNumber(Double(activity?.steps ?? 0)),
                        unit: "steps",
                        tint: .accentCool,
                        caption: "moving",
                        sub: movementSubtitle(activity),
                        diameter: 128,
                        celebratesOverflow: true
                    )
                }
                if credit >= 1 {
                    movementCreditChip(credit)
                }
                Text(movementGoalSuggestion)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.sm)
            } else {
                MetricRing(
                    value: calories, goal: baseGoal,
                    number: Self.heroNumber(calories), unit: "kcal",
                    tint: standing == .over ? .error : .brand,
                    diameter: 172
                )
                Text("of \(Self.heroNumber(baseGoal)) kcal goal")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                if health.isAvailable {
                    connectMovementCard
                }
            }
            calorieWarningCaption(standing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, AppSpacing.md)
        .animation(.appReduced, value: standing)
        .task { await health.refreshToday() }
    }

    private func movementCreditChip(_ credit: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .bold))
            Text("Moving earned back ~\(Self.heroNumber(credit)) kcal of room")
                .appFont(.captionStrong)
        }
        .foregroundStyle(Color.accentCool)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.brandSoft))
        .accessibilityLabel("Moving earned back about \(Self.heroNumber(credit)) calories of eating room.")
    }

    private func movementSubtitle(_ activity: HealthActivityService.TodayActivity?) -> String {
        guard let activity else { return "no data yet" }
        if activity.activeEnergyKcal >= 1 {
            return "~\(Int(activity.activeEnergyKcal.rounded())) kcal active"
        }
        return "goal \(Self.heroNumber(Double(dailyStepGoal)))"
    }

    private func ringColumn(value: Double, goal: Double,
                            number: String, unit: String, tint: Color,
                            caption: String, sub: String,
                            diameter: CGFloat,
                            celebratesOverflow: Bool = false) -> some View {
        VStack(spacing: AppSpacing.xs) {
            MetricRing(value: value, goal: goal, number: number,
                       unit: unit, tint: tint, diameter: diameter,
                       celebratesOverflow: celebratesOverflow)
            Text(caption.uppercased())
                .appFont(.labelEyebrow)
                .foregroundStyle(Color.inkMute)
            Text(sub)
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectMovementCard: some View {
        Button {
            Task {
                await health.requestAuthorization()
                await health.refreshToday()
            }
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                ZStack {
                    Circle().fill(Color.brandSoft).frame(width: 42, height: 42)
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentCool)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your movement")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                    Text("Connect Apple Health to show today's steps and active calories next to your goal, your full energy loop, in and out.")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Connect Apple Health")
                            .appFont(.captionStrong)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundStyle(Color.brandDeep)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(
                        LinearGradient(
                            colors: [Color.brandSoft.opacity(0.85), Color.bgSurface],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.brand.opacity(0.30), lineWidth: 1)
            )
            .appShadow(.shadowCard)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(.plain)
        .padding(.top, AppSpacing.sm)
        .accessibilityLabel("Add your movement. Connect Apple Health to show today's steps and active calories next to your goal.")
    }

    @ViewBuilder
    private func calorieWarningCaption(_ standing: CalorieRingStanding) -> some View {
        switch standing {
        case .under:
            EmptyView()
        case .approaching:
            VStack(spacing: 2) {
                Text("You're close to today's goal")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Text("Small choices now keep dinner flexible.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        case .onGoal:
            VStack(spacing: 2) {
                Text("Right on your goal today")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Text("Nicely balanced, a little room either way is fine.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        case .over:
            // For a gain goal a surplus is the plan working, not a slip —
            // affirm it instead of the gentle lose/maintain "fresh start" line.
            let isGain = profile?.weightGoalDirection == .gain
            VStack(spacing: 2) {
                Text(isGain ? "Surplus logged today" : "A little over today")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                Text(isGain
                     ? "That extra fuel is what builds, nice work."
                     : "No big deal, tomorrow's a fresh start.")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkLight)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        }
    }

    private static func heroNumber(_ v: Double) -> String {
        guard v.isFinite else { return "-" }
        return heroFormatter.string(from: NSNumber(value: v.rounded()))
            ?? "\(Int(v.rounded()))"
    }
    private static let heroFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
