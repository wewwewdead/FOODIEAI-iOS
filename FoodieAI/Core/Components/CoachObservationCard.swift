import SwiftUI

/// Phase 16. Editorial card the active coach posts on Today between
/// meals. Compacter sibling to `EditorialQuote` — same magazine vibe,
/// no opening curly-quote glyph, with a small dismiss affordance at
/// the bottom.
///
/// Surface: bg-surface, radius-lg, shadow-card, hairline border
/// (consistent with `MealCard` and `PatternCard` so the section
/// reads as a peer of the meal list).
///
/// Behavior:
///   - The body of the observation is the only tappable region above
///     the dismiss link. Tapping it is currently a no-op — Phase 17
///     could open a "Coach Notes" history sheet from here. Hooked
///     through `onBodyTap` so the future wiring is one-line.
///   - "Dismiss" calls `onDismiss`, which sets
///     `coach_observations.dismissed_at = now()` server-side via
///     `CoachObservationService.dismiss(_:)` and clears the card
///     locally.
///
/// No appear animation. Per the brief: this is calm content; the
/// transition is whatever the parent VStack supplies.
struct CoachObservationCard: View {
    let observation: CoachObservation
    var onBodyTap: (() -> Void)? = nil
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            CoachBadge(name: observation.coachName)

            Button {
                onBodyTap?()
            } label: {
                Text(observation.body)
                    .appFont(.bodyEmphasis)
                    .italic()
                    .lineSpacing(4)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(observation.coachName) observation: \(observation.body)")

            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.borderHairline)
                    .frame(width: 36, height: 1)
                Button {
                    onDismiss()
                } label: {
                    Text("tap to dismiss")
                        .appFont(.caption)
                        .foregroundStyle(Color.inkLight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss observation")
                Spacer(minLength: 0)
            }
            .padding(.top, AppSpacing.xs)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
#Preview("CoachObservationCard") {
    let sample = CoachObservation(
        id: UUID(),
        userId: UUID(),
        coachName: "Marcus Aurelius",
        body: "Routine is the rhythm of a life lived deliberately. The pizza on Fridays — perhaps that is your ritual. Notice it without judging it.",
        patternKind: "frequent",
        patternSubject: "margherita pizza",
        dismissedAt: nil,
        createdAt: Date()
    )
    return CoachObservationCard(observation: sample, onDismiss: {})
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
}
#endif
