#if DEBUG
import SwiftUI

/// `LAUNCH_PROFILE_UPDATE_PROBE=1` entry point. Renders the real
/// `ProfileView` but, on appear, drives a programmatic round-trip:
///
///   1. Wait for the initial `load()` to complete.
///   2. Mutate the four drafts to a fixed Phase 7 verification payload.
///   3. Call `save()` — exercises the live UPDATE against the
///      RLS-protected `profiles` row.
///   4. NSLog the new `updated_at` so the verification report can confirm
///      the row actually changed in Postgres, not just in memory.
///
/// Used to capture the live UPDATE network log + a real "saved" screenshot
/// without simulator UI taps.
struct ProfileUpdateProbeView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var viewModel: ProfileViewModel

    @State private var didTrigger = false

    /// Probe payload — picked to differ from schema defaults so the
    /// `hasUnsavedChanges` flag latches reliably.
    static let probeName     = "Phase 7 Probe"
    static let probeCalories = 2200
    static let probeCarbs    = 230
    static let probeSugar    = 45

    init() {
        _viewModel = StateObject(
            wrappedValue: ProfileViewModel(auth: AuthService())
        )
    }

    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                statusLine
                Divider()
                ProfileFormShim(viewModel: viewModel)
            }
            .padding(AppSpacing.lg)
        }
        .task {
            guard !didTrigger else { return }
            didTrigger = true
            NSLog("[Probe] starting — loading profile")
            await viewModel.load()
            NSLog("[Probe] load done — state=%@", String(describing: viewModel.state))

            // Mutate drafts to the probe payload.
            viewModel.displayNameDraft = Self.probeName
            viewModel.calorieGoalDraft = Self.probeCalories
            viewModel.carbGoalDraft    = Self.probeCarbs
            viewModel.sugarGoalDraft   = Self.probeSugar

            // Give Combine a turn so hasUnsavedChanges latches before save().
            try? await Task.sleep(nanoseconds: 100_000_000)
            NSLog("[Probe] hasUnsavedChanges=%@ — calling save()",
                  viewModel.hasUnsavedChanges ? "true" : "false")

            await viewModel.save()
            NSLog("[Probe] save done — isSaving=%@ saveError=%@ hasUnsavedChanges=%@",
                  viewModel.isSaving ? "true" : "false",
                  viewModel.saveError.map { "\($0)" } ?? "nil",
                  viewModel.hasUnsavedChanges ? "true" : "false")
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("LAUNCH_PROFILE_UPDATE_PROBE")
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
            Text("Drafts → name=\(Self.probeName), cal=\(Self.probeCalories), carb=\(Self.probeCarbs), sugar=\(Self.probeSugar)")
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
        }
    }
}

/// Renders the same fields ProfileView uses but bound to the probe's VM.
/// Lets us screenshot the resulting state without going through the
/// production ProfileView (which owns its own private @StateObject VM).
private struct ProfileFormShim: View {
    @ObservedObject var viewModel: ProfileViewModel

    var body: some View {
        switch viewModel.state {
        case .loading:
            HStack { ProgressView(); Text("loading…").appFont(.body) }
        case .failed(let error):
            Text("FAILED: \(error.localizedDescription)")
                .appFont(.body)
                .foregroundStyle(Color.redError)
        case .loaded(let profile):
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("Display name: \(viewModel.displayNameDraft)")
                Text("Calories: \(viewModel.calorieGoalDraft)")
                Text("Carbs: \(viewModel.carbGoalDraft)g")
                Text("Sugar: \(viewModel.sugarGoalDraft)g")
                Divider()
                Text("hasUnsavedChanges: \(viewModel.hasUnsavedChanges ? "YES" : "no")")
                Text("isSaving: \(viewModel.isSaving ? "YES" : "no")")
                if let err = viewModel.saveError {
                    Text("saveError: \(err.localizedDescription)")
                        .foregroundStyle(Color.redError)
                }
                Divider()
                Text("DB row")
                    .appFont(.meta).foregroundStyle(Color.textMeta)
                Text("id=\(profile.id.uuidString)")
                    .appFont(.meta).foregroundStyle(Color.textBody)
                Text("updated_at=\(ISO8601DateFormatter().string(from: profile.updatedAt))")
                    .appFont(.meta).foregroundStyle(Color.textBody)
                Text("display_name=\(profile.displayName ?? "<nil>")")
                    .appFont(.meta).foregroundStyle(Color.textBody)
                Text("daily_calorie_goal=\(profile.dailyCalorieGoal)")
                    .appFont(.meta).foregroundStyle(Color.textBody)
                Text("daily_carb_goal_g=\(profile.dailyCarbGoalG)")
                    .appFont(.meta).foregroundStyle(Color.textBody)
                Text("daily_sugar_goal_g=\(profile.dailySugarGoalG)")
                    .appFont(.meta).foregroundStyle(Color.textBody)
            }
            .font(AppFont.font(.body))
            .foregroundStyle(Color.textPrimary)
        }
    }
}

#endif
