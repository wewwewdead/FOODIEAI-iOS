import SwiftUI

/// Phase 16. Star/unstar coaches; the rotation skews toward starred
/// names (server-side weighting in `routes/gemini.js`'s `pickCoach`).
///
/// The canonical list of coaches is duplicated here for v1. The server's
/// `deadCelebs` array in `routes/gemini.js` is the source of truth; if
/// you add a coach there, mirror it in `Self.canonicalCoaches`. v2 will
/// move this to a server endpoint so the client doesn't need to be
/// redeployed when the coach pool changes.
struct CoachPreferencesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var viewModel = CoachPreferencesViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                header
                listOfCoaches
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.bgCanvas)
        .navigationTitle("Coaches")
        .navigationBarTitleDisplayMode(.inline)
        // ProfileView's root hides its own navigation bar; re-show it
        // here so the back chevron + "Coaches" title appear on push.
        .toolbar(.visible, for: .navigationBar)
        .task {
            // Seed from the shared profile so a fresh open shows the
            // current persisted preferences without a re-fetch.
            viewModel.seed(from: profileStore.profile?.preferredCoaches ?? [])
        }
        .onChange(of: profileStore.profile?.preferredCoaches ?? []) { _, new in
            viewModel.seed(from: new)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Star the coaches you'd like to hear from more often.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
            if let error = viewModel.lastError {
                Text(error.localizedDescription)
                    .appFont(.caption)
                    .foregroundStyle(Color.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var listOfCoaches: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(Self.canonicalCoaches, id: \.self) { name in
                CoachRow(
                    name: name,
                    isStarred: viewModel.isStarred(name),
                    isSaving: viewModel.savingCoach == name,
                    onToggle: {
                        Task {
                            await viewModel.toggle(name, in: profileStore)
                        }
                    }
                )
            }
        }
    }

    // MARK: - Canonical list (mirrors server `deadCelebs`)

    static let canonicalCoaches: [String] = [
        "Albert Einstein",
        "Cleopatra",
        "Julius Caesar",
        "Shakespeare",
        "Frida Kahlo",
        "Bruce Lee",
        "Leonardo da Vinci",
        "Napoleon Bonaparte",
        "Amelia Earhart",
        "Marie Curie",
    ]
}

// MARK: - Coach row

private struct CoachRow: View {
    let name: String
    let isStarred: Bool
    let isSaving: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            onToggle()
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                // Single-letter avatar circle, mirrors CoachBadge pattern.
                ZStack {
                    Circle()
                        .fill(Color.brandSoft)
                        .frame(width: 36, height: 36)
                    Text(initials(name))
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.brandDeep)
                }

                Text(name)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.brand)
                } else {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isStarred ? Color.brand : Color.inkLight)
                }
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
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel("\(name)\(isStarred ? ", starred" : "")")
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ")
            .compactMap { $0.first.map(Character.init) }
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

// MARK: - View model

/// Owns the local star set, drives optimistic toggling, and writes
/// changes back via `ProfileService.setPreferredCoaches`. The shared
/// `ProfileStore` is updated on success so the rest of the app
/// (CaptureViewModel reading `preferredCoaches` for `/analyze`,
/// MainTabView's onboarding gate) sees the new value immediately.
@MainActor
final class CoachPreferencesViewModel: ObservableObject {
    @Published private(set) var starred: Set<String> = []
    /// Order is preserved for the persisted `preferred_coaches` array;
    /// `starred` is only the lookup set for fast row rendering.
    @Published private(set) var orderedStarred: [String] = []
    @Published private(set) var savingCoach: String? = nil
    @Published private(set) var lastError: Error? = nil

    private let service: ProfileService

    init(service: ProfileService = ProfileService()) {
        self.service = service
    }

    func isStarred(_ name: String) -> Bool {
        starred.contains(name)
    }

    func seed(from coaches: [String]) {
        // Preserve ordering from the persisted array so toggling
        // doesn't reshuffle existing preferences.
        self.orderedStarred = coaches
        self.starred = Set(coaches)
    }

    func toggle(_ name: String, in store: ProfileStore) async {
        guard savingCoach == nil else { return }
        savingCoach = name
        lastError = nil
        defer { savingCoach = nil }

        // Optimistic local toggle — the row's star fills/empties
        // immediately while the network call runs.
        var nextOrdered = orderedStarred
        if starred.contains(name) {
            nextOrdered.removeAll { $0 == name }
            starred.remove(name)
        } else {
            // Append to the end so the user's original first-starred
            // preference stays first (it gets the slightly higher
            // weight in any future ordered-weighting scheme).
            nextOrdered.append(name)
            starred.insert(name)
        }
        orderedStarred = nextOrdered

        do {
            let updated = try await service.setPreferredCoaches(nextOrdered)
            store.apply(updated)
            Haptics.selection()
        } catch {
            // Roll back the optimistic change.
            #if DEBUG
            NSLog("[CoachPrefs] setPreferredCoaches FAILED: %@", "\(error)")
            #endif
            seed(from: store.profile?.preferredCoaches ?? [])
            lastError = error
            Haptics.error()
        }
    }
}

#if DEBUG
#Preview("CoachPreferencesView") {
    NavigationStack {
        CoachPreferencesView()
            .environmentObject(ProfileStore())
    }
}
#endif
