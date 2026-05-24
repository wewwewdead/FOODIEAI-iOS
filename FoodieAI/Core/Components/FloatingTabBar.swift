import SwiftUI

/// Premium-polish wave: custom floating glass tab bar.
///
/// Overlays a hidden system `TabView` (we keep TabView for its lifecycle,
/// state restoration, and tap-to-pop-to-root behavior — but hide the
/// system chrome and present this floating capsule on top). Selection
/// stays bound to the same Int the existing `MainTabView` already uses,
/// so all routing (NotificationRouter, deep-links, programmatic switches)
/// continues to work unchanged.
///
/// Design:
///   - 64pt capsule that floats 16pt above the bottom safe area
///   - Liquid Glass background (iOS 26) / ultraThinMaterial (iOS 17–25)
///   - 4 tab buttons, brand-tinted active state
///   - A morphing brand pill that slides between tabs via
///     `matchedGeometryEffect` — the visual signature of the bar
///   - Scale-stamp on tap, soft haptic, brand spring
///   - Auto-hides behind a subtle bottom fade so content scrolling under
///     it dissolves smoothly
struct FloatingTabBar: View {
    @Binding var selection: Int
    let tabs: [TabSpec]

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, spec in
                TabButton(
                    spec: spec,
                    isSelected: selection == index,
                    namespace: indicator,
                    reduceMotion: reduceMotion,
                    onTap: {
                        guard selection != index else {
                            // Tap on already-selected tab → soft haptic
                            // only (the system "pop to root" behavior is
                            // owned by the underlying TabView).
                            Haptics.soft()
                            return
                        }
                        Haptics.tap()
                        // CRITICAL perf fix: do NOT wrap this in
                        // `withAnimation`. A withAnimation here would
                        // propagate the spring curve through the
                        // `$selection` binding into TabView's content
                        // swap, causing the entire destination tab's
                        // body to ride the spring (sticky transition).
                        // The matchedGeometryEffect on the indicator
                        // capsule gets its animation from the
                        // `.animation(.spring..., value: selection)`
                        // applied to this HStack below — scoped to
                        // just the indicator, never to tab content.
                        selection = index
                    }
                )
            }
        }
        // Scopes the spring to the HStack only — the matchedGeometryEffect
        // indicator capsule animates, but the parent TabView's tab swap
        // happens instantly (no spring propagation through the binding).
        .animation(
            reduceMotion ? .appReduced : .spring(response: 0.42, dampingFraction: 0.78),
            value: selection
        )
        .padding(6)
        .liquidGlass(in: Capsule(), tint: .brand, strokeOpacity: 0.22)
        // One combined shadow instead of two — each .shadow() forces
        // an additional render pass, so collapsing them is a free
        // perf win without changing the look meaningfully.
        .shadow(color: Color.brand.opacity(0.20), radius: 20, x: 0, y: 10)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, 8)
        // Composites the whole bar into a single layer so the per-
        // frame work during scroll-under is a single texture blit
        // instead of re-rasterizing the capsule + shadow stack.
        .compositingGroup()
        .accessibilityElement(children: .contain)
    }

    struct TabSpec {
        let title: String
        let systemImage: String
        let selectedSystemImage: String?

        init(title: String, systemImage: String, selectedSystemImage: String? = nil) {
            self.title = title
            self.systemImage = systemImage
            self.selectedSystemImage = selectedSystemImage
        }
    }

    private struct TabButton: View {
        let spec: TabSpec
        let isSelected: Bool
        let namespace: Namespace.ID
        let reduceMotion: Bool
        let onTap: () -> Void

        @State private var pressStamp: Bool = false

        var body: some View {
            Button(action: {
                if !reduceMotion {
                    pressStamp = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                        pressStamp = false
                    }
                }
                onTap()
            }) {
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.brand)
                            .matchedGeometryEffect(id: "tabIndicator", in: namespace)
                            .shadow(color: Color.brand.opacity(0.42), radius: 10, x: 0, y: 4)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: resolvedSymbol)
                            .font(.system(size: 15, weight: .heavy))
                            .symbolRenderingMode(.hierarchical)
                            .scaleEffect(pressStamp ? 1.18 : 1.0)
                        if isSelected {
                            Text(spec.title)
                                .appFont(.captionStrong)
                                .lineLimit(1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .foregroundStyle(isSelected ? Color.brandDeep : Color.inkLight)
                    .padding(.horizontal, isSelected ? 16 : 12)
                    .padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spec.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        private var resolvedSymbol: String {
            if isSelected, let sel = spec.selectedSystemImage { return sel }
            return spec.systemImage
        }
    }
}

/// Total vertical footprint reserved at the bottom of every tab's
/// content area for the FloatingTabBar overlay. Includes the bar's
/// capsule height (~56pt), its bottom padding (8pt), and a small
/// breathing gap (8pt) so content stops above the bar instead of
/// touching it. The home indicator margin is added on top of this
/// by SwiftUI automatically (safeAreaInset stacks on the existing
/// bottom safe area).
///
/// Must stay in sync with FloatingTabBar's intrinsic frame.
let FloatingTabBarFootprint: CGFloat = 72

/// Hides the system tab bar AND reserves space at the bottom of the
/// tab's content for the floating tab bar that lives in the MainTabView
/// overlay layer. Both concerns travel together so every tab gets
/// consistent treatment with one modifier.
struct HiddenSystemTabBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Color.clear of the bar's footprint height. Pinned
                // CTAs (e.g. CaptureView's "Take a photo" pill) and
                // scroll content both end above this inset, so the
                // floating bar in the overlay layer never covers
                // tappable surfaces.
                Color.clear.frame(height: FloatingTabBarFootprint)
            }
    }
}

extension View {
    func hideSystemTabBar() -> some View { modifier(HiddenSystemTabBar()) }
}

#if DEBUG
private struct FloatingTabBarPreview: View {
    @State private var sel: Int = 0
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.bgCanvas.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Tab \(sel)")
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                Spacer()
            }
            .padding()
            FloatingTabBar(
                selection: $sel,
                tabs: [
                    .init(title: "Home", systemImage: "camera", selectedSystemImage: "camera.fill"),
                    .init(title: "Tracker", systemImage: "list.bullet.rectangle"),
                    .init(title: "Mirror", systemImage: "sparkles"),
                    .init(title: "Profile", systemImage: "person.crop.circle")
                ]
            )
        }
    }
}

#Preview { FloatingTabBarPreview() }
#endif
