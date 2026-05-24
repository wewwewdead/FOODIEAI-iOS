import SwiftUI

/// Premium-polish wave: custom floating glass tab bar.
///
/// Overlays MainTabView's persistent tab content host. Selection stays
/// bound to the same Int the app already uses, so routing
/// (NotificationRouter, deep-links, programmatic switches) continues to
/// work unchanged.
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
    var onTabTap: ((Int, Int) -> Void)? = nil

    @Namespace private var indicator
    @State private var indicatorSelection: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, spec in
                TabButton(
                    spec: spec,
                    isSelected: selection == index,
                    showsIndicator: indicatorSelection == index,
                    namespace: indicator,
                    reduceMotion: reduceMotion,
                    onTap: {
                        guard selection != index else {
                            // Tap on already-selected tab → soft haptic
                            // only.
                            Haptics.soft()
                            return
                        }
                        onTabTap?(selection, index)
                        Haptics.tap()
                        // CRITICAL perf fix: do NOT wrap this in
                        // `withAnimation`. A withAnimation here would
                        // propagate the spring curve through the
                        // `$selection` binding into the root content
                        // host. The indicator animation is driven by
                        // private `indicatorSelection` state below.
                        selection = index
                    }
                )
            }
        }
        .onAppear {
            indicatorSelection = selection
        }
        .onChange(of: selection) { _, newValue in
            if reduceMotion {
                indicatorSelection = newValue
            } else {
                // Keep the pill motion local to the tab bar. The parent
                // content host sees a plain selection mutation, while
                // this internal state drives the matchedGeometryEffect
                // spring.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    indicatorSelection = newValue
                }
            }
        }
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
        let showsIndicator: Bool
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
                    if showsIndicator {
                        Capsule()
                            .fill(Color.brand)
                            .matchedGeometryEffect(id: "tabIndicator", in: namespace)
                            .shadow(color: Color.brand.opacity(0.42), radius: 10, x: 0, y: 4)
                    }
                    Image(systemName: resolvedSymbol)
                        .font(.system(size: 15, weight: .heavy))
                        .symbolRenderingMode(.hierarchical)
                        .scaleEffect(pressStamp ? 1.18 : 1.0)
                        .foregroundStyle(Color.inkLight)
                        .opacity(isSelected ? 0 : 1)

                    HStack(spacing: 6) {
                        Image(systemName: resolvedSymbol)
                            .font(.system(size: 15, weight: .heavy))
                            .symbolRenderingMode(.hierarchical)
                            .scaleEffect(pressStamp ? 1.18 : 1.0)
                        Text(spec.title)
                            .appFont(.captionStrong)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.brandDeep)
                    .opacity(isSelected ? 1 : 0)
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
