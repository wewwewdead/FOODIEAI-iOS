import SwiftUI
import UIKit
import UserNotifications

/// Phase 17. Profile → Notifications screen.
///
/// Layout:
///   [ Master toggle: "Enable nudges" ]
///   [ Breakfast — usually 8:00 AM ]   (rows disabled when master off)
///   [ Lunch — usually 12:30 PM ]
///   [ Dinner — usually 7:00 PM ]
///   ──
///   [ Sunday evening recap ]
///        Every Sunday at 7 PM.
///   [ Open notification settings → ]
///
/// Each toggle persists immediately to `profiles` and triggers a
/// `NotificationScheduler.reschedule(...)`. When the user flips a meal
/// reminder on while system permission is `.denied`, the
/// `NotificationDeniedView` sheet appears with the "Open Settings"
/// affordance.
///
/// The inferred eating times are shown even when notifications are
/// off — the prompt called this out as a "the app knows me" moment.
struct NotificationSettingsView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var viewModel = NotificationSettingsViewModel()

    @State private var showDeniedSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                masterToggle
                mealToggles
                Divider()
                    .padding(.horizontal, AppSpacing.sm)
                recapToggle
                openSettingsLink
                if let error = viewModel.lastError {
                    Text(error.localizedDescription)
                        .appFont(.caption)
                        .foregroundStyle(Color.error)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.bgCanvas)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await viewModel.bootstrap(from: profileStore)
        }
        .onChange(of: profileStore.profile) { _, _ in
            viewModel.refreshFromStore(profileStore)
        }
        .sheet(isPresented: $showDeniedSheet) {
            NotificationDeniedView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Sections

    private var masterToggle: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ToggleRow(
                title: "Enable nudges",
                subtitle: "Daily reminders at the times you usually eat.",
                isOn: viewModel.masterEnabled,
                isEnabled: !viewModel.isSaving
            ) { newValue in
                Task {
                    if newValue {
                        await turnMasterOn()
                    } else {
                        await viewModel.setMaster(false, store: profileStore)
                    }
                }
            }
        }
    }

    private var mealToggles: some View {
        VStack(spacing: AppSpacing.sm) {
            ToggleRow(
                title: "Breakfast",
                subtitle: usualTimeSubtitle(viewModel.inferred.breakfast,
                                            confidence: viewModel.inferred.confidence),
                isOn: viewModel.breakfast,
                isEnabled: viewModel.masterEnabled && !viewModel.isSaving
            ) { newValue in
                Task { await viewModel.setBreakfast(newValue, store: profileStore) }
            }
            ToggleRow(
                title: "Lunch",
                subtitle: usualTimeSubtitle(viewModel.inferred.lunch,
                                            confidence: viewModel.inferred.confidence),
                isOn: viewModel.lunch,
                isEnabled: viewModel.masterEnabled && !viewModel.isSaving
            ) { newValue in
                Task { await viewModel.setLunch(newValue, store: profileStore) }
            }
            ToggleRow(
                title: "Dinner",
                subtitle: usualTimeSubtitle(viewModel.inferred.dinner,
                                            confidence: viewModel.inferred.confidence),
                isOn: viewModel.dinner,
                isEnabled: viewModel.masterEnabled && !viewModel.isSaving
            ) { newValue in
                Task { await viewModel.setDinner(newValue, store: profileStore) }
            }
        }
    }

    private var recapToggle: some View {
        ToggleRow(
            title: "Sunday evening recap",
            subtitle: "Every Sunday at 7 PM.",
            isOn: viewModel.weeklyRecap,
            isEnabled: viewModel.masterEnabled && !viewModel.isSaving
        ) { newValue in
            Task { await viewModel.setWeeklyRecap(newValue, store: profileStore) }
        }
    }

    private var openSettingsLink: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack {
                Text("Open notification settings")
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.brandDeep)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.borderHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Master-on flow

    /// Tapping master ON when system status is `.denied` should route
    /// to Settings.app via the denied sheet — not flip the local
    /// toggle (which would lie about scheduling). For `.notDetermined`
    /// we surface the pre-prompt sheet via the standard gate; for
    /// `.authorized` / `.provisional` we just persist.
    private func turnMasterOn() async {
        let status = await NotificationScheduler.shared.authorizationStatus()
        switch status {
        case .denied:
            showDeniedSheet = true
            return
        case .notDetermined:
            let granted = await NotificationScheduler.shared.requestAuthorization()
            guard granted else {
                NotificationGate.defer30Days()
                return
            }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }
        await viewModel.setMaster(true, store: profileStore)
    }

    // MARK: - Helpers

    private func usualTimeSubtitle(_ comps: DateComponents?,
                                   confidence: EatingTimeInference.Confidence) -> String {
        guard let comps, let h = comps.hour, let m = comps.minute else {
            return "We don't have a usual time yet."
        }
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        var dc = DateComponents(); dc.hour = h; dc.minute = m
        let dt = Calendar.current.date(from: dc) ?? Date()
        let label = f.string(from: dt)
        switch confidence {
        case .insufficient: return "Suggested time \(label)."
        case .low:          return "Around \(label) — based on a few logs."
        case .good:         return "Usually \(label)."
        }
    }
}

// MARK: - Toggle row

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in onChange(newValue) }
            ))
            .labelsHidden()
            .tint(Color.brand)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.55)
    }
}

// MARK: - View model

/// Owns the local toggle state, computes the inferred-time labels,
/// and persists changes by routing through `ProfileService` +
/// `NotificationScheduler`. Toggles are optimistic — the local state
/// flips immediately; a write failure rolls back via `seed`.
@MainActor
final class NotificationSettingsViewModel: ObservableObject {
    @Published private(set) var masterEnabled: Bool = false
    @Published private(set) var breakfast: Bool = true
    @Published private(set) var lunch: Bool = true
    @Published private(set) var dinner: Bool = true
    @Published private(set) var weeklyRecap: Bool = true

    @Published private(set) var inferred: EatingTimeInference.InferredTimes =
        .init(breakfast: EatingTimeInference.defaultBreakfast,
              lunch: EatingTimeInference.defaultLunch,
              dinner: EatingTimeInference.defaultDinner,
              confidence: .insufficient)
    @Published private(set) var isSaving: Bool = false
    @Published private(set) var lastError: Error? = nil

    private let profileService: ProfileService
    private let history: MealHistoryService
    private let scheduler: NotificationScheduler

    init(profileService: ProfileService = ProfileService(),
         history: MealHistoryService = MealHistoryService(),
         scheduler: NotificationScheduler? = nil) {
        self.profileService = profileService
        self.history = history
        // See AppForegroundOrchestrator.init for the rationale on the
        // `.shared` indirection — Swift 6 forbids MainActor-isolated
        // defaults in non-isolated argument position.
        self.scheduler = scheduler ?? .shared
    }

    func bootstrap(from store: ProfileStore) async {
        seed(from: store.profile)
        // Background-load the inference so the time labels populate
        // even on first open. Don't block the UI — labels start at
        // the static defaults in `inferred`.
        Task { await refreshInferredTimes() }
    }

    func refreshFromStore(_ store: ProfileStore) {
        seed(from: store.profile)
    }

    // MARK: - Toggles (optimistic + persistent)

    func setMaster(_ on: Bool, store: ProfileStore) async {
        await update(store: store) {
            self.masterEnabled = on
            return try await self.profileService.setNotificationPreferences(
                notificationsEnabled: on
            )
        }
    }

    func setBreakfast(_ on: Bool, store: ProfileStore) async {
        await update(store: store) {
            self.breakfast = on
            return try await self.profileService.setNotificationPreferences(
                reminderBreakfast: on
            )
        }
    }

    func setLunch(_ on: Bool, store: ProfileStore) async {
        await update(store: store) {
            self.lunch = on
            return try await self.profileService.setNotificationPreferences(
                reminderLunch: on
            )
        }
    }

    func setDinner(_ on: Bool, store: ProfileStore) async {
        await update(store: store) {
            self.dinner = on
            return try await self.profileService.setNotificationPreferences(
                reminderDinner: on
            )
        }
    }

    func setWeeklyRecap(_ on: Bool, store: ProfileStore) async {
        await update(store: store) {
            self.weeklyRecap = on
            return try await self.profileService.setNotificationPreferences(
                weeklyRecapEnabled: on
            )
        }
    }

    // MARK: - Internals

    private func seed(from profile: Profile?) {
        guard let profile else { return }
        masterEnabled = profile.notificationsEnabled
        breakfast     = profile.reminderBreakfast
        lunch         = profile.reminderLunch
        dinner        = profile.reminderDinner
        weeklyRecap   = profile.weeklyRecapEnabled
    }

    private func refreshInferredTimes() async {
        do {
            let logs = try await history.recentMealsForCoachContext()
            let tz = TimeZone.current
            let result = EatingTimeInference.infer(from: logs, timeZone: tz)
            await MainActor.run { self.inferred = result }
        } catch {
            #if DEBUG
            NSLog("[NotifSettings] inference fetch FAILED: %@", "\(error)")
            #endif
        }
    }

    /// Common save+reschedule wrapper. Run the persisted write inside
    /// `op`, which returns the freshly-loaded profile so we can refresh
    /// the shared store and reschedule.
    private func update(store: ProfileStore,
                        op: @escaping () async throws -> Profile) async {
        guard !isSaving else { return }
        isSaving = true
        lastError = nil
        defer { isSaving = false }

        do {
            let updated = try await op()
            store.apply(updated)
            await reschedule(profile: updated)
            Haptics.selection()
        } catch {
            #if DEBUG
            NSLog("[NotifSettings] save FAILED: %@", "\(error)")
            #endif
            lastError = error
            seed(from: store.profile) // roll back optimistic flip
            Haptics.error()
        }
    }

    private func reschedule(profile: Profile) async {
        let prefs = NotificationPreferences(profile: profile)
        // Refresh inference each reschedule — log distribution may have
        // changed since the screen opened.
        await refreshInferredTimes()
        let tz = profile.timeZone.flatMap { TimeZone(identifier: $0) } ?? .current
        await scheduler.reschedule(
            preferences: prefs, inferred: inferred, timeZone: tz
        )
    }
}

#if DEBUG
#Preview("NotificationSettings") {
    NavigationStack {
        NotificationSettingsView()
            .environmentObject(ProfileStore())
    }
}
#endif
