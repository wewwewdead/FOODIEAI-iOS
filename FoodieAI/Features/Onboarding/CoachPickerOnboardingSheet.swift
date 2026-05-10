import SwiftUI

/// Phase 16. One-time bottom sheet shown after the user completes their
/// first save. Lets them star a few coaches up front so the rotation
/// feels intentional rather than random. Skippable; sets a UserDefaults
/// flag so it doesn't re-appear on subsequent launches.
///
/// Why a separate component (instead of reusing `CoachPreferencesView`):
///   - Different layout: a friendly intro paragraph + "Maybe later" /
///     "Done" affordances tuned for first-run UX.
///   - Different persistence trigger: writes happen in batch on Done
///     rather than per-toggle, so we don't churn the Profile row in
///     the middle of an introductory flow.
///   - The shared canonical-coach list lives on `CoachPreferencesView`
///     so we don't duplicate it here.
struct CoachPickerOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var starred: Set<String> = []
    @State private var orderedStarred: [String] = []
    @State private var isSaving: Bool = false
    @State private var lastError: Error? = nil

    /// Caller is notified after the sheet dismisses (whether via Done
    /// or Maybe later). The flag-flip happens in this view; the parent
    /// just gets notified so it can refresh anything observing
    /// preferred_coaches (e.g., trigger an immediate generate).
    var onClosed: () -> Void

    private static let service = ProfileService()

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Pick your coaches")
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                Text("These voices show up in your meals. Star a few to hear from them more often. You can change this any time in Profile → Coaches.")
                    .appFont(.bodyV2)
                    .foregroundStyle(Color.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(CoachPreferencesView.canonicalCoaches, id: \.self) { name in
                        coachPill(name: name)
                    }
                }
            }
            .frame(maxHeight: 360)

            if let error = lastError {
                Text(error.localizedDescription)
                    .appFont(.caption)
                    .foregroundStyle(Color.error)
            }

            HStack(spacing: AppSpacing.md) {
                Button {
                    Haptics.tap()
                    UserDefaults.standard.set(true, forKey: Self.didSeeKey)
                    dismiss()
                    onClosed()
                } label: {
                    Text("Maybe later")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)

                PrimaryButton(
                    title: starred.isEmpty ? "Skip for now" : "Save",
                    isLoading: isSaving
                ) {
                    Task { await save() }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.lg)
        .background(Color.bgCanvas)
        .task {
            // Seed from any pre-existing preferences so this sheet is
            // idempotent if it ever fires twice (it shouldn't, but
            // defensive against userdefault flag corruption).
            let existing = profileStore.profile?.preferredCoaches ?? []
            self.orderedStarred = existing
            self.starred = Set(existing)
        }
    }

    @ViewBuilder
    private func coachPill(name: String) -> some View {
        let isOn = starred.contains(name)
        Button {
            Haptics.selection()
            toggle(name)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(isOn ? Color.brand : Color.brandSoft)
                        .frame(width: 32, height: 32)
                    Text(initials(name))
                        .appFont(.captionStrong)
                        .foregroundStyle(isOn ? Color.bgSurface : Color.brandDeep)
                }
                Text(name)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOn ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isOn ? Color.brand : Color.inkLight)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(isOn ? Color.brand.opacity(0.4) : Color.borderHairline,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ name: String) {
        if starred.contains(name) {
            starred.remove(name)
            orderedStarred.removeAll { $0 == name }
        } else {
            starred.insert(name)
            orderedStarred.append(name)
        }
    }

    private func save() async {
        isSaving = true
        lastError = nil
        defer { isSaving = false }
        do {
            let updated = try await Self.service.setPreferredCoaches(orderedStarred)
            profileStore.apply(updated)
            UserDefaults.standard.set(true, forKey: Self.didSeeKey)
            Haptics.success()
            dismiss()
            onClosed()
        } catch {
            lastError = error
            Haptics.error()
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ")
            .compactMap { $0.first.map(Character.init) }
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
    }

    // MARK: - One-time flag

    /// UserDefaults key. Set to `true` after the user closes the sheet
    /// (Done or Maybe later) so subsequent saves don't re-present.
    static let didSeeKey = "phase16.didSeeCoachPicker"

    /// Returns `true` once the user has seen the coach picker (or
    /// chosen to skip it). Caller (CaptureViewModel save success path)
    /// uses this as the gate.
    static var didSee: Bool {
        UserDefaults.standard.bool(forKey: didSeeKey)
    }

    /// Test/debug hook — Phase 16 verification mentions wanting to
    /// re-trigger the sheet on a fresh-feeling account without
    /// signing out. Prefixed `debug_` to flag it.
    static func debug_resetDidSee() {
        UserDefaults.standard.removeObject(forKey: didSeeKey)
    }
}

#if DEBUG
#Preview("CoachPickerOnboardingSheet") {
    Color.bgSurfaceSoft
        .sheet(isPresented: .constant(true)) {
            CoachPickerOnboardingSheet(onClosed: {})
                .environmentObject(ProfileStore())
                .presentationDetents([.large])
        }
}
#endif
