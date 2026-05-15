import SwiftUI

/// User-initiated account deletion. App Store Review Guideline
/// 5.1.1(v) — required for every app that supports sign-in.
///
/// Four stages flowing top-to-bottom:
///   1. warning — list of what gets deleted, "Continue to delete"
///   2. typedConfirmation — type "confirm delete" verbatim to enable
///   3. deleting — step-specific progress messages, no cancel
///   4. failed — friendly error + Try again that retries from start
///
/// On success the auth session is cleared; RootView observes
/// `auth.isSignedIn` flipping to false and routes back to landing
/// automatically (same path as the regular sign-out).
struct DeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = DeleteAccountViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgCanvas.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .interactiveDismissDisabled(vm.stage == .deleting)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.stage {
        case .warning:
            warningView
        case .typedConfirmation:
            typedConfirmationView
        case .deleting:
            deletingView
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Stage 1: warning

    private var warningView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                topBar(showClose: true)

                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(Color.error)
                        .padding(.top, AppSpacing.md)

                    Text("Delete your account?")
                        .appFont(.display1)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    Text("This will permanently remove:")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.inkMute)

                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        bullet("Your profile and goals")
                        bullet("All your saved meals and photos")
                        bullet("Your coach observations")
                        bullet("Your weekly recaps")
                        bullet("Your eating patterns")
                    }

                    Text("This cannot be undone. We can't recover your data after deletion.")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: AppSpacing.md) {
                    DestructiveActionButton(title: "Continue to delete") {
                        Haptics.tap()
                        withAnimation(.appBouncy) {
                            vm.stage = .typedConfirmation
                        }
                    }

                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.inkLight)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, AppSpacing.md)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Circle()
                .fill(Color.error.opacity(0.65))
                .frame(width: 6, height: 6)
                .padding(.top, 8)
            Text(text)
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Stage 2: typed confirmation

    /// Phrase to type. Single space, case-sensitive, no quotes.
    /// Showing it inline (not just in instructions) sidesteps the i18n
    /// case where a user reading translated copy still sees the
    /// literal English phrase they must type — equality is strict.
    private static let confirmationPhrase = "confirm delete"

    private var typedConfirmationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                topBar(showClose: false, showBack: true) {
                    withAnimation(.appBouncy) { vm.stage = .warning }
                }

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("Last step.")
                        .appFont(.display2)
                        .foregroundStyle(Color.textPrimary)

                    Text("Type the phrase below to confirm you want to permanently delete your account.")
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(Self.confirmationPhrase)
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.inkMute)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .fill(Color.bgSurfaceSoft)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(Color.borderHairline, lineWidth: 1)
                        )
                        .textSelection(.disabled)

                    TextField("Type the phrase", text: $vm.typedPhrase)
                        .font(AppFont.font(.bodyEmphasis))
                        .foregroundStyle(Color.textPrimary)
                        .tint(Color.error)
                        .textInputAutocapitalization(TextInputAutocapitalization.never)
                        .autocorrectionDisabled()
                        .padding(AppSpacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .fill(Color.bgSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(
                                    vm.phraseMatches(Self.confirmationPhrase)
                                        ? Color.error
                                        : Color.borderHairline,
                                    lineWidth: 1.5
                                )
                        )
                        .animation(.appPress, value: vm.typedPhrase)
                }

                VStack(spacing: AppSpacing.md) {
                    DestructiveActionButton(
                        title: "Delete my account",
                        isDisabled: !vm.phraseMatches(Self.confirmationPhrase)
                    ) {
                        Haptics.tap()
                        Task { await vm.runDeletion() }
                    }

                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.inkLight)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, AppSpacing.md)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
    }

    // MARK: - Stage 3: deleting

    private var deletingView: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(Color.brand)
            Text("Deleting your account…")
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.textPrimary)
            Text(stepMessage(vm.currentStep))
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .animation(.appPress, value: vm.currentStep)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppSpacing.lg)
    }

    private func stepMessage(_ step: AccountDeletionService.Step?) -> String {
        switch step {
        case .fetchingFiles:   return "Preparing…"
        case .deletingStorage: return "Removing photos…"
        case .deletingAccount: return "Removing your account…"
        case .cleaningLocal:   return "Almost done…"
        case nil:              return "Starting…"
        }
    }

    // MARK: - Stage 4: failed

    private func failedView(message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                topBar(showClose: true)

                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(Color.error.opacity(0.75))
                        .padding(.top, AppSpacing.md)

                    Text("Something went wrong.")
                        .appFont(.display2)
                        .foregroundStyle(Color.textPrimary)

                    Text("We weren't able to delete your account. Your data is still safe.")
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: AppSpacing.md) {
                    DestructiveActionButton(title: "Try again") {
                        Haptics.tap()
                        Task { await vm.runDeletion() }
                    }

                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .appFont(.bodyEmphasis)
                            .foregroundStyle(Color.inkLight)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }

                if !message.isEmpty {
                    Text(message)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AppSpacing.md)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private func topBar(
        showClose: Bool,
        showBack: Bool = false,
        onBack: (() -> Void)? = nil
    ) -> some View {
        HStack {
            if showBack {
                Button {
                    Haptics.tap()
                    onBack?()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.inkMute)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if showClose {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.inkMute)
                        .frame(width: 44, height: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, AppSpacing.sm)
    }
}

// MARK: - View model

@MainActor
final class DeleteAccountViewModel: ObservableObject {
    enum Stage: Equatable {
        case warning
        case typedConfirmation
        case deleting
        case failed(String)
    }

    @Published var stage: Stage = .warning
    @Published var typedPhrase: String = ""
    @Published var currentStep: AccountDeletionService.Step?

    private let service: AccountDeletionService

    init(service: AccountDeletionService? = nil) {
        // Default constructed inside the @MainActor-isolated body so
        // the default-expression isn't evaluated at the call site
        // (which Swift would treat as a non-isolated synchronous
        // context and reject).
        self.service = service ?? AccountDeletionService()
    }

    /// Strict equality — no whitespace trimming, no case folding. The
    /// whole point of the github-style typed-phrase gate is that the
    /// user committed to typing exactly this string.
    func phraseMatches(_ target: String) -> Bool {
        typedPhrase == target
    }

    func runDeletion() async {
        currentStep = nil
        stage = .deleting
        do {
            try await service.deleteCurrentAccount { [weak self] step in
                Task { @MainActor in
                    self?.currentStep = step
                }
            }
            // Success: AuthService will publish session=nil from the
            // signOut() inside the service; RootView observes that and
            // routes back to landing. No further work here.
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Destructive button

/// Full-width red CTA used across the three actionable stages.
/// Kept local to the deletion flow because nothing else in the app
/// uses a destructive-tinted pill (yet); promoting to a shared
/// component is overkill for one screen.
private struct DestructiveActionButton: View {
    let title: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .appFont(.pillTitle)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(
                    Capsule().fill(isDisabled ? Color.error.opacity(0.4) : Color.error)
                )
        }
        .buttonStyle(PressableScaleStyle())
        .disabled(isDisabled)
        .animation(.appPress, value: isDisabled)
    }
}

private struct PressableScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

#if DEBUG
#Preview("Warning") {
    DeleteAccountSheet()
}
#endif
