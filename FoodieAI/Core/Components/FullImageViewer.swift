import SwiftUI
import UIKit

/// Full-screen viewer for a meal's main (1024px) image. Phase 12 addendum.
///
/// Presented via `.fullScreenCover` rather than `.sheet`: a sheet has a
/// visible card edge that fights against an immersive image view, and
/// the sheet's drag-to-dismiss interferes with the pinch-to-zoom gesture.
///
/// Pinch-to-zoom and pan are delegated to a `UIScrollView` (via
/// `ZoomableImageView` below) — the UIKit gesture composition is more
/// robust than stitching SwiftUI `MagnificationGesture` + `DragGesture`
/// together.
///
/// When initialized with a `FoodLog`, a bottom detail panel slides up
/// after the image is visible and each detail row reveals with a small
/// stagger. The panel is draggable: pulling up snaps it to an expanded
/// state that surfaces coach advice and category lists; pulling down
/// snaps back to compact. Reduce Motion collapses the choreography to
/// a single opacity fade and skips the slide / stagger entirely.
struct FullImageViewer: View {
    let imagePath: String
    let log: FoodLog?

    init(imagePath: String) {
        self.imagePath = imagePath
        self.log = nil
    }

    init(log: FoodLog) {
        self.imagePath = log.imagePath ?? log.imageThumbPath ?? ""
        self.log = log
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?
    @State private var loadError: Bool = false

    // Staggered reveal state.
    @State private var panelVisible = false
    @State private var visibleDetailCount = 0
    @State private var revealTask: Task<Void, Never>?

    // Drag-to-expand state.
    @State private var panelExpanded = false

    private static let imageService = FoodImageService()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            content

            // Tap-catcher: only present when the panel is expanded. Sits
            // above the image (intercepting its tap-to-zoom) and below
            // the panel itself, so a tap anywhere outside the panel
            // collapses it instead of dismissing the viewer. In compact
            // mode this disappears and the original behaviors (image
            // pinch/zoom, background tap-to-dismiss) come back.
            if panelExpanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapsePanel() }
                    .transition(.opacity)
            }

            VStack {
                HStack {
                    closeButton
                    Spacer()
                }
                Spacer()
            }
            .padding(AppSpacing.md)

            if let log {
                VStack {
                    Spacer()
                    DetailPanel(
                        log: log,
                        visibleCount: visibleDetailCount,
                        reduceMotion: reduceMotion,
                        expanded: $panelExpanded
                    )
                    .opacity(panelVisible ? 1 : 0)
                    .offset(y: panelVisible ? 0 : (reduceMotion ? 0 : 80))
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(panelVisible)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await load()
        }
        .onAppear {
            startRevealIfNeeded()
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            ZoomableImageView(image: image)
                .ignoresSafeArea()
                .accessibilityLabel(Text(imageAccessibilityLabel))
        } else if loadError {
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Couldn't load image")
                    .appFont(.body)
                    .fontWeight(.heavy)
                    .foregroundStyle(.white)
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var imageAccessibilityLabel: String {
        if let name = log?.foodName, !name.isEmpty {
            return "Full image of \(name)"
        }
        return "Full meal image"
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 32, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close image viewer")
    }

    /// Same snap curve `DetailPanel` uses for drag releases — keeps the
    /// programmatic collapse visually consistent with the gesture.
    private static let collapseAnimation: Animation =
        .spring(response: 0.34, dampingFraction: 0.86)

    private func collapsePanel() {
        guard panelExpanded else { return }
        if reduceMotion {
            panelExpanded = false
        } else {
            withAnimation(Self.collapseAnimation) {
                panelExpanded = false
            }
        }
        Haptics.selection()
    }

    private func startRevealIfNeeded() {
        guard let log, revealTask == nil else { return }
        let rows = DetailPanel.rowCount(for: log)

        if reduceMotion {
            withAnimation(.appReduced) {
                panelVisible = true
                visibleDetailCount = rows
            }
            return
        }

        revealTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.motionReveal) {
                    panelVisible = true
                }

                try await Task.sleep(nanoseconds: 180_000_000)

                for _ in 0..<rows {
                    guard !Task.isCancelled else { return }
                    withAnimation(.appEntrance) {
                        visibleDetailCount += 1
                    }
                    try await Task.sleep(nanoseconds: 55_000_000)
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func load() async {
        guard image == nil, !loadError else { return }
        guard !imagePath.isEmpty else {
            loadError = true
            return
        }
        do {
            let url = try await Self.imageService.cachedSignedURL(for: imagePath)
            guard !Task.isCancelled else { return }
            #if DEBUG
            NSLog("[FullImageViewer] loading %@", imagePath)
            #endif
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            guard let img = UIImage(data: data) else {
                guard !Task.isCancelled else { return }
                await MainActor.run { loadError = true }
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self.image = img }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            #if DEBUG
            NSLog("[FullImageViewer] load FAILED %@: %@", imagePath, "\(error)")
            #endif
            guard !Task.isCancelled else { return }
            await MainActor.run { loadError = true }
        }
    }
}

// MARK: - Detail panel

/// Bottom-anchored translucent panel showing the saved log's food name,
/// calories, and macros. Two snap states: compact (header + macros) and
/// expanded (adds coach advice + nutrients/benefits/drawbacks if present).
/// Drag the handle at the top to switch states.
private struct DetailPanel: View {
    let log: FoodLog
    let visibleCount: Int
    let reduceMotion: Bool
    @Binding var expanded: Bool

    @State private var dragTranslation: CGFloat = 0

    /// Fixed compact height. Locked rather than intrinsic so the frame
    /// height is a smoothly-animatable CGFloat — intrinsic sizing would
    /// force a layout-tree rebuild on every state change and break the
    /// continuous expand/collapse animation.
    private let compactHeight: CGFloat = 252

    private var rows: [MacroRow] {
        var out: [MacroRow] = [
            MacroRow(label: "Carbs", value: log.carbsG, unit: "g"),
            MacroRow(label: "Sugar", value: log.sugarG, unit: "g"),
        ]
        if let p = log.proteinG { out.append(MacroRow(label: "Protein", value: p, unit: "g")) }
        if let f = log.fatG     { out.append(MacroRow(label: "Fat",     value: f, unit: "g")) }
        if let fi = log.fiberG  { out.append(MacroRow(label: "Fiber",   value: fi, unit: "g")) }
        return out
    }

    static func rowCount(for log: FoodLog) -> Int {
        var count = 2 // name + calories
        count += 2    // carbs + sugar
        if log.proteinG != nil { count += 1 }
        if log.fatG     != nil { count += 1 }
        if log.fiberG   != nil { count += 1 }
        return count
    }

    private var hasExtras: Bool {
        let advice = log.coachAdvice?.isEmpty == false
        return advice || !log.nutrients.isEmpty || !log.benefits.isEmpty || !log.drawbacks.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            let expandedHeight = min(geo.size.height * 0.78, 640)
            let target: CGFloat = expanded ? expandedHeight : compactHeight
            // Translate the drag (up = negative) into a height delta.
            // Rubber-band past either snap point so the gesture stays
            // alive without launching the panel offscreen.
            let raw = target - dragTranslation
            let lowerBound = compactHeight - 30
            let upperBound = expandedHeight + 60
            let live = max(lowerBound, min(upperBound, raw))

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                panelBody
                    .frame(maxWidth: .infinity)
                    .frame(height: live, alignment: .top)
                    .background(panelBackground)
                    .clipShape(
                        RoundedRectangle(cornerRadius: AppRadius.xl2,
                                         style: .continuous)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: -4)
            }
        }
    }

    /// Single panel layout used in both states. The extras are only added
    /// to the scroll tree when expanded so that, in compact mode, the
    /// ScrollView's content size matches its visible frame and there's no
    /// way for a stale scroll offset (from the user having scrolled the
    /// expanded content) to leave the header/macros off-screen. The
    /// `proxy.scrollTo("top")` on collapse is the second belt — if the
    /// user collapses by dragging or tapping the handle while scrolled
    /// down, we always snap back to the top.
    private var panelBody: some View {
        VStack(spacing: AppSpacing.sm + 4) {
            dragHandle
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm + 4) {
                        Color.clear
                            .frame(height: 0)
                            .id("top")
                        headerRows
                        MacroChipFlow(rows: rows) { idx, row in
                            revealing(index: 2 + idx) {
                                macroChip(row)
                            }
                        }
                        if hasExtras, expanded {
                            expandedExtras
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.lg + 8)
                }
                .scrollDisabled(!expanded)
                .onChange(of: expanded) { _, isExpanded in
                    if !isExpanded {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var headerRows: some View {
        revealing(index: 0) {
            Text(log.foodName)
                .appFont(.title1)
                .foregroundStyle(.white)
                .lineLimit(expanded ? nil : 2)
                .multilineTextAlignment(.leading)
                .accessibilityLabel("Food: \(log.foodName)")
        }
        revealing(index: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(format(log.calories))
                    .appFont(.display2)
                    .foregroundStyle(.white)
                Text("cal")
                    .appFont(.captionStrong)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.bottom, 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(format(log.calories)) calories")
        }
    }

    // The drag handle is the dedicated gesture target. Touching it (or
    // the strip of space around the capsule) opens the panel; the rest
    // of the panel stays scrollable when expanded.
    private var dragHandle: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(.white.opacity(0.32))
                .frame(width: 44, height: 5)
            if hasExtras, !expanded, visibleCount >= DetailPanel.rowCount(for: log) {
                Text("Pull up for details")
                    .appFont(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, AppSpacing.sm + 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasExtras else { return }
            toggleExpanded()
        }
        .gesture(panelDragGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(expanded ? "Collapse details" : "Expand details")
        .accessibilityAddTraits(.isButton)
    }

    /// Snappier than `.appBouncy` for the bottom-sheet snap — bouncy
    /// overshoot reads as jank when paired with a height interpolation
    /// because the shadow + clip have to redraw past the target. Damping
    /// 0.86 lands once and stays.
    private static let snapAnimation: Animation =
        .spring(response: 0.34, dampingFraction: 0.86)

    private var panelDragGesture: some Gesture {
        // `.global` rather than `.local`: the handle sits at the top of a
        // bottom-anchored panel that grows upward as the drag progresses,
        // so its local coordinate space moves with the finger. Measuring
        // translation in that moving frame feeds height changes back into
        // the gesture and produces visible flicker — the global frame is
        // stable, so translation tracks the finger cleanly.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                // Direct assignment — no animation while finger is down,
                // so the panel tracks the finger 1:1 instead of chasing it.
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let translation = value.translation.height
                let velocity = value.predictedEndTranslation.height - value.translation.height

                let willExpand: Bool = {
                    if expanded {
                        if translation > 80 || velocity > 350 { return false }
                        return true
                    } else {
                        if (translation < -60 || velocity < -300) && hasExtras { return true }
                        return false
                    }
                }()

                let changed = (willExpand != expanded)

                if reduceMotion {
                    expanded = willExpand
                    dragTranslation = 0
                } else {
                    withAnimation(Self.snapAnimation) {
                        expanded = willExpand
                        dragTranslation = 0
                    }
                }

                if changed { Haptics.selection() }
            }
    }

    private func toggleExpanded() {
        let target = !expanded
        if reduceMotion {
            expanded = target
        } else {
            withAnimation(Self.snapAnimation) {
                expanded = target
            }
        }
        Haptics.selection()
    }

    @ViewBuilder
    private var expandedExtras: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 4)

            if let advice = log.coachAdvice, !advice.isEmpty {
                section(title: "Coach", icon: "quote.bubble.fill") {
                    if let coach = log.coachName, !coach.isEmpty {
                        Text(coach.uppercased())
                            .appFont(.labelEyebrow)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(advice)
                        .appFont(.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !log.nutrients.isEmpty {
                section(title: "Nutrients", icon: "leaf.fill") {
                    listed(log.nutrients)
                }
            }
            if !log.benefits.isEmpty {
                section(title: "Benefits", icon: "checkmark.seal.fill") {
                    listed(log.benefits)
                }
            }
            if !log.drawbacks.isEmpty {
                section(title: "Watch outs", icon: "exclamationmark.triangle.fill") {
                    listed(log.drawbacks)
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .appFont(.captionStrong)
                    .foregroundStyle(.white.opacity(0.7))
            }
            content()
        }
    }

    @ViewBuilder
    private func listed(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(item)
                        .appFont(.body)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func revealing<Content: View>(index: Int,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        let shown = index < visibleCount
        content()
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : (reduceMotion ? 0 : 8))
    }

    /// Solid translucent fill rather than `.ultraThinMaterial`. The blur
    /// is gorgeous in theory but recomputing it every frame against a
    /// changing frame size during the expand/collapse drag was the main
    /// source of jank — measured noticeably smoother once removed.
    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl2, style: .continuous)
            .fill(Color.black.opacity(0.68))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl2, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .ignoresSafeArea(edges: .bottom)
    }

    private func macroChip(_ row: MacroRow) -> some View {
        HStack(spacing: 4) {
            Text("\(format(row.value))\(row.unit)")
                .appFont(.captionStrong)
                .foregroundStyle(.white)
            Text(row.label.lowercased())
                .appFont(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.label): \(format(row.value)) grams")
    }

    private func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "—" }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }

    struct MacroRow {
        let label: String
        let value: Double
        let unit: String
    }
}

private struct MacroChipFlow<Content: View>: View {
    let rows: [DetailPanel.MacroRow]
    @ViewBuilder let content: (Int, DetailPanel.MacroRow) -> Content

    var body: some View {
        WrappingLayout(spacing: 8, runSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                content(idx, row)
            }
        }
    }
}

private struct WrappingLayout: Layout {
    var spacing: CGFloat
    var runSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + runSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                y += rowHeight + runSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Zoomable image (UIKit)

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let target: CGFloat = 2.0
                let location = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                let w = size.width / target
                let h = size.height / target
                let rect = CGRect(
                    x: location.x - w / 2,
                    y: location.y - h / 2,
                    width: w, height: h
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

#if DEBUG
#Preview("FullImageViewer — error") {
    FullImageViewer(imagePath: "")
}
#endif
