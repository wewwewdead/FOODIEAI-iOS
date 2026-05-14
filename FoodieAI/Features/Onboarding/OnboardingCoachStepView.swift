import SwiftUI

/// Phase 19. Step 3 — pick a few coaches whose voice the user wants to
/// hear more often.
///
/// Differs from the existing `CoachPreferencesView`:
///   - In-line voice samples (one-liner per coach) so users can pick by
///     voice rather than name recognition.
///   - Selection is purely client-side — `OnboardingViewModel.complete()`
///     batches the write into the same UPDATE that stamps the gate.
///   - Continue is enabled with zero stars (random rotation is a valid
///     answer); "Skip this" leaves coaches empty and advances.
struct OnboardingCoachStepView: View {
    @ObservedObject var vm: OnboardingViewModel
    /// Shared CTA namespace from `OnboardingFlow` so the primary pill
    /// morphs in/out of this step alongside the rest of onboarding.
    var ctaNamespace: Namespace.ID? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headline
                    coachList
                    if let confirmation = coachConfirmationCopy {
                        Text(confirmation)
                            .appFont(.caption)
                            .foregroundStyle(Color.brandDeep)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                            .accessibilityLabel(confirmation)
                    }
                    Color.clear.frame(height: 140) // scroll past sticky CTA
                }
                .animation(.appReveal, value: vm.orderedCoaches)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                .padding(.bottom, AppSpacing.lg)
            }

            BackChevron(action: { Haptics.tap(); vm.back() })

            VStack(spacing: AppSpacing.sm) {
                PrimaryButton(title: vm.preferredCoaches.isEmpty
                              ? "Continue without picking"
                              : "Continue (\(vm.preferredCoaches.count) starred)") {
                    vm.advance()
                }
                .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
                Button {
                    Haptics.tap()
                    vm.advance()
                } label: {
                    Text("Skip this")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)
                        .underline()
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(
                LinearGradient(colors: [Color.bgCanvas.opacity(0),
                                        Color.bgCanvas.opacity(0.95),
                                        Color.bgCanvas],
                               startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            )
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Who'd you like coaching you?")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a few. The starred ones show up more often.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Single-line confirmation that names the user's first-starred
    /// coach so the choice carries forward into the app. Falls back to
    /// a gentle reassurance when no coach is starred so users who
    /// continue without picking don't feel they've made a wrong move.
    private var coachConfirmationCopy: String? {
        // Try the first-starred (ordered) coach, then any starred name
        // as a fallback. Both go through a non-empty-trim guard so we
        // can never render "<empty> will check in on you the most."
        let topRaw: String? = vm.orderedCoaches.first
            ?? vm.preferredCoaches.first
        guard let raw = topRaw else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Defensive: a corrupt/empty name string is treated as the
            // "no starred coaches" case rather than rendering an
            // ungrammatical line.
            return "Your coaches will check in on you the most."
        }

        // First word — for canonical names like "Albert Einstein" this
        // produces "Albert"; for single-word names ("Cleopatra") it
        // falls back to the whole name.
        let firstName = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return "\(firstName) will check in on you the most."
    }

    private var coachList: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(CoachPreferencesView.canonicalCoaches, id: \.self) { name in
                OnboardingCoachRow(
                    name: name,
                    voiceSample: Self.voiceSample(for: name),
                    isStarred: vm.preferredCoaches.contains(name),
                    onToggle: {
                        Haptics.selection()
                        vm.toggleCoach(name)
                    }
                )
            }
        }
    }

    /// Voice samples mapped to the canonical coach list. Hardcoded
    /// here for v1; future phase moves to a server-driven catalogue.
    /// Mirrors the personalities the server's coach generator uses,
    /// but framed as a one-liner pitch the user reads on the row.
    static func voiceSample(for name: String) -> String {
        switch name {
        case "Albert Einstein":     "E = mc²… and a slice of pizza ≈ 285 kcal."
        case "Cleopatra":           "I shall not be removed from this rotation."
        case "Julius Caesar":       "Veni, vidi, edi."
        case "Shakespeare":         "To eat, or not to eat — what was the question?"
        case "Frida Kahlo":         "I paint what I eat. Mostly fruit."
        case "Bruce Lee":           "Be water. Be also slightly less sodium."
        case "Leonardo da Vinci":   "Simplicity is sophistication. Also, fiber."
        case "Napoleon Bonaparte":  "An army marches on its stomach. Yours could use protein."
        case "Amelia Earhart":      "Adventure begins with breakfast."
        case "Marie Curie":         "We must have perseverance — and kale."
        default:                    ""
        }
    }
}

private struct OnboardingCoachRow: View {
    let name: String
    let voiceSample: String
    let isStarred: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(isStarred ? Color.brand : Color.brandSoft)
                        .frame(width: 40, height: 40)
                    Text(initials(name))
                        .appFont(.captionStrong)
                        .foregroundStyle(isStarred ? Color.ink : Color.brandDeep)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .appFont(.title2)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if !voiceSample.isEmpty {
                        Text(voiceSample)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isStarred ? "star.fill" : "star")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isStarred ? Color.brand : Color.inkLight)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(isStarred ? Color.brand.opacity(0.5) : Color.borderHairline,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

#if DEBUG
#Preview("Coaches") {
    OnboardingCoachStepView(vm: OnboardingViewModel(initialStep: .coaches))
}
#endif
