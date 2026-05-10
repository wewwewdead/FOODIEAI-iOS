import SwiftUI

/// Profile tab. Read + UPDATE only — the row is auto-created by the
/// `handle_new_user` DB trigger. Layout per DESIGN_SYSTEM.md, mobile
/// stacked: identity header, display name field, three daily-goal
/// steppers, save button, sign-out section.
struct ProfileView: View {
    @EnvironmentObject private var auth: AuthService
    /// Optional because the Phase 7 verification probes
    /// (LAUNCH_PROFILE_DIRECT, LAUNCH_PROFILE_UPDATE_PROBE) instantiate
    /// ProfileView outside the MainTabView host that supplies the store.
    /// In the normal user flow (RootView → MainTabView), the store is
    /// always present and changes propagate to Tracker.
    @EnvironmentObject private var profileStore: ProfileStore
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
        // Phase 16: wrapped in a NavigationStack so the new "Coaches"
        // row's NavigationLink has a host. Title is hidden on the root
        // screen via inline display + an empty title, preserving the
        // pre-Phase-16 chromeless look while still letting child
        // screens (CoachPreferencesView) push with a back chevron.
        NavigationStack {
            ZStack {
                Color.bgCanvas
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.lastResolvedProfile) { _, newProfile in
            // Broadcast every successful load/save into the shared store
            // so Tracker (and any other observer) re-renders with the
            // updated daily goals without a manual refresh.
            if let profile = newProfile {
                profileStore.apply(profile)
            }
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
                coachesSection
                moodLogSection
                notificationsSection
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
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Phase 16. NavigationLink row → CoachPreferencesView. Wrapped in
    /// the existing tab's NavigationStack (provided by MainTabView).
    private var coachesSection: some View {
        NavigationLink {
            CoachPreferencesView()
                .environmentObject(profileStore)
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "person.2.crop.square.stack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coaches")
                        .appFont(.displayMD)
                        .foregroundStyle(Color.textPrimary)
                    Text(coachesSummary)
                        .appFont(.caption)
                        .foregroundStyle(Color.textMeta)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.inkLight)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.panelBorder, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Pick coaches you'd like to hear from" / "3 starred" / etc.
    private var coachesSummary: String {
        let count = profileStore.profile?.preferredCoaches.count ?? 0
        if count == 0 { return "Tap to star your favorites" }
        if count == 1 { return "1 starred" }
        return "\(count) starred"
    }

    /// Phase 18. NavigationLink → MoodLogView.
    private var moodLogSection: some View {
        NavigationLink {
            MoodLogView()
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mood log")
                        .appFont(.displayMD)
                        .foregroundStyle(Color.textPrimary)
                    Text("How meals have hit recently")
                        .appFont(.caption)
                        .foregroundStyle(Color.textMeta)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.inkLight)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.panelBorder, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Phase 17. NavigationLink → NotificationSettingsView.
    private var notificationsSection: some View {
        NavigationLink {
            NotificationSettingsView()
                .environmentObject(profileStore)
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brandDeep)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .appFont(.displayMD)
                        .foregroundStyle(Color.textPrimary)
                    Text(notificationsSummary)
                        .appFont(.caption)
                        .foregroundStyle(Color.textMeta)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.inkLight)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.panelBorder, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var notificationsSummary: String {
        guard let profile = profileStore.profile else {
            return "Off"
        }
        if !profile.notificationsEnabled { return "Off" }
        var parts: [String] = []
        if profile.reminderBreakfast { parts.append("Breakfast") }
        if profile.reminderLunch     { parts.append("Lunch") }
        if profile.reminderDinner    { parts.append("Dinner") }
        if profile.weeklyRecapEnabled { parts.append("recap") }
        return parts.isEmpty ? "On (no reminders)" : parts.joined(separator: " · ")
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
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
                        .fill(Color.bgSurface)
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
            goalRow(
                label: "Protein (g)",
                value: $viewModel.proteinGoalDraft,
                range: 0...1_000,
                step: 5,
                unit: "g"
            )
            goalRow(
                label: "Fat (g)",
                value: $viewModel.fatGoalDraft,
                range: 0...1_000,
                step: 5,
                unit: "g"
            )
            goalRow(
                label: "Fiber (g)",
                value: $viewModel.fiberGoalDraft,
                range: 0...500,
                step: 1,
                unit: "g"
            )
        }
    }

    private func goalRow(label: String,
                         value: Binding<Int>,
                         range: ClosedRange<Int>,
                         step: Int,
                         unit: String) -> some View {
        // `step` is retained in the signature for call-site compatibility
        // but unused now that the input is a free-form numeric field
        // rather than a Stepper. Kept rather than removed so any future
        // re-introduction of step-locked controls (e.g., a long-press
        // accelerator) doesn't churn every call site again.
        _ = step
        return HStack(spacing: AppSpacing.md) {
            Text(label)
                .appFont(.body)
                .fontWeight(.bold)
                .foregroundStyle(Color.greenCalorie)
                .frame(width: 100, alignment: .leading)

            Spacer(minLength: 0)

            GoalNumberField(value: value, range: range, unit: unit)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(Color.bgSurface)
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

// MARK: - Goal number field

/// Numeric text input for daily goals. Replaces the prior `Stepper`
/// affordance — users with goals like "2350" no longer have to tap +/-
/// 47 times.
///
/// Behavior:
///   - `.numberPad` keyboard, no decimal/sign keys.
///   - The buffer is filtered to ASCII digits 0–9 on every change, so
///     a paste of "2,400" or "300g" lands as "2400" / "300".
///   - Out-of-range values are clamped to the row's bounds; the buffer
///     is rewritten so the displayed text always matches the bound Int.
///   - Empty buffer is allowed *while editing* (so the user can clear
///     and retype) but normalizes to the row's lower bound on blur.
///   - "Done" toolbar item dismisses the keyboard from any focused
///     field. Multiple goal rows share the same toolbar slot via
///     SwiftUI's keyboard placement.
private struct GoalNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    @State private var buffer: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $buffer)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(AppFont.font(.kcal))
                .fontWeight(.heavy)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 80, maxWidth: 120, alignment: .trailing)
                .focused($isFocused)
                .onAppear { buffer = String(value) }
                .onChange(of: value) { _, newValue in
                    // Seed-from-profile or external reset — keep buffer
                    // in sync unless the user is mid-typing the same int.
                    if Int(buffer) != newValue {
                        buffer = String(newValue)
                    }
                }
                .onChange(of: buffer) { _, newText in
                    let filtered = newText.filter { ("0"..."9").contains($0) }
                    if filtered != newText {
                        buffer = filtered
                        return
                    }
                    guard !filtered.isEmpty, let parsed = Int(filtered) else {
                        return
                    }
                    let clamped = min(max(parsed, range.lowerBound),
                                      range.upperBound)
                    let normalized = String(clamped)
                    if normalized != filtered {
                        // Either out-of-range or had leading zeros — snap
                        // the displayed text to the canonical form.
                        buffer = normalized
                        return
                    }
                    if clamped != value {
                        value = clamped
                        Haptics.selection()
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        if buffer.isEmpty {
                            value = range.lowerBound
                            buffer = String(value)
                        } else if Int(buffer) != value {
                            buffer = String(value)
                        }
                    }
                }
                // Always-attached keyboard toolbar. The `if isFocused`
                // guard SwiftUI used to support has been flaky across
                // releases — registering unconditionally keeps the
                // close affordance reliably present whenever this
                // field's keyboard is up. The placement is `.keyboard`,
                // so it only renders while a software keyboard is
                // visible anyway.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            isFocused = false
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "keyboard.chevron.compact.down")
                                Text("Close")
                            }
                            .fontWeight(.semibold)
                        }
                        .accessibilityLabel("Close keyboard")
                    }
                }

            if !unit.isEmpty {
                Text(unit)
                    .appFont(.kcal)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.textMeta)
                    .monospacedDigit()
            }
        }
    }
}

#if DEBUG
#Preview("ProfileView — loading") {
    ProfileView()
        .environmentObject(AuthService())
        .environmentObject(ProfileStore())
}
#endif
