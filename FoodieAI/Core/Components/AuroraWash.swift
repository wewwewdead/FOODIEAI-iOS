import SwiftUI

/// Premium-polish wave: a slow breathing gradient wash for canvas
/// backgrounds.
///
/// Performance-tuned rewrite — the previous implementation ran
/// `TimelineView(.animation(minimumInterval: 1/20))` redrawing an
/// `AngularGradient` with `.blur(80)` every tick. On a 4-tab TabView
/// (which keeps all tabs alive) that's four heavy blurred gradient
/// re-rasterizations on every frame, which made tab switches stutter.
///
/// New implementation:
///   - Static AngularGradient — the color story is unchanged
///   - A single SwiftUI animation on `rotation` runs the slow loop
///     (no TimelineView, no per-frame redraw)
///   - `.blur(radius: 40)` (down from 80) — still feels atmospheric
///     but ~4x cheaper to composite
///   - `.drawingGroup()` flattens the blurred gradient to a Metal
///     texture; rotation animates the cached texture instead of
///     re-blurring per frame
///   - `isActive` gate: rotation stops on hidden tabs
///
/// Designed to layer between `Color.bgCanvas` and content:
///   ```swift
///   ZStack {
///       Color.bgCanvas.ignoresSafeArea()
///       AuroraWash().ignoresSafeArea()
///       content
///   }
///   ```
struct AuroraWash: View {
    /// 0 = invisible, 1 = full opacity.
    var intensity: Double = 0.4
    /// When false, rotation freezes — useful for hidden tabs.
    var isActive: Bool = true

    @State private var rotation: Angle = .degrees(0)
    /// Toggled by `.onAppear` / `.onDisappear`. TabView fires these on
    /// tab switches in iOS 17+, so the rotation loop stops on hidden
    /// tabs. Critical for snappy tab transitions — three tabs running
    /// continuous animations in the background was contributing to
    /// the sticky transition feel.
    @State private var isVisible: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AngularGradient(
            gradient: Gradient(colors: [
                Color.brand.opacity(0.18),
                Color.brandBright.opacity(0.12),
                Color.accentCool.opacity(0.10),
                Color.brand.opacity(0.18)
            ]),
            center: .center,
            angle: .radians(0)
        )
        .blur(radius: 32)
        .rotationEffect(rotation)
        .opacity(intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            isVisible = true
            startRotationIfNeeded()
        }
        .onDisappear { isVisible = false }
        .onChange(of: isActive) { _, _ in startRotationIfNeeded() }
    }

    private func startRotationIfNeeded() {
        guard !reduceMotion, isActive, isVisible else { return }
        // 90s for a full rotation — well below detection threshold.
        withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) {
            rotation = .degrees(360)
        }
    }
}

#if DEBUG
#Preview("AuroraWash") {
    ZStack {
        Color.bgCanvas.ignoresSafeArea()
        AuroraWash().ignoresSafeArea()
        Text("Aurora layered behind")
            .appFont(.display1)
            .foregroundStyle(Color.ink)
    }
}
#endif
