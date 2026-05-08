import SwiftUI

/// Web equivalent: `.message-container` (HomePage coach advice).
/// Squared bottom-left corner so the bubble visually originates from the
/// lower-left. Width caps at ~50% of available width and wraps below that.
struct SpeechBubble: View {
    let text: String
    var coachName: String? = nil

    @State private var halfWidth: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: 0) {
                bubble
                    .frame(maxWidth: halfWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .background(
                // GeometryReader as a measurement-only overlay — placed in
                // .background so it doesn't affect layout, just reports
                // the available container width back via PreferenceKey.
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SpeechBubbleWidthKey.self,
                        value: geo.size.width
                    )
                }
            )
            .onPreferenceChange(SpeechBubbleWidthKey.self) { width in
                halfWidth = max(0, width * 0.5)
            }

            if let coachName, !coachName.isEmpty {
                Text("~~ \(coachName) ~~")
                    .appFont(.meta)
                    .italic()
                    .foregroundStyle(Color.textMeta)
            }
        }
    }

    private var bubble: some View {
        Text(text)
            .appFont(.body)
            .foregroundStyle(Color.greenCalorie)
            .multilineTextAlignment(.leading)
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: AppRadius.xl2,
                        bottomLeading: 0,
                        bottomTrailing: AppRadius.xl2,
                        topTrailing: AppRadius.xl2
                    )
                )
                .fill(Color.brand)
            )
    }
}

private struct SpeechBubbleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview("SpeechBubble — variations") {
    VStack(alignment: .leading, spacing: AppSpacing.xl) {
        SpeechBubble(
            text: "E = mc²… and a slice of pizza ≈ 285 kcal.",
            coachName: "Albert Einstein"
        )
        SpeechBubble(
            text: "Hark! This dish containeth more sugar than the Globe Theatre's punch bowl on a Saturday eve. Pace thyself.",
            coachName: "William Shakespeare"
        )
        SpeechBubble(
            text: "No coach this round.",
            coachName: nil
        )
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.brandIvory)
}
