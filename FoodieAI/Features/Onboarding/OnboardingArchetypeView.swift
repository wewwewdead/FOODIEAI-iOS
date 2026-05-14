import SwiftUI

/// Phase 19. Step 2 — single-select goal-framing question.
///
/// Why a single question (not a survey): users hesitate on commitment-
/// style flows. The "you can change this later" subtitle is critical —
/// explicit reversibility lowers the bar to answering. The four options
/// are deliberately non-clinical (`Be more aware` / `Lose some weight`
/// / `Build muscle` / `Just curious`) to avoid prescriptive framings.
///
/// Continue is disabled until a selection exists; "Skip this" advances
/// with `aware` (most generic defaults) so users who can't commit aren't
/// blocked.
struct OnboardingArchetypeView: View {
    @ObservedObject var vm: OnboardingViewModel
    /// Shared CTA namespace from `OnboardingFlow`. Receives the matched
    /// geometry from the hero's "Get started" button so the pill morphs
    /// from its hero-position into the floating Continue stack. Optional
    /// so previews still build.
    var ctaNamespace: Namespace.ID? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    headline
                    options
                    if let confirmation = confirmationCopy {
                        Text(confirmation)
                            .appFont(.caption)
                            .foregroundStyle(Color.brandDeep)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                            .accessibilityLabel(confirmation)
                    }
                    Spacer(minLength: 0)
                }
                .animation(.appReveal, value: vm.archetype)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xl3)
                // Reserve clearance for the floating Continue + Skip stack
                // pinned at the bottom (60pt button + ~36pt skip + spacing
                // + safe-area), otherwise the last option ("Just curious")
                // sits under the CTA on short or wide-aspect screens.
                .padding(.bottom, 160)
            }

            BackChevron(action: { Haptics.tap(); vm.back() })

            VStack(spacing: AppSpacing.sm) {
                PrimaryButton(title: "Continue",
                              isDisabled: vm.archetype == nil) {
                    vm.advance()
                }
                .matchedCTA(OnboardingHeroView.ctaMatchedID, in: ctaNamespace)
                Button {
                    Haptics.tap()
                    vm.skipArchetype()
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
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("What brings you to Foodie?")
                .appFont(.display2)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick whatever feels closest. You can change this later.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One-line confirmation that mirrors the user's selection so the
    /// app feels personal before they leave the step. Nil until a choice
    /// is made; never instructional.
    private var confirmationCopy: String? {
        guard let archetype = vm.archetype else { return nil }
        switch archetype {
        case .aware:
            return "Got it — FoodieAI will help you stay aware of what you eat."
        case .loseWeight:
            return "Got it — we'll tune things to keep your day in balance."
        case .buildMuscle:
            return "Got it — we'll lean into protein and fuel for training."
        case .curious:
            return "Got it — we'll keep things light and curious."
        }
    }

    private var options: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(Profile.Archetype.allCases, id: \.self) { archetype in
                ArchetypeOptionRow(
                    archetype: archetype,
                    isSelected: vm.archetype == archetype
                ) {
                    Haptics.selection()
                    vm.selectArchetype(archetype)
                }
            }
        }
    }
}

private struct ArchetypeOptionRow: View {
    let archetype: Profile.Archetype
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.brand : Color.brandSoft)
                        .frame(width: 40, height: 40)
                    Image(systemName: archetype.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.ink : Color.brandDeep)
                }
                Text(archetype.displayLabel)
                    .appFont(.title2)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.brandDeep)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(isSelected ? Color.brandSoft : Color.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(isSelected ? Color.brand : Color.borderHairline,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(archetype.displayLabel)\(isSelected ? ", selected" : "")")
    }
}

/// Small back-chevron pill used across onboarding steps. Mirrors the
/// SignInView back button styling but lives at the step level so each
/// step view doesn't redefine it.
struct BackChevron: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.bgSurfaceSoft))
        }
        .padding(.top, AppSpacing.md)
        .padding(.leading, AppSpacing.lg)
        .accessibilityLabel("Back")
    }
}

#if DEBUG
#Preview("Archetype") {
    OnboardingArchetypeView(vm: OnboardingViewModel(initialStep: .archetype))
}
#endif
