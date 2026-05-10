import SwiftUI

/// Phase 14: custom replacement for `Picker(.segmented)` matching the
/// redesign mockup (mockup-3-tracker.svg lines 33–40).
///
/// 40pt tall. `bg-surface-soft` track at 55% opacity (so the warm canvas
/// behind it shows through subtly), white thumb with `shadow-floating`.
/// Three equal-width segments. Tap fires `Haptics.selection()` and
/// animates the thumb under `.motionQuick`.
///
/// Type-erased over a generic `Segment: Hashable & Identifiable & CaseIterable`
/// so it works for `TrackerSegment` (today/week/month) and any future
/// three-segment switcher.
///
/// Naming: `AppSegmentedControl` rather than `SegmentedControl` to avoid
/// any possibility of collision with a future SwiftUI / UIKit type.
struct AppSegmentedControl<Segment>: View
where Segment: Hashable, Segment: Identifiable, Segment: CaseIterable,
      Segment.AllCases.Index == Int {

    @Binding var selection: Segment
    let titleProvider: (Segment) -> String

    var body: some View {
        GeometryReader { geo in
            let segments = Array(Segment.allCases)
            let count = max(segments.count, 1)
            let trackInset: CGFloat = 3
            let thumbWidth = (geo.size.width - trackInset * 2) / CGFloat(count)
            let selectedIdx = segments.firstIndex(of: selection) ?? 0

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.bgSurfaceSoft.opacity(0.55))

                // Thumb — slides via offset animation under motionQuick.
                Capsule()
                    .fill(Color.bgSurface)
                    .appShadow(.shadowFloating)
                    .frame(width: thumbWidth - 0, height: geo.size.height - trackInset * 2)
                    .padding(trackInset)
                    .offset(x: thumbWidth * CGFloat(selectedIdx))

                // Labels — render last so they sit above both track and thumb.
                HStack(spacing: 0) {
                    ForEach(segments, id: \.self) { segment in
                        Button {
                            guard segment != selection else { return }
                            Haptics.selection()
                            withAnimation(.motionQuick) {
                                selection = segment
                            }
                        } label: {
                            Text(titleProvider(segment))
                                .appFont(.captionStrong)
                                .foregroundStyle(
                                    segment == selection
                                        ? Color.ink
                                        : Color.inkLight
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
private enum DemoSegment: String, CaseIterable, Identifiable {
    case today = "Today", week = "Week", month = "Month"
    var id: String { rawValue }
}

private struct AppSegmentedControlDemo: View {
    @State private var segment: DemoSegment = .today
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            AppSegmentedControl<DemoSegment>(
                selection: $segment,
                titleProvider: { $0.rawValue }
            )
            Text("Selected: \(segment.rawValue)")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
    }
}

#Preview("AppSegmentedControl") {
    AppSegmentedControlDemo()
}
#endif
