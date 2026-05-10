import Foundation
import Combine

/// Drives the Profile tab. Loads the signed-in user's profile, exposes
/// editable drafts for display name and three daily goals, and writes
/// changes back via `ProfileService.updateProfile`.
///
/// `hasUnsavedChanges` is recomputed reactively whenever any of the four
/// drafts change OR a fresh `.loaded` profile lands; the `Save changes`
/// button observes it directly.
@MainActor
final class ProfileViewModel: ObservableObject {
    enum State {
        case loading
        case loaded(Profile)
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    @Published var displayNameDraft: String = ""
    @Published var calorieGoalDraft: Int = 2000
    @Published var carbGoalDraft:    Int = 250
    @Published var sugarGoalDraft:   Int = 50
    @Published var proteinGoalDraft: Int = 90
    @Published var fatGoalDraft:     Int = 70
    @Published var fiberGoalDraft:   Int = 28

    @Published private(set) var isSaving: Bool = false
    @Published private(set) var saveError: Error?
    @Published private(set) var hasUnsavedChanges: Bool = false

    /// Last profile we successfully loaded or saved. ProfileView observes
    /// this and forwards into the shared `ProfileStore` so other
    /// screens (Tracker) re-render with the new daily goals on save.
    @Published private(set) var lastResolvedProfile: Profile?

    private let profileService: ProfileService
    private let auth: AuthService
    private var cancellables = Set<AnyCancellable>()

    init(profileService: ProfileService = ProfileService(),
         auth: AuthService) {
        self.profileService = profileService
        self.auth = auth
        bindUnsavedChangeTracking()
    }

    // MARK: - Public API

    func load() async {
        state = .loading
        saveError = nil
        do {
            let profile = try await profileService.currentProfile()
            seed(from: profile)
            state = .loaded(profile)
            lastResolvedProfile = profile
        } catch {
            state = .failed(error)
        }
    }

    func save() async {
        guard case .loaded = state else { return }
        guard !isSaving else { return }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            let updated = try await profileService.updateProfile(
                displayName:       displayNameDraft,
                dailyCalorieGoal:  calorieGoalDraft,
                dailyCarbGoalG:    carbGoalDraft,
                dailySugarGoalG:   sugarGoalDraft,
                dailyProteinGoalG: proteinGoalDraft,
                dailyFatGoalG:     fatGoalDraft,
                dailyFiberGoalG:   fiberGoalDraft
            )
            seed(from: updated)
            state = .loaded(updated)
            lastResolvedProfile = updated
            Haptics.success()
        } catch {
            saveError = error
            Haptics.error()
        }
    }

    func signOut() async {
        do {
            try await auth.signOut()
        } catch {
            saveError = error
        }
    }

    // MARK: - Wiring

    /// Pre-populate the four drafts from a freshly-loaded or freshly-saved
    /// profile, then snap `hasUnsavedChanges` to false. Setting drafts
    /// triggers `bindUnsavedChangeTracking`'s combine pipeline, which
    /// recomputes against the new baseline (the just-loaded profile).
    private func seed(from profile: Profile) {
        displayNameDraft = profile.displayName ?? ""
        calorieGoalDraft = profile.dailyCalorieGoal
        carbGoalDraft    = profile.dailyCarbGoalG
        sugarGoalDraft   = profile.dailySugarGoalG
        proteinGoalDraft = profile.dailyProteinGoalG
        fatGoalDraft     = profile.dailyFatGoalG
        fiberGoalDraft   = profile.dailyFiberGoalG
        hasUnsavedChanges = false
    }

    /// Observe the four draft properties + the loaded state; emit
    /// `hasUnsavedChanges = true` whenever any draft diverges from the
    /// currently-loaded baseline.
    private func bindUnsavedChangeTracking() {
        // Combine caps native combineLatest at 4 publishers; we have 7
        // drafts now. Compose them into nested tuples — the consumer
        // unpacks into named locals so the diff stays readable.
        let nameAndCal       = Publishers.CombineLatest($displayNameDraft, $calorieGoalDraft)
        let carbAndSugar     = Publishers.CombineLatest($carbGoalDraft, $sugarGoalDraft)
        let proteinFatFiber  = Publishers.CombineLatest3($proteinGoalDraft, $fatGoalDraft, $fiberGoalDraft)
        let allDrafts        = Publishers.CombineLatest3(nameAndCal, carbAndSugar, proteinFatFiber)

        Publishers.CombineLatest(allDrafts, $state)
            .map { combined, state -> Bool in
                guard case .loaded(let profile) = state else { return false }
                let ((name, cal), (carb, sugar), (protein, fat, fiber)) = combined
                return name    != (profile.displayName ?? "")
                    || cal     != profile.dailyCalorieGoal
                    || carb    != profile.dailyCarbGoalG
                    || sugar   != profile.dailySugarGoalG
                    || protein != profile.dailyProteinGoalG
                    || fat     != profile.dailyFatGoalG
                    || fiber   != profile.dailyFiberGoalG
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: \.hasUnsavedChanges, on: self)
            .store(in: &cancellables)
    }
}
