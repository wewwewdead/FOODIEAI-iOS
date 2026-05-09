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
/// together. Bonus: native double-tap-to-zoom is straightforward to
/// add later if we want it.
///
/// Image data is fetched explicitly via `URLSession` (rather than the
/// SwiftUI `AsyncImage`) because the UIKit scroll view needs a `UIImage`,
/// and we'd rather load once than have AsyncImage load and the scroll
/// view re-decode the same bytes.
struct FullImageViewer: View {
    /// Storage path of the **main** image — i.e. `food_logs.image_path`,
    /// not `image_thumb_path`. Pre-Phase-12 rows still have a populated
    /// `image_path` (the legacy single image), so this works for them too.
    let imagePath: String

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var loadError: Bool = false

    private static let imageService = FoodImageService()

    var body: some View {
        ZStack {
            // Tap-outside-image dismiss target.
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            content

            // Top-leading close button. Inside `safeAreaInset` so it never
            // overlaps the Dynamic Island.
            VStack {
                HStack {
                    closeButton
                    Spacer()
                }
                Spacer()
            }
            .padding(AppSpacing.md)
        }
        .preferredColorScheme(.dark)
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            // The scroll view eats taps internally; pin its tap-to-dismiss
            // affordance to the surrounding black background only.
            ZoomableImageView(image: image)
                .ignoresSafeArea()
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

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 32, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
                .accessibilityLabel("Close")
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard image == nil, !loadError else { return }
        guard !imagePath.isEmpty else {
            loadError = true
            return
        }
        do {
            let url = try await Self.imageService.cachedSignedURL(for: imagePath)
            #if DEBUG
            NSLog("[FullImageViewer] loading %@", imagePath)
            #endif
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else {
                await MainActor.run { loadError = true }
                return
            }
            await MainActor.run { self.image = img }
        } catch {
            #if DEBUG
            NSLog("[FullImageViewer] load FAILED %@: %@", imagePath, "\(error)")
            #endif
            await MainActor.run { loadError = true }
        }
    }
}

/// UIKit `UIScrollView` wrapper providing native pinch-to-zoom and pan.
/// The image is sized once (`updateUIView` is a no-op after first install)
/// so re-rendering the parent doesn't reset the user's zoom/pan state.
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

        // Image fills the scroll view's bounds at zoomScale 1, with
        // .scaleAspectFit so the whole image is visible. Constraints on
        // both the scrollView's contentLayoutGuide and frameLayoutGuide
        // make the centering math automatic.
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Double-tap to toggle between fit and 2× zoom. A natural
        // affordance and cheap to add.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // No-op. Image is set once at init time; updating here would reset
        // the user's pan/zoom state on every parent re-render.
    }

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
