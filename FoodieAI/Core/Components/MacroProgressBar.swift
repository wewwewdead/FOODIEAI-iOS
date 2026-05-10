import SwiftUI

/// Phase 14: a single macro row on Tracker.
///
/// Visual structure (matches mockup-3-tracker.svg, lines 58–77):
///   Carbs                    142 / 250 g
///   ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░
///
/// Three of these stack on Tracker:
///   - Carbs   tinted `brand`        (#B8CA38)
///   - Sugar   tinted `accentWarm`   (#E27B2C)
///   - Protein tinted `accentCool`   (#5B7F8F)
///
/// On appear the fill bar animates from 0 width to its target under
/// `.motionReveal`. Numbers are tabular.
struct MacroProgressBar: View {
    let label: String
    let value: Double
    let goal: Double
    var unit: String = "g"
    let tint: Color

    @State private var fillProgress: Double = 0

    private var clampedProgress: Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(label)
                    .appFont(.captionStrong)
                    .foregroundStyle(Color.ink)
                Spacer()
                HStack(spacing: 0) {
                    Text.number(value)
                        .appFont(.captionStrong)
                    Text(" / ")
                        .appFont(.captionStrong)
                    Text.number(goal)
                        .appFont(.captionStrong)
                    Text(" \(unit)")
                        .appFont(.captionStrong)
                }
                .foregroundStyle(Color.inkMute)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.borderHairline)
                        .frame(height: 6)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * fillProgress),
                               height: 6)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label) \(Int(value.rounded())) of \(Int(goal.rounded())) \(unit)"
        )
        .onAppear {
            // Phase 14 delight: bar visibly overshoots before settling.
            withAnimation(.appBouncy.delay(0.05)) {
                fillProgress = clampedProgress
            }
        }
        .onChange(of: clampedProgress) { _, new in
            withAnimation(.appBouncy) {
                fillProgress = new
            }
        }
    }
}

#if DEBUG
#Preview("MacroProgressBar — three rows") {
    VStack(spacing: AppSpacing.xl) {
        MacroProgressBar(
            label: "Carbs",   value: 142, goal: 250, tint: .brand
        )
        MacroProgressBar(
            label: "Sugar",   value: 28,  goal: 50,  tint: .accentWarm
        )
        MacroProgressBar(
            label: "Protein", value: 52,  goal: 90,  tint: .accentCool
        )
    }
    .padding(AppSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
