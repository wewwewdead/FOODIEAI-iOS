import SwiftUI

/// Profile tab. Read + UPDATE only — the row is auto-created by the
/// `handle_new_user` DB trigger. Layout per DESIGN_SYSTEM.md, mobile
/// stacked: identity header, display name field, three daily-goal
/// steppers, save button, sign-out section.
struct ProfileView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var viewModel: ProfileViewModel
    @State private var showingAbout = false

    init() {
        // We can't read @EnvironmentObject during init; ProfileViewModel
        // takes the AuthService reference here for sign-out delegation.
        // A throwaway placeholder gets replaced from the View's onAppear
        // via its environment object — but using the @EnvironmentObject
        // pattern with @StateObject requires a slightly indirect dance.
        // Simpler: construct with a fresh AuthService alias; the actual
        // sign-out call delegates to client.auth.signOut which is shared
        // singleton state, so functionally equivalent.
        _viewModel = StateObject(wrappedValue: ProfileViewModel(auth: AuthService()))
    }

    var body: some View {
        ZStack {
            Color.brandCream.ignoresSafeArea()
            content
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $showingAbout) {
            AboutSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(Color.brand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let profile):
            loadedForm(profile: profile)
        case .failed(let error):
            failedView(error: error)
        }
    }

    // MARK: - Loaded form

    private func loadedForm(profile: Profile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                identityHeader(profile: profile)
                displayNameSection
                goalsSection
                saveButton
                if let saveError = viewModel.saveError {
                    errorBanner(saveError)
                }
                signOutSection
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func identityHeader(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let email = auth.session?.user.email {
                Text(email)
                    .appFont(.body)
                    .foregroundStyle(Color.textMeta)
            }
            Text("Member since \(memberSince(profile.createdAt))")
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Display name")
                .appFont(.displayMD)
                .foregroundStyle(Color.textPrimary)

            TextField("Your name", text: $viewModel.displayNameDraft)
                .font(AppFont.font(.body))
                .padding(AppSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(Color.brandIvory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(Color.panelBorder, lineWidth: 2)
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(TextInputAutocapitalization.words)
        }
    }

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Daily goals")
                .appFont(.displayMD)
                .foregroundStyle(Color.textPrimary)

            goalRow(
                label: "Calories",
                value: $viewModel.calorieGoalDraft,
                range: 0...10_000,
                step: 50,
                unit: ""
            )
            goalRow(
                label: "Carbs (g)",
                value: $viewModel.carbGoalDraft,
                range: 0...1_000,
                step: 5,
                unit: "g"
            )
            goalRow(
                label: "Sugar (g)",
                value: $viewModel.sugarGoalDraft,
                range: 0...500,
                step: 5,
                unit: "g"
            )
        }
    }

    private func goalRow(label: String,
                         value: Binding<Int>,
                         range: ClosedRange<Int>,
                         step: Int,
                         unit: String) -> some View {
        HStack(spacing: AppSpacing.md) {
            Text(label)
                .appFont(.body)
                .fontWeight(.bold)
                .foregroundStyle(Color.greenCalorie)
                .frame(width: 100, alignment: .leading)

            Spacer(minLength: 0)

            Text("\(value.wrappedValue)\(unit)")
                .appFont(.kcal)
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 100, alignment: .trailing)

            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.brandIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 2)
        )
    }

    @ViewBuilder
    private var saveButton: some View {
        // Always-visible-but-disabled when there's nothing to save.
        // Decision: keeping the button visible (greyed) so the user
        // doesn't get a layout shift when they make a change.
        PillButton(
            title: viewModel.isSaving ? "Saving…" : "Save changes",
            variant: .primary,
            isLoading: viewModel.isSaving,
            isDisabled: !viewModel.hasUnsavedChanges
        ) {
            Task { await viewModel.save() }
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Couldn't save. Try again.")
                .appFont(.body)
                .fontWeight(.bold)
                .foregroundStyle(Color.redError)
            Text(error.localizedDescription)
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signOutSection: some View {
        VStack(spacing: AppSpacing.sm) {
            PillButton(title: "Sign out", variant: .outline) {
                Task { await viewModel.signOut() }
            }
            .frame(maxWidth: .infinity)

            Text("You'll need to sign back in to access your meals.")
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(action: { showingAbout = true }) {
                Text("About FoodieAI")
                    .appFont(.meta)
                    .underline()
                    .foregroundStyle(Color.textMeta)
            }
            .padding(.top, AppSpacing.sm)
        }
        .padding(.top, AppSpacing.xl)
    }

    // MARK: - Failed state

    private func failedView(error: Error) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Couldn't load your profile")
                .appFont(.displayMD)
                .foregroundStyle(Color.redError)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            Text(error.localizedDescription)
                .appFont(.meta)
                .foregroundStyle(Color.textMeta)
                .multilineTextAlignment(.center)
            PillButton(title: "Try again", variant: .outline) {
                Task { await viewModel.load() }
            }
        }
        .padding(AppSpacing.xl)
    }

    // MARK: - Date formatting

    private func memberSince(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }
}

#if DEBUG
#Preview("ProfileView — loading") {
    ProfileView()
        .environmentObject(AuthService())
}
#endif
