import SwiftUI

// MARK: - FoodOSMomentFeedbackView
//
// Small row of feedback chips that sits at the bottom of the FoodOS
// Moment card. Three calm surfaces: Helpful / Not useful / (for
// nudge & experiment moments) I'll try this. Tapping one records a
// local feedback event and swaps the row for a brief confirmation
// chip — no alerts, no toasts, no server calls.
//
// Pure presentational view: the parent owns the store and the
// confirmation state, so animations stay scoped to the card.

struct FoodOSMomentFeedbackView: View {
    let moment: FoodOSMoment
    /// `nil` while the user hasn't tapped yet for this moment; set
    /// to the chosen feedback after a tap so the row can render its
    /// confirmation state.
    let recordedFeedback: FoodOSMomentFeedback?
    let onTap: (FoodOSMomentFeedback) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let _ = recordedFeedback {
                confirmation
                    .transition(.opacity)
            } else {
                chipRow
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? .none : .easeInOut(duration: 0.18),
            value: recordedFeedback
        )
        .padding(.top, AppSpacing.sm)
    }

    private var chipRow: some View {
        HStack(spacing: AppSpacing.xs) {
            FeedbackChip(
                title: "Helpful",
                systemImage: "hand.thumbsup",
                onTap: { onTap(.helpful) }
            )
            FeedbackChip(
                title: "Not useful",
                systemImage: "hand.thumbsdown",
                onTap: { onTap(.notUseful) }
            )
            if FoodOSMomentFeedbackPolicy.showsWillTry(for: moment) {
                FeedbackChip(
                    title: "I'll try this",
                    systemImage: "sparkles",
                    onTap: { onTap(.willTry) }
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// Calm in-card confirmation. Replaces the chip row in place so
    /// the card doesn't grow or shift. V2 varies copy by feedback so
    /// "I'll try this" tells the user FoodOS will check in after the
    /// next mood note (the active-experiment loop).
    private var confirmation: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandDeep)
            Text(confirmationCopy)
                .appFont(.caption)
                .foregroundStyle(Color.brandDeep)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var confirmationCopy: String {
        switch recordedFeedback {
        case .willTry:
            return "Got it — FoodOS will check in after your next mood note."
        case .notUseful:
            return "Got it — I'll show fewer moments like this."
        case .helpful, .none:
            return "Got it — FoodOS will learn from this."
        }
    }
}

/// Single pill-shaped feedback chip. Kept private to the feedback
/// view so its visual tuning (size, padding, fill colour) doesn't
/// drift onto unrelated chips elsewhere in the app.
private struct FeedbackChip: View {
    let title: String
    let systemImage: String
    let onTap: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .appFont(.captionStrong)
            }
            .foregroundStyle(Color.brandDeep)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.brandSoft)
            )
            .overlay(
                Capsule().strokeBorder(
                    Color.brand.opacity(0.35),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
    }
}
