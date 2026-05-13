import SwiftUI

/// Phase 13: shimmer placeholder used in loading states. Lives where the
/// real content will eventually appear, with the same shape and rough
/// dimensions, so the screen doesn't reflow when data arrives.
///
/// The shimmer is intentionally subtle — this is a loading state, not
/// entertainment. White-at-60% gradient over `brandIvory`, traveling
/// left-to-right at 1.4 s per cycle, looping forever.
struct SkeletonShape: View {
    var cornerRadius: CGFloat = AppRadius.md

    @State private var travel: CGFloat = -1
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.brandIvory)
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.6),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width)
                .offset(x: travel * width)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        // Capture the placeholder's width once, then drive the
                        // shimmer travel as a fraction of that width — the
                        // gradient slides from -width to +width, never visible
                        // outside the rect.
                        width = geo.size.width
                        // Reduce Motion: leave the shimmer parked. The
                        // base color already reads as a placeholder; the
                        // moving sheen is purely decorative.
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            travel = 1
                        }
                    }
                }
            )
    }
}

/// Skeleton mimicking a `MealRow` collapsed shape — 80×80 thumbnail block
/// + two text bars to its right. Matches the real row's geometry so
/// switching from skeleton to data causes minimal layout shift.
struct MealRowSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            SkeletonShape()
                .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                SkeletonShape(cornerRadius: 4)
                    .frame(height: 18)
                    .frame(maxWidth: 200, alignment: .leading)
                SkeletonShape(cornerRadius: 4)
                    .frame(height: 12)
                    .frame(maxWidth: 280, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.brandIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.panelBorder, lineWidth: 2)
        )
    }
}

/// Skeleton mimicking the month calendar grid — 35 squares (5 rows × 7
/// columns is enough to cover any typical month including its padding).
struct MonthGridSkeleton: View {
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: AppSpacing.xs),
        count: 7
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppSpacing.xs) {
            ForEach(0..<35, id: \.self) { _ in
                SkeletonShape()
                    .frame(height: 48)
            }
        }
    }
}

#if DEBUG
#Preview("SkeletonShape") {
    VStack(spacing: AppSpacing.lg) {
        MealRowSkeleton()
        MealRowSkeleton()
        MonthGridSkeleton()
    }
    .padding(AppSpacing.lg)
    .background(Color.brandCream)
}
#endif
